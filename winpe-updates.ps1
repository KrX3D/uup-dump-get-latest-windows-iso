#!/usr/bin/env pwsh
# winpe-updates.ps1 — EXPERIMENTAL. Dot-sourced by build-iso.ps1 when
# EXPERIMENTAL_WINPE_UPDATES=1. Not enabled by default and not part of the
# normal build path.
#
# Why this exists: the Linux/wimlib converter used for the normal build has
# no equivalent to DISM's /Add-Package servicing (see uup-dump's own FAQ —
# "Linux/macOS scripts do not support installing updates"), so ConvertConfig's
# AddUpdates/ResetBase are no-ops there. This module works around that by
# booting the ISO's own sources\boot.wim (a real WinPE, the same environment
# Windows Setup itself uses, and the one IT admins already use via Shift+F10
# for offline servicing) inside a throwaway QEMU/KVM VM, running real
# dism.exe against install.wim on an attached data disk, then splicing the
# serviced install.wim back into a copy of the original ISO.
#
# Requirements this needs from the container runtime that the normal build
# does not:
#   --device=/dev/kvm                (nested virtualization)
#   --device=/dev/fuse --cap-add SYS_ADMIN   (wimlib-imagex FUSE mount of boot.wim)
# If either is missing, or any step fails, this integration is skipped and
# logged — the caller falls back to the unpatched ISO. It must never turn a
# working build into a failed one.
#
# Known unknowns that need validating against a real run (see README):
#   - Which image index inside boot.wim is the plain "Windows PE" one whose
#     winpeshl.ini actually gets honored (vs. the "Windows Setup" index,
#     which may launch setup.exe regardless of winpeshl.ini).
#   - Whether the update package filenames under UUPs/ match the classic
#     SSU-*.cab / *KB*.msu|.cab pattern used by uup-dump's own Windows
#     converter (convert-UUP.cmd) for every target/ring, or only some.
#   - Whether the boot.wim's bundled dism.exe has everything it needs for
#     /Add-Package on very new/Insider builds.

function Test-WinPePrereqs {
    $ok = $true
    if (-not (Test-Path '/dev/kvm')) {
        Write-Log "[WinPE] /dev/kvm not present in this container. Run with --device=/dev/kvm (and confirm the Docker host itself has KVM available)." 'WARN'
        $ok = $false
    }
    foreach ($bin in 'qemu-system-x86_64', 'xorriso', 'wimlib-imagex', 'mkfs.ntfs') {
        if (-not (Get-Command $bin -EA SilentlyContinue)) {
            Write-Log "[WinPE] Required tool '$bin' not found in image." 'WARN'
            $ok = $false
        }
    }
    return $ok
}

function Find-UpdatePackages {
    param([string]$UupsDir)
    # Matches the naming pattern uup-dump's own Windows converter
    # (convert-UUP.cmd) looks for: SSU-*.cab must be applied before the LCU,
    # which ships as either *KB*.msu or *KB*.cab.
    $ssu = Get-ChildItem $UupsDir -Filter 'SSU-*.cab' -File -Recurse -EA SilentlyContinue | Select-Object -First 1
    $lcu = Get-ChildItem $UupsDir -File -Recurse -EA SilentlyContinue |
        Where-Object { $_.Name -match 'KB\d+.*\.(msu|cab)$' -and $_.Name -notlike 'SSU-*' } |
        Select-Object -First 1
    [PSCustomObject]@{ Ssu = $ssu; Lcu = $lcu }
}

function Get-WinPeShellImageIndex {
    param([string]$BootWimPath)
    # Prefer the image whose name contains "PE" (plain WinPE, honors
    # winpeshl.ini) over the "Windows Setup" image (may ignore it and launch
    # setup.exe directly). Falls back to index 1 if that heuristic finds
    # nothing — needs confirming against a real boot.wim (see file header).
    $info = & wimlib-imagex info $BootWimPath 2>$null
    Write-Log "[WinPE] boot.wim contents:`n$($info -join "`n")"
    $peIndex = $null
    $currentIndex = $null
    foreach ($line in $info) {
        if ($line -match '^Index:\s*(\d+)') { $currentIndex = [int]$Matches[1] }
        if ($line -match '^Name:\s*(.+)$' -and $currentIndex) {
            if ($Matches[1] -match '(?i)\bPE\b' -and $Matches[1] -notmatch '(?i)setup') {
                $peIndex = $currentIndex
            }
        }
    }
    if (-not $peIndex) {
        Write-Log "[WinPE] Could not identify a plain 'Windows PE' image by name — defaulting to index 1. If the VM boots straight into Setup instead of running the DISM script, this is why." 'WARN'
        $peIndex = 1
    }
    return $peIndex
}

function Invoke-WinPeUpdateIntegration {
    param(
        [Parameter(Mandatory)] [string]$IsoPath,
        [Parameter(Mandatory)] [string]$BuildDirectory,
        [bool]$ResetBase = $false
    )

    Write-Log "[WinPE] EXPERIMENTAL_WINPE_UPDATES is enabled — attempting real DISM update integration." 'WARN'

    if (-not (Test-WinPePrereqs)) {
        Write-Log "[WinPE] Prerequisites missing — skipping. ISO will remain unpatched (same as with this feature off)." 'WARN'
        return $null
    }

    $uupsDir = Join-Path $BuildDirectory 'UUPs'
    $pkgs = Find-UpdatePackages -UupsDir $uupsDir
    if (-not $pkgs.Lcu) {
        Write-Log "[WinPE] No KB*.msu/.cab update package found under UUPs/ — either this build is already fully current, or the package naming didn't match what this experimental step expects. Skipping." 'WARN'
        return $null
    }
    Write-Log "[WinPE] Update packages found: SSU=$(if ($pkgs.Ssu) { $pkgs.Ssu.Name } else { '<none>' })  LCU=$($pkgs.Lcu.Name)"

    $work = Join-Path $BuildDirectory 'winpe-update'
    New-Item -ItemType Directory -Force $work | Out-Null
    $bootWim    = Join-Path $work 'boot.wim'
    $installWim = Join-Path $work 'install.wim'
    $toolIso    = Join-Path $work 'winpe-tool.iso'
    $dataImg    = Join-Path $work 'data.img'
    $bootMnt    = Join-Path $work 'boot-mnt'
    $dataMnt    = Join-Path $work 'data-mnt'
    $finalIso   = Join-Path $work 'patched.iso'
    $loopDev    = $null

    try {
        Write-Log "[WinPE] Extracting boot.wim and install.wim from the built ISO..."
        & xorriso -indev $IsoPath -osirrox on -extract /sources/boot.wim $bootWim 2>&1 | ForEach-Object { Write-Log "  $_" }
        & xorriso -indev $IsoPath -osirrox on -extract /sources/install.wim $installWim 2>&1 | ForEach-Object { Write-Log "  $_" }
        if (-not (Test-Path $bootWim) -or -not (Test-Path $installWim)) {
            throw "xorriso did not produce boot.wim/install.wim — unexpected ISO layout"
        }

        $peIndex = Get-WinPeShellImageIndex -BootWimPath $bootWim

        Write-Log "[WinPE] Injecting DISM automation script into boot.wim (index $peIndex)..."
        New-Item -ItemType Directory -Force $bootMnt | Out-Null
        & wimlib-imagex mountrw $bootWim $peIndex $bootMnt 2>&1 | ForEach-Object { Write-Log "  $_" }

        $dismRunCmd = @'
@echo off
set LOG=X:\dism-run.log
echo === WinPE DISM update run started === > %LOG%
set DRV=
for %%D in (D E F G H I J) do if exist %%D:\install.wim set DRV=%%D:
if "%DRV%"=="" (
    echo No data drive with install.wim found >> %LOG%
    goto :fail
)
echo Using data drive %DRV% >> %LOG%

dism /Get-WimInfo /WimFile:%DRV%\install.wim >> %LOG% 2>&1

mkdir X:\mount
dism /Mount-Wim /WimFile:%DRV%\install.wim /Index:1 /MountDir:X:\mount >> %LOG% 2>&1
if errorlevel 1 goto :fail

if exist %DRV%\ssu.cab (
    dism /Image:X:\mount /Add-Package /PackagePath:%DRV%\ssu.cab >> %LOG% 2>&1
    if errorlevel 1 goto :fail_mounted
)

dism /Image:X:\mount /Add-Package /PackagePath:%DRV%\lcu.update >> %LOG% 2>&1
if errorlevel 1 goto :fail_mounted

if exist %DRV%\resetbase.flag (
    dism /Image:X:\mount /Cleanup-Image /StartComponentCleanup /ResetBase >> %LOG% 2>&1
)

dism /Unmount-Wim /MountDir:X:\mount /Commit >> %LOG% 2>&1
if errorlevel 1 goto :fail

echo done > %DRV%\done.flag
copy %LOG% %DRV%\dism-run.log
wpeutil shutdown
exit /b 0

:fail_mounted
dism /Unmount-Wim /MountDir:X:\mount /Discard >> %LOG% 2>&1
:fail
echo error > %DRV%\error.flag
copy %LOG% %DRV%\dism-run.log
wpeutil shutdown
exit /b 1
'@ -replace "`r?`n", "`r`n"
        Set-Content -Path (Join-Path $bootMnt 'dism-run.cmd') -Value $dismRunCmd -Encoding ascii -NoNewline

        $winpeshl = "[LaunchApps]`r`n%SYSTEMDRIVE%\dism-run.cmd`r`n"
        $sysDir = Join-Path (Join-Path $bootMnt 'Windows') 'System32'
        if (Test-Path $sysDir) {
            Set-Content -Path (Join-Path $sysDir 'winpeshl.ini') -Value $winpeshl -Encoding ascii
        } else {
            Write-Log "[WinPE] Windows\System32 not found inside boot.wim image $peIndex — winpeshl.ini not written, VM will likely boot to a plain prompt instead of running DISM automatically." 'WARN'
        }

        & wimlib-imagex unmount $bootMnt --commit 2>&1 | ForEach-Object { Write-Log "  $_" }

        Write-Log "[WinPE] Assembling bootable tool ISO (original boot catalog, patched boot.wim)..."
        & xorriso -indev $IsoPath -outdev $toolIso -boot_image any replay -map $bootWim /sources/boot.wim -commit 2>&1 |
            ForEach-Object { Write-Log "  $_" }
        if (-not (Test-Path $toolIso)) { throw "xorriso did not produce $toolIso" }

        Write-Log "[WinPE] Building NTFS data disk (install.wim + update packages)..."
        $sizeMb = [int]((Get-Item $installWim).Length / 1MB) + 4096
        & qemu-img create -f raw $dataImg "${sizeMb}M" 2>&1 | ForEach-Object { Write-Log "  $_" }
        & mkfs.ntfs -F -L WINPEDATA $dataImg 2>&1 | ForEach-Object { Write-Log "  $_" }

        $loopDev = (& losetup --find --show $dataImg).Trim()
        New-Item -ItemType Directory -Force $dataMnt | Out-Null
        & /bin/mount -t ntfs-3g $loopDev $dataMnt
        Copy-Item $installWim (Join-Path $dataMnt 'install.wim')
        if ($pkgs.Ssu) { Copy-Item $pkgs.Ssu.FullName (Join-Path $dataMnt 'ssu.cab') }
        Copy-Item $pkgs.Lcu.FullName (Join-Path $dataMnt 'lcu.update')
        if ($ResetBase) { Set-Content -Path (Join-Path $dataMnt 'resetbase.flag') -Value '1' }
        & /bin/umount $dataMnt
        & losetup -d $loopDev
        $loopDev = $null

        Write-Log "[WinPE] Booting WinPE under QEMU/KVM to run DISM offline servicing — this can take several minutes..."
        $serialLog = Join-Path $work 'serial.log'
        $qemuArgs = @(
            '-enable-kvm', '-machine', 'pc', '-cpu', 'host',
            '-m', '4096', '-smp', '2',
            '-drive', "file=$toolIso,media=cdrom",
            '-drive', "file=$dataImg,format=raw,if=ide",
            '-boot', 'd',
            '-nic', 'none',
            '-display', 'none',
            '-serial', "file:$serialLog",
            '-no-reboot'
        )
        $proc = Start-Process -FilePath 'qemu-system-x86_64' -ArgumentList $qemuArgs -PassThru -NoNewWindow
        $finished = $proc.WaitForExit(20 * 60 * 1000)
        if (-not $finished) {
            Write-Log "[WinPE] QEMU did not exit within 20 minutes — killing it and giving up on this integration attempt." 'WARN'
            try { $proc.Kill() } catch {}
            return $null
        }

        Write-Log "[WinPE] VM exited — checking result..."
        $loopDev = (& losetup --find --show $dataImg).Trim()
        & /bin/mount -t ntfs-3g $loopDev $dataMnt

        $dismLog = Join-Path $dataMnt 'dism-run.log'
        if (Test-Path $dismLog) {
            Copy-Item $dismLog (Join-Path $LogDirectory 'winpe-dism-run.log') -Force
            Write-Log "[WinPE] dism-run.log copied to $(Join-Path $LogDirectory 'winpe-dism-run.log')"
        }

        $success = Test-Path (Join-Path $dataMnt 'done.flag')
        if (-not $success) {
            Write-Log "[WinPE] No done.flag found on the data disk — update integration did not complete successfully. See winpe-dism-run.log. Falling back to the unpatched ISO." 'WARN'
            & /bin/umount $dataMnt
            & losetup -d $loopDev
            $loopDev = $null
            return $null
        }

        Write-Log "[WinPE] DISM reported success — pulling serviced install.wim back out..."
        $servicedInstallWim = Join-Path $work 'install-serviced.wim'
        Copy-Item (Join-Path $dataMnt 'install.wim') $servicedInstallWim
        & /bin/umount $dataMnt
        & losetup -d $loopDev
        $loopDev = $null

        Write-Log "[WinPE] Splicing serviced install.wim into a copy of the original ISO..."
        & xorriso -indev $IsoPath -outdev $finalIso -boot_image any replay -map $servicedInstallWim /sources/install.wim -commit 2>&1 |
            ForEach-Object { Write-Log "  $_" }
        if (-not (Test-Path $finalIso)) { throw "xorriso did not produce the final patched ISO" }

        Write-Log "[WinPE] Update integration succeeded."
        return $finalIso

    } catch {
        Write-Log "[WinPE] Update integration failed: $_. Falling back to the unpatched ISO." 'WARN'
        return $null
    } finally {
        if ($loopDev) { try { & /bin/umount $dataMnt 2>$null } catch {}; try { & losetup -d $loopDev 2>$null } catch {} }
        try { if (Test-Path $bootMnt) { & wimlib-imagex unmount $bootMnt 2>$null } } catch {}
    }
}
