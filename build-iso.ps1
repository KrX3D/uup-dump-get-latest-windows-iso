#!/usr/bin/env pwsh
param(
    [string]$OutputDirectory = '/output',
    [string]$WindowsTarget   = 'windows-11',
    [string]$Language        = 'de-de',
    [string]$Edition         = 'Professional'
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

$WorkDirectory = Join-Path $OutputDirectory '.work'
$script:buildDirectory = $null

$LogFile = Join-Path $OutputDirectory 'uup-dump.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

function Invoke-LogRotate {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
            $kept = Get-Content $LogFile -Tail 4000
            Set-Content $LogFile -Value $kept -Encoding UTF8
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
    exit 1
}

New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
Invoke-LogRotate

Write-Log "=================================================="
Write-Log "UUP Dump Windows ISO Builder"
Write-Log "Target   : $WindowsTarget"
Write-Log "Language : $Language"
Write-Log "Edition  : $Edition"
Write-Log "Output   : $OutputDirectory"
Write-Log "Work     : $WorkDirectory (cleaned up on exit)"
Write-Log "=================================================="

# ── Version feed ──────────────────────────────────────────────────────────────

Write-Log "Fetching latest version feed..."
$Versions = Invoke-RestMethod -Method Get -Uri 'https://windows.secant.workers.dev'

$TARGETS = @{
    'windows-10' = @{
        search   = "windows 10 $($Versions.'windows-10'.Split('.')[0]) amd64"
        keep     = @('*windows 10*')
        skip     = @('*team*', '*insider*', '*preview*', '*next*')
        editions = @($Edition)
    }
    'windows-11' = @{
        search   = "windows 11 $($Versions.'windows-11'.Split('.')[0]) amd64"
        keep     = @('*windows 11*')
        skip     = @('*team*', '*insider*', '*preview*', '*next*')
        editions = @($Edition)
    }
    'windows-2022' = @{
        search   = "microsoft server operating system $($Versions.'windows-2022'.Split('.')[0]) amd64"
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

function Get-UupDumpIso([string]$name, [hashtable]$target) {
    Write-Log "Searching UUP dump: '$($target.search)'"

    $result = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listid.php' `
        -Body @{ search = $target.search }

    $result.response.builds.PSObject.Properties `
    | Where-Object {
        $t = $_.Value.title
        (($target.keep | ForEach-Object { $t -like $_ }) -notcontains $false) `
          -and (($target.skip | ForEach-Object { $t -like $_ }) -notcontains $true)
    } `
    | ForEach-Object {
        $id = $_.Value.uuid
        Write-Log "Checking build $id..."
        $r = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listlangs.php' -Body @{ id = $id }
        if ($r.response.updateInfo.build -ne $_.Value.build) {
            throw "listlangs returned unexpected build for $id"
        }
        $_.Value | Add-Member -NotePropertyMembers @{
            langs = $r.response.langFancyNames
            info  = $r.response.updateInfo
        }
        $editions = if ($_.Value.langs.PSObject.Properties.Name -eq $Language) {
            $r2 = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listeditions.php' `
                -Body @{ id = $id; lang = $Language }
            $r2.response.editionFancyNames
        } else { [PSCustomObject]@{} }
        $_.Value | Add-Member -NotePropertyMembers @{ editions = $editions }
        $_
    } `
    | Where-Object {
        $_.Value.langs.PSObject.Properties.Name -eq $Language `
          -and (Compare-Object -ExcludeDifferent $target.editions $_.Value.editions.PSObject.Properties.Name).Length `
                -eq $target.editions.Length
    } `
    | Select-Object -First 1 `
    | ForEach-Object {
        $id = $_.Value.uuid
        [PSCustomObject]@{
            name               = $name
            title              = $_.Value.title
            build              = $_.Value.build
            id                 = $id
            downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{
                id      = $id
                pack    = $Language
                edition = $target.editions -join ';'
            })
        }
    }
}

# ── Fetch latest build metadata ───────────────────────────────────────────────

$iso = Get-UupDumpIso $WindowsTarget $TARGETS.$WindowsTarget

if (-not $iso) {
    Write-Log "No matching build found for $WindowsTarget ($Language / $Edition)" 'ERROR'
    exit 1
}

if ($iso.build -notmatch '^\d+\.\d+$') {
    throw "Unexpected build number format: $($iso.build)"
}

Write-Log "Latest build: $($iso.title)  [$($iso.build)]"

$buildMajor = $iso.build.Split('.')[0]
$buildMinor = $iso.build.Split('.')[1]

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

# ── Download UUP conversion package ──────────────────────────────────────────

Write-Log "Downloading UUP package ($($iso.downloadPackageUrl))..."
Invoke-WebRequest -Method Post -Uri $iso.downloadPackageUrl `
    -Body @{ autodl = 2; updates = 1; cleanup = 1 } `
    -OutFile $zipPath

Write-Log "Extracting package..."
Expand-Archive $zipPath $buildDirectory
Remove-Item $zipPath

# ── Configure ConvertConfig.ini ───────────────────────────────────────────────

$configPath = Join-Path $buildDirectory 'ConvertConfig.ini'
Set-Content -Encoding ascii -Path $configPath -Value (
    (Get-Content $configPath) `
    -replace '^(AutoExit\s*)=.*',   '${1}=1' `
    -replace '^(CustomList\s*)=.*', '${1}=1' `
    -replace '^(NetFx3\s*)=.*',     '${1}=1' `
    -replace '^(ResetBase\s*)=.*',  '${1}=1' `
    -replace '^(SkipWinRE\s*)=.*',  '${1}=1'
)
Write-Log "ConvertConfig.ini: AutoExit=1 CustomList=1 NetFx3=1 ResetBase=1 SkipWinRE=1"

# ── Configure CustomAppsList.txt ──────────────────────────────────────────────

$appsPath = Join-Path $buildDirectory 'CustomAppsList.txt'
Set-Content -Encoding ascii -Path $appsPath -Value (
    (Get-Content $appsPath) `
    -replace '^\s*#\s*(Microsoft\.Windows\.Photos_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WindowsCamera_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WindowsNotepad_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.Paint_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WindowsTerminal_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(MicrosoftWindows\.Client\.WebExperience_cw5n1h2txyewy)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WindowsAlarms_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WindowsCalculator_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WindowsMaps_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.MicrosoftStickyNotes_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.ScreenSketch_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(microsoft\.windowscommunicationsapps_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.People_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WindowsFeedbackHub_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.GetHelp_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.Getstarted_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.Todos_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.PowerAutomateDesktop_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.549981C3F5F10_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(MicrosoftCorporationII\.QuickAssist_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(MicrosoftCorporationII\.MicrosoftFamily_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Clipchamp\.Clipchamp_yxz26nhyzhsrt)', '$1' `
    -replace '^\s*#\s*(Microsoft\.ApplicationCompatibilityEnhancements_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(MicrosoftWindows\.CrossDevice_cw5n1h2txyewy)', '$1' `
    -replace '^\s*#\s*(Microsoft\.MicrosoftPCManager_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.YourPhone_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WindowsSoundRecorder_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.StartExperiencesApp_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WidgetsPlatformRuntime_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WebMediaExtensions_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.RawImageExtension_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.HEIFImageExtension_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.HEVCVideoExtension_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.VP9VideoExtensions_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.WebpImageExtension_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.DolbyAudioExtensions_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.AVCEncoderVideoExtension_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.MPEG2VideoExtension_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.AV1VideoExtension_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(Microsoft\.Whiteboard_8wekyb3d8bbwe)', '$1' `
    -replace '^\s*#\s*(microsoft\.microsoftskydrive_8wekyb3d8bbwe)', '$1'
)
Write-Log "CustomAppsList.txt: enabled standard Store apps"

# ── Patch aria2 flags in the Linux download script ───────────────────────────

$linuxScript = Join-Path $buildDirectory 'uup_download_linux.sh'
if (Test-Path $linuxScript) {
    $content = [System.IO.File]::ReadAllText($linuxScript)
    $patched = $content -replace '--no-conf\b', '--no-conf --timeout=30 --max-tries=10 --retry-wait=5'
    [System.IO.File]::WriteAllText($linuxScript, $patched)
    & chmod +x $linuxScript
    Write-Log "Patched uup_download_linux.sh: --timeout=30 --max-tries=10 --retry-wait=5"
} else {
    Write-Log "uup_download_linux.sh not found in package — cannot continue" 'ERROR'
    exit 1
}

# ── Run download and conversion ───────────────────────────────────────────────

Write-Log "Starting download and ISO conversion (this may take 1-3 hours)..."
$startTime = Get-Date

Push-Location $buildDirectory
try {
    $proc = Start-Process -FilePath 'bash' -ArgumentList './uup_download_linux.sh' `
        -NoNewWindow -PassThru -Wait
    if ($proc.ExitCode -ne 0) {
        throw "uup_download_linux.sh exited with code $($proc.ExitCode)"
    }
} finally {
    Pop-Location
}

$elapsed = (Get-Date) - $startTime
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
    'Professional'   { 'CLIENTPRO' }
    'Home'           { 'CLIENTHOME' }
    'ServerStandard' { 'SERVERSTANDARD' }
    'ServerDatacenter' { 'SERVERDATACENTER' }
    default          { $Edition.ToUpper() }
}

$destName = "$buildMajor.$buildMinor.Vibranium-X64-$langCode-${edCode}_Updated.iso"
$destPath = Join-Path $OutputDirectory $destName

Write-Log "Moving ISO to: $destPath"
Move-Item -Path $sourceIso.FullName -Destination $destPath -Force

Set-Content -Encoding ascii -NoNewline -Path "$destPath.sha256.txt" -Value $checksum

# ── Write metadata JSON ───────────────────────────────────────────────────────

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

# ── Cleanup ───────────────────────────────────────────────────────────────────

Write-Log "Cleaning up work directory..."
Remove-Item -Force -Recurse $buildDirectory -ErrorAction SilentlyContinue
Remove-Item -Force "$buildDirectory.zip"    -ErrorAction SilentlyContinue

Write-Log "Output directory:"
Get-ChildItem $OutputDirectory | Where-Object { -not $_.PSIsContainer } | Sort-Object Name | ForEach-Object {
    Write-Log ("  {0,-60} {1,8} MB" -f $_.Name, [math]::Round($_.Length / 1MB, 1))
}

Write-Log "=================================================="
Write-Log "Done: $destName"
Write-Log "=================================================="
