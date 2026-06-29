#!/usr/bin/env pwsh
param(
    [string]$OutputDirectory = '/output',
    [string]$LogDirectory    = '',
    [string]$WorkDirectory   = '/work',
    [string]$WindowsTarget   = 'windows-11',
    [string]$Language        = 'de-de',
    [string]$Edition         = 'Professional',
    [string]$Ring            = 'RETAIL',
    # Web UI mode — set MODE=web (or -Mode web) to serve the config UI instead of auto-building
    [string]$Mode            = 'auto',
    [int]$WebPort            = 8080,
    # Settings file written by the web UI; overrides ConvertConfig, app list, and output options
    [string]$SettingsFile    = '',
    # Per-run log path for the web UI live-log poller
    [string]$CurrentBuildLog = '',
    # Specific UUP dump build UUID pinned in the web UI; empty = use latest
    [string]$BuildId         = '',
    # Output file options (can be toggled in the web UI)
    [bool]$WriteChecksum     = $true,
    [bool]$WriteMetadata     = $true
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

if (-not $LogDirectory) { $LogDirectory = $OutputDirectory }

# Honour MODE env var as fallback (set in Docker as MODE=web)
if ($Mode -eq 'auto' -and $env:MODE -eq 'web') { $Mode = 'web' }
if ($WebPort -eq 8080 -and $env:WEB_PORT)       { $WebPort = [int]$env:WEB_PORT }

$script:WorkDirectory    = $WorkDirectory
$script:buildDirectory   = $null
$script:CurrentBuildLog  = $CurrentBuildLog
$script:StatusFilePath   = '/config/build-status.json'
$script:UseStatusFile    = ($CurrentBuildLog -ne '')
$script:RollingLog       = Join-Path $LogDirectory 'uup-dump.log'
$script:RunStartTime     = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
$script:RunLogFile       = Join-Path $LogDirectory ('{0}_{1}_{2}_{3}.log' -f
    $script:RunStartTime, $WindowsTarget, $Language, $Edition)

New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
New-Item -ItemType Directory -Force $LogDirectory    | Out-Null
New-Item -ItemType Directory -Force $WorkDirectory   | Out-Null

# Load settings file (written by the web UI; also auto-loaded from /config/settings.json in auto mode)
$settingsData = $null
$_sfPath = if ($SettingsFile) { $SettingsFile } `
           elseif (Test-Path '/config/settings.json') { '/config/settings.json' } `
           else { '' }
if ($_sfPath) {
    $settingsData = Get-Content $_sfPath -Raw -EA SilentlyContinue | ConvertFrom-Json -EA SilentlyContinue
    if ($settingsData) {
        if ($settingsData.writeChecksum -ne $null) { $WriteChecksum = [bool]$settingsData.writeChecksum }
        if ($settingsData.writeMetadata -ne $null) { $WriteMetadata = [bool]$settingsData.writeMetadata }
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try { Add-Content -Path $script:RollingLog -Value $line -Encoding UTF8 } catch {}
    try { Add-Content -Path $script:RunLogFile -Value $line -Encoding UTF8 } catch {}
    if ($script:CurrentBuildLog) {
        try { Add-Content -Path $script:CurrentBuildLog -Value $line -Encoding UTF8 } catch {}
    }
}

function Invoke-LogRotate {
    try {
        if ((Test-Path $script:RollingLog) -and (Get-Item $script:RollingLog).Length -gt 1MB) {
            $kept = Get-Content $script:RollingLog -Tail 4000
            Set-Content $script:RollingLog -Value $kept -Encoding UTF8
        }
    } catch {}
}

trap {
    Write-Log "FATAL: $_" 'ERROR'
    $_.ScriptStackTrace -split '\r?\n' | ForEach-Object { Write-Log "  $_" 'ERROR' }
    if ($script:buildDirectory -and (Test-Path $script:buildDirectory)) {
        Write-Log "Cleaning up work directory after error..."
        Remove-Item -Force -Recurse $script:buildDirectory -ErrorAction SilentlyContinue
        Remove-Item -Force "$($script:buildDirectory).zip" -ErrorAction SilentlyContinue
    }
    if ($script:WorkDirectory -and (Test-Path $script:WorkDirectory)) {
        Remove-Item -Force -Recurse $script:WorkDirectory -ErrorAction SilentlyContinue
    }
    if ($script:UseStatusFile) {
        try { '{"status":"failed"}' | Set-Content $script:StatusFilePath -Encoding UTF8 } catch {}
    }
    exit 1
}

Invoke-LogRotate

# ── Web UI mode — source and start the HTTP server; never proceeds to build logic ─────

if ($Mode -eq 'web') {
    . '/web-ui.ps1'
    Start-WebUi -BuildScriptPath $PSCommandPath -Port $WebPort `
        -OutputDirectory $OutputDirectory -WorkDirectory $WorkDirectory -LogDirectory $LogDirectory
    exit 0
}

# ── Auto-run mode: mark running if invoked from web UI ────────────────────────

if ($script:UseStatusFile) {
    New-Item -ItemType Directory -Force (Split-Path $script:StatusFilePath) | Out-Null
    '{"status":"running"}' | Set-Content $script:StatusFilePath -Encoding UTF8
}

# Blank-line separator between runs in the rolling log
if (Test-Path $script:RollingLog) {
    try { Add-Content -Path $script:RollingLog -Value "`n" -Encoding UTF8 } catch {}
}

Write-Log "=================================================="
Write-Log "UUP Dump Windows ISO Builder"
Write-Log "Target   : $WindowsTarget"
Write-Log "Ring     : $Ring"
Write-Log "Language : $Language"
Write-Log "Edition  : $Edition"
Write-Log "Output   : $OutputDirectory"
Write-Log "Logs     : $LogDirectory"
Write-Log "Work     : $WorkDirectory (cleaned up on exit)"
if ($BuildId) { Write-Log "BuildId  : $BuildId (pinned)" }
Write-Log "=================================================="

$TARGETS = @{
    'windows-10' = @{
        search   = 'windows 10 amd64'
        keep     = @('*windows 10*')
        skip     = @('*team*', '*insider*', '*preview*', '*next*')
        editions = @($Edition)
    }
    'windows-11' = @{
        search   = 'windows 11 amd64'
        keep     = @('*windows 11*')
        skip     = @('*team*', '*insider*', '*preview*', '*next*')
        editions = @($Edition)
    }
    'windows-2022' = @{
        search   = 'microsoft server operating system amd64'
        keep     = @('*microsoft server operating system*')
        skip     = @('*team*', '*insider*', '*preview*', '*next*')
        editions = @($Edition)
    }
}

if (-not $TARGETS.ContainsKey($WindowsTarget)) {
    Write-Log "Unknown WINDOWS_TARGET '$WindowsTarget'. Valid values: $($TARGETS.Keys -join ', ')" 'ERROR'
    exit 1
}

# ── API helpers ───────────────────────────────────────────────────────────────

function New-QueryString([hashtable]$params) {
    @($params.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
    }) -join '&'
}

function Get-UupDumpIso([string]$name, [hashtable]$target, [string]$wantRing, [string]$specificBuildId = '') {
    if ($specificBuildId) {
        Write-Log "Using pinned build ID: $specificBuildId"
        $r     = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listlangs.php' -Body @{ id = $specificBuildId }
        $build = $r.response.updateInfo.build
        $ring  = if ($r.response.updateInfo.ring)  { $r.response.updateInfo.ring }  else { $wantRing }
        $title = if ($r.response.updateInfo.title) { $r.response.updateInfo.title } else { "Build $build" }
        if ($r.response.langFancyNames.PSObject.Properties.Name -notcontains $Language) {
            Write-Log "Pinned build $specificBuildId does not have language '$Language'" 'ERROR'
            return $null
        }
        return [PSCustomObject]@{
            name               = $name
            title              = $title
            build              = $build
            ring               = $ring
            id                 = $specificBuildId
            downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{
                id      = $specificBuildId
                pack    = $Language
                edition = $target.editions -join ';'
            })
        }
    }

    Write-Log "Searching UUP dump: '$($target.search)' | Ring: $wantRing"

    $result = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listid.php' `
        -Body @{ search = $target.search }

    # Filter by title patterns and sort newest-first.
    # listid.php includes a 'ring' field on each build, so we can filter and log
    # rings without any extra API calls.
    $allBuilds = $result.response.builds.PSObject.Properties `
    | Where-Object {
        $t = $_.Value.title
        (($target.keep | ForEach-Object { $t -like $_ }) -notcontains $false) `
          -and (($target.skip | ForEach-Object { $t -like $_ }) -notcontains $true)
    } `
    | Sort-Object { [version]$_.Value.build } -Descending

    # Log a discovery table (ring not available until listlangs is called per-build)
    Write-Log "Available builds (newest 15) — rings shown during per-build checks below:"
    $allBuilds | Select-Object -First 15 | ForEach-Object {
        Write-Log ("    {0,-15} {1}" -f $_.Value.build, $_.Value.title)
    }
    Write-Log "Set WINDOWS_RING to RETAIL, DEV, BETA, CANARY, RP, or ANY."

    # Select candidates matching the requested ring (or any, when wantRing='ANY').
    # Builds without ring info in listid are included as fallback candidates.
    $candidates = $allBuilds | Where-Object {
        if ($wantRing -eq 'ANY') { return $true }
        $r = if ($_.Value.PSObject.Properties.Name -contains 'ring' -and $_.Value.ring) { $_.Value.ring } else { $null }
        -not $r -or $r -eq $wantRing
    } | Select-Object -First 5

    foreach ($candidate in $candidates) {
        $id        = $candidate.Value.uuid
        $build     = $candidate.Value.build
        $buildRing = if ($candidate.Value.PSObject.Properties.Name -contains 'ring' -and $candidate.Value.ring) {
            $candidate.Value.ring } else { '?' }
        Write-Log "Checking build $id ($build, ring: $buildRing)..."

        $r = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listlangs.php' -Body @{ id = $id }

        # Double-check ring from listlangs in case listid didn't have it
        $confirmedRing = if ($r.response.updateInfo.ring) { $r.response.updateInfo.ring } else { $buildRing }
        if ($wantRing -ne 'ANY' -and $confirmedRing -ne '?' -and $confirmedRing -ne $wantRing) {
            Write-Log "  Skipping (ring confirmed: $confirmedRing)"
            continue
        }

        if ($r.response.langFancyNames.PSObject.Properties.Name -notcontains $Language) { continue }

        $r2 = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listeditions.php' `
            -Body @{ id = $id; lang = $Language }
        $avail = $r2.response.editionFancyNames.PSObject.Properties.Name
        if ((Compare-Object -ExcludeDifferent $target.editions $avail).Length -ne $target.editions.Length) { continue }

        return [PSCustomObject]@{
            name               = $name
            title              = $candidate.Value.title
            build              = $build
            ring               = $confirmedRing
            id                 = $id
            downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{
                id      = $id
                pack    = $Language
                edition = $target.editions -join ';'
            })
        }
    }

    return $null
}

# ── Fetch latest build metadata ───────────────────────────────────────────────

$iso = Get-UupDumpIso $WindowsTarget $TARGETS.$WindowsTarget $Ring $BuildId

if (-not $iso) {
    Write-Log "No matching build found for $WindowsTarget ($Language / $Edition)" 'ERROR'
    exit 1
}

if ($iso.build -notmatch '^\d+\.\d+$') {
    throw "Unexpected build number format: $($iso.build)"
}

Write-Log "Latest build: $($iso.title)  [$($iso.build)]  (ring: $($iso.ring))"

$buildMajor = $iso.build.Split('.')[0]
$buildMinor = $iso.build.Split('.')[1]

# Rename per-run log now that the build number is known
$runLogFinal = Join-Path $LogDirectory ('{0}_{1}.{2}_{3}_{4}_{5}.log' -f
    $script:RunStartTime, $buildMajor, $buildMinor, $WindowsTarget, $Language, $Edition)
if ((Test-Path $script:RunLogFile) -and $script:RunLogFile -ne $runLogFinal) {
    Move-Item $script:RunLogFile $runLogFinal -Force
    $script:RunLogFile = $runLogFinal
}

# ── Check for existing ISO ────────────────────────────────────────────────────

$existingIso = Get-ChildItem $OutputDirectory -Filter "$buildMajor.$buildMinor.*.iso" `
    -ErrorAction SilentlyContinue | Select-Object -First 1

if ($existingIso) {
    Write-Log "ISO for build $($iso.build) already present: $($existingIso.Name)"
    Write-Log "Nothing to do."
    exit 0
}

Write-Log "No existing ISO for build $($iso.build) — starting download and conversion."

# ── Prepare build directory ───────────────────────────────────────────────────

$buildDirectory = Join-Path $WorkDirectory "$WindowsTarget-$($iso.build)"
$script:buildDirectory = $buildDirectory

if (Test-Path $buildDirectory) {
    Write-Log "Removing stale build directory: $buildDirectory"
    Remove-Item -Force -Recurse $buildDirectory
}
New-Item -ItemType Directory -Force $buildDirectory | Out-Null

$zipPath = "$buildDirectory.zip"

# ── Download, patch, and run — with retry on URL expiry ──────────────────────
# UUP download URLs contain a P1= expiry timestamp (~22 min window). On Unraid,
# CDN stalling means some files exhaust retries before completing. On failure we
# re-fetch a fresh package (new P1 timestamps) and re-run with --check-integrity
# so aria2 verifies and skips already-complete files, only retrying the failures.

$maxAttempts = 3
$totalStart  = Get-Date

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

    # ── Download UUP conversion package (fresh URLs on every attempt) ──────────

    if ($attempt -eq 1) {
        Write-Log "Downloading UUP package ($($iso.downloadPackageUrl))..."
    } else {
        Write-Log "Retry $attempt/$maxAttempts — fetching fresh package URLs from uupdump.net..."
    }
    Invoke-WebRequest -Method Post -Uri $iso.downloadPackageUrl `
        -Body @{ autodl = 2; updates = 1; cleanup = 1 } `
        -OutFile $zipPath
    # -Force: extract into existing dir without deleting UUPs/ download folder
    Expand-Archive $zipPath $buildDirectory -Force
    Remove-Item $zipPath

    if ($attempt -eq 1) { Write-Log "Extracting package..." }

    # ── Configure ConvertConfig.ini ────────────────────────────────────────────

    $configPath = Join-Path $buildDirectory 'ConvertConfig.ini'
    $cc = if ($settingsData -and $settingsData.convertConfig) { $settingsData.convertConfig } else {
        [PSCustomObject]@{ AutoExit=$true; CustomList=$true; NetFx3=$true; ResetBase=$true; SkipWinRE=$true; AddUpdates=$false }
    }
    $ccMap = @{ AutoExit=$cc.AutoExit; CustomList=$cc.CustomList; NetFx3=$cc.NetFx3
                ResetBase=$cc.ResetBase; SkipWinRE=$cc.SkipWinRE; AddUpdates=$cc.AddUpdates }
    $cfgLines = Get-Content $configPath
    foreach ($key in $ccMap.Keys) {
        $val      = [int][bool]$ccMap[$key]
        $cfgLines = $cfgLines -replace "^($key\s*)=.*", "`${1}=$val"
    }
    Set-Content -Encoding ascii -Path $configPath -Value $cfgLines
    if ($attempt -eq 1) {
        $ccSummary = ($ccMap.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$([int][bool]$_.Value)" }) -join ' '
        Write-Log "ConvertConfig.ini: $ccSummary"
    }

    # ── Configure CustomAppsList.txt ───────────────────────────────────────────

    $allKnownApps = @(
        'Microsoft.Windows.Photos_8wekyb3d8bbwe',
        'Microsoft.WindowsCamera_8wekyb3d8bbwe',
        'Microsoft.WindowsNotepad_8wekyb3d8bbwe',
        'Microsoft.Paint_8wekyb3d8bbwe',
        'Microsoft.WindowsTerminal_8wekyb3d8bbwe',
        'MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy',
        'Microsoft.WindowsAlarms_8wekyb3d8bbwe',
        'Microsoft.WindowsCalculator_8wekyb3d8bbwe',
        'Microsoft.WindowsMaps_8wekyb3d8bbwe',
        'Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe',
        'Microsoft.ScreenSketch_8wekyb3d8bbwe',
        'microsoft.windowscommunicationsapps_8wekyb3d8bbwe',
        'Microsoft.People_8wekyb3d8bbwe',
        'Microsoft.WindowsFeedbackHub_8wekyb3d8bbwe',
        'Microsoft.GetHelp_8wekyb3d8bbwe',
        'Microsoft.Getstarted_8wekyb3d8bbwe',
        'Microsoft.Todos_8wekyb3d8bbwe',
        'Microsoft.PowerAutomateDesktop_8wekyb3d8bbwe',
        'Microsoft.549981C3F5F10_8wekyb3d8bbwe',
        'MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe',
        'MicrosoftCorporationII.MicrosoftFamily_8wekyb3d8bbwe',
        'Clipchamp.Clipchamp_yxz26nhyzhsrt',
        'Microsoft.ApplicationCompatibilityEnhancements_8wekyb3d8bbwe',
        'MicrosoftWindows.CrossDevice_cw5n1h2txyewy',
        'Microsoft.MicrosoftPCManager_8wekyb3d8bbwe',
        'Microsoft.YourPhone_8wekyb3d8bbwe',
        'Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe',
        'Microsoft.StartExperiencesApp_8wekyb3d8bbwe',
        'Microsoft.WidgetsPlatformRuntime_8wekyb3d8bbwe',
        'Microsoft.WebMediaExtensions_8wekyb3d8bbwe',
        'Microsoft.RawImageExtension_8wekyb3d8bbwe',
        'Microsoft.HEIFImageExtension_8wekyb3d8bbwe',
        'Microsoft.HEVCVideoExtension_8wekyb3d8bbwe',
        'Microsoft.VP9VideoExtensions_8wekyb3d8bbwe',
        'Microsoft.WebpImageExtension_8wekyb3d8bbwe',
        'Microsoft.DolbyAudioExtensions_8wekyb3d8bbwe',
        'Microsoft.AVCEncoderVideoExtension_8wekyb3d8bbwe',
        'Microsoft.MPEG2VideoExtension_8wekyb3d8bbwe',
        'Microsoft.AV1VideoExtension_8wekyb3d8bbwe',
        'Microsoft.Whiteboard_8wekyb3d8bbwe',
        'microsoft.microsoftskydrive_8wekyb3d8bbwe'
    )
    $enabledApps = if ($settingsData -and $settingsData.enabledApps -and @($settingsData.enabledApps).Count -gt 0) {
        @($settingsData.enabledApps)
    } else {
        $allKnownApps
    }
    $appsPath    = Join-Path $buildDirectory 'CustomAppsList.txt'
    $appsContent = Get-Content $appsPath
    $appsContent = $appsContent | ForEach-Object {
        $line = $_
        if ($line -match '^(\s*)#\s*(\S.*)$') {
            $appId = $Matches[2].Trim()
            if ($allKnownApps -contains $appId -and $enabledApps -contains $appId) { return $appId }
        } elseif ($line.Trim() -ne '' -and $line -notmatch '^\s*#') {
            $appId = $line.Trim()
            if ($allKnownApps -contains $appId -and $enabledApps -notcontains $appId) { return "# $appId" }
        }
        return $line
    }
    Set-Content -Encoding ascii -Path $appsPath -Value $appsContent
    if ($attempt -eq 1) { Write-Log "CustomAppsList.txt: $($enabledApps.Count)/$($allKnownApps.Count) apps enabled" }

    # ── Patch uup_download_linux.sh ────────────────────────────────────────────

    $linuxScript = Join-Path $buildDirectory 'uup_download_linux.sh'
    if (-not (Test-Path $linuxScript)) {
        Write-Log "uup_download_linux.sh not found in package — cannot continue" 'ERROR'
        exit 1
    }

    # On retry add --check-integrity=true: aria2 hashes each existing file against
    # the checksum in the input script and skips files that already match, so only
    # the failed files (with now-expired URLs) get re-downloaded with fresh URLs.
    $ciFlag = if ($attempt -gt 1) { '--check-integrity=true ' } else { '' }
    & bash -c "sed -i 's/--no-conf /--no-conf --timeout=60 --max-tries=20 --retry-wait=15 --disable-ipv6 ${ciFlag}/g' `"$linuxScript`""

    # Inject "Total files to download: N" right before the main download starts.
    # The aria2 input script (aria2_script.PID.txt) has already been downloaded by
    # this point in uup_download_linux.sh, so the grep count is accurate.
    # Uses PowerShell string replace to avoid bash/sed quoting complexity.
    $scriptContent = Get-Content -Path $linuxScript -Raw
    $countSnippet  = '_tc=$(grep -c "^  out=" aria2_script.*.txt 2>/dev/null || echo "?"); echo "Total files to download: ${_tc}"'
    $patched       = $scriptContent -replace '(echo "Downloading the UUP set\.\.\.")', "`$1`n$countSnippet"
    if ($patched -ne $scriptContent) {
        [System.IO.File]::WriteAllText($linuxScript, ($patched -replace '\r\n', "`n"))
    }

    & chmod +x $linuxScript
    $patchSuffix = if ($attempt -gt 1) { ', check-integrity (skips complete files)' } else { '' }
    Write-Log "Patched uup_download_linux.sh: aria2 retries, IPv4-only$patchSuffix"

    # ── Pre-populate converter files ───────────────────────────────────────────

    $converterMulti = Join-Path $buildDirectory 'files' 'converter_multi'
    if (Test-Path $converterMulti) {
        $filesDir = Join-Path $buildDirectory 'files'
        $cacheOk = (& bash -c "test -s /opt/uup-converter/convert.sh && test -s /opt/uup-converter/convert_ve_plugin && echo yes || echo no").Trim()
        if ($cacheOk -eq 'yes') {
            & bash -c "cp /opt/uup-converter/convert.sh /opt/uup-converter/convert_ve_plugin `"$filesDir/`""
            & bash -c "chmod +x `"$filesDir/convert.sh`" `"$filesDir/convert_ve_plugin`""
            & bash -c "sed -i '/converter_multi/c\echo Converter files pre-populated from image cache' `"$linuxScript`""
            if ($attempt -eq 1) {
                Write-Log "Pre-populated converter files from image cache; replaced aria2 converter download"
            }
        } else {
            if ($attempt -eq 1) {
                Write-Log "No converter cache in image — aria2 will attempt git.uupdump.net directly"
            }
        }
    }

    # ── Run download and conversion ────────────────────────────────────────────

    $startMsg = if ($attempt -eq 1) {
        'Starting download and ISO conversion (this may take 1-3 hours)...'
    } else {
        "Retry $attempt/$maxAttempts — downloading remaining files with fresh URLs..."
    }
    Write-Log $startMsg

    Push-Location $buildDirectory
    try {
        # Tee-Object writes bash output to both Docker stdout and the per-run log file
        & bash ./uup_download_linux.sh 2>&1 | Tee-Object -Append -FilePath $script:RunLogFile
        $_exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    # ── Download summary ───────────────────────────────────────────────────────
    $_uupsDir = Join-Path $buildDirectory 'UUPs'
    if (Test-Path $_uupsDir) {
        $_doneFiles = @(Get-ChildItem $_uupsDir -File -EA SilentlyContinue |
                        Where-Object Extension -ne '.aria2')
        $_bytes     = ($_doneFiles | Measure-Object Length -Sum).Sum
        $_szStr     = if ($_bytes -ge 1GB)   { '{0:F2} GB' -f ($_bytes / 1GB)  }
                      elseif ($_bytes -ge 1MB) { '{0:F1} MB' -f ($_bytes / 1MB)  }
                      else                     { '{0} KB'    -f [int]($_bytes / 1KB) }
        $_a2f   = Get-ChildItem $buildDirectory -Filter 'aria2_script.*.txt' -EA SilentlyContinue |
                  Select-Object -First 1
        $_total = if ($_a2f) { (Select-String -Path $_a2f.FullName -Pattern '^  out=').Count } else { '?' }
        Write-Log "Download: $($_doneFiles.Count)/$_total files complete | $_szStr on disk"
    }

    if ($_exitCode -eq 0) { break }
    if ($attempt -lt $maxAttempts) {
        Write-Log "Attempt $attempt failed (exit $_exitCode) — will retry with fresh URLs" 'ERROR'
    } else {
        throw "uup_download_linux.sh exited with code $_exitCode after $maxAttempts attempts"
    }
}

$elapsed = (Get-Date) - $totalStart
Write-Log "Completed in $([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s"

# ── Locate the created ISO ────────────────────────────────────────────────────

$sourceIso = Get-ChildItem $buildDirectory -Filter '*.iso' -Recurse | Select-Object -First 1
if (-not $sourceIso) {
    throw "No ISO found in $buildDirectory after conversion"
}
Write-Log "ISO created: $($sourceIso.Name)  ($([math]::Round($sourceIso.Length / 1GB, 2)) GB)"

# ── Checksum ──────────────────────────────────────────────────────────────────

Write-Log "Computing SHA256..."
$sha    = [System.Security.Cryptography.SHA256]::Create()
$stream = $sourceIso.OpenRead()
$bytes  = $sha.ComputeHash($stream)
$stream.Close()
$checksum = (([BitConverter]::ToString($bytes)) -replace '-', '').ToLower()
Write-Log "SHA256: $checksum"

# ── Build destination filename ────────────────────────────────────────────────

$langCode = switch ($Language.ToLower()) {
    'de-de' { 'DE' }
    'en-us' { 'EN-US' }
    'en-gb' { 'EN-GB' }
    'fr-fr' { 'FR' }
    'es-es' { 'ES' }
    'it-it' { 'IT' }
    'pl-pl' { 'PL' }
    'nl-nl' { 'NL' }
    'pt-pt' { 'PT-PT' }
    'pt-br' { 'PT-BR' }
    default  { ($Language -split '-')[0].ToUpper() }
}

$edCode = switch ($Edition) {
    'Professional'     { 'CLIENTPRO' }
    'Home'             { 'CLIENTHOME' }
    'ServerStandard'   { 'SERVERSTANDARD' }
    'ServerDatacenter' { 'SERVERDATACENTER' }
    default            { $Edition.ToUpper() }
}

$destName = "$buildMajor.$buildMinor.Vibranium-X64-$langCode-${edCode}_Updated.iso"
$destPath = Join-Path $OutputDirectory $destName

Write-Log "Moving ISO to: $destPath"
Move-Item -Path $sourceIso.FullName -Destination $destPath -Force

if ($WriteChecksum) {
    Set-Content -Encoding ascii -NoNewline -Path "$destPath.sha256.txt" -Value $checksum
    Write-Log "Checksum written: $destName.sha256.txt"
}

# ── Write metadata JSON ───────────────────────────────────────────────────────

if ($WriteMetadata) {
    $meta = [PSCustomObject]@{
        name               = $WindowsTarget
        title              = $iso.title
        build              = $iso.build
        language           = $Language
        edition            = $Edition
        isoFile            = $destName
        checksum           = $checksum
        createdAt          = (Get-Date).ToUniversalTime().ToString('o')
        uupDumpId          = $iso.id
        downloadPackageUrl = $iso.downloadPackageUrl
    }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutputDirectory "$buildMajor.$buildMinor.json") -Encoding UTF8
    Write-Log "Metadata written: $buildMajor.$buildMinor.json"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

Write-Log "Cleaning up work directory..."
Remove-Item -Force -Recurse $buildDirectory       -ErrorAction SilentlyContinue
Remove-Item -Force "$buildDirectory.zip"          -ErrorAction SilentlyContinue
Remove-Item -Force -Recurse $script:WorkDirectory -ErrorAction SilentlyContinue

Write-Log "Output directory:"
Get-ChildItem $OutputDirectory | Where-Object { -not $_.PSIsContainer } | Sort-Object Name | ForEach-Object {
    Write-Log ("  {0,-60} {1,8} MB" -f $_.Name, [math]::Round($_.Length / 1MB, 1))
}

Write-Log "=================================================="
Write-Log "Done: $destName"
Write-Log "=================================================="

if ($script:UseStatusFile) {
    try { '{"status":"done"}' | Set-Content $script:StatusFilePath -Encoding UTF8 } catch {}
}
