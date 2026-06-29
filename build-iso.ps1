#!/usr/bin/env pwsh
param(
    [string]$OutputDirectory = '/output',
    [string]$LogDirectory    = '',
    [string]$WindowsTarget   = 'windows-11',
    [string]$Language        = 'de-de',
    [string]$Edition         = 'Professional',
    [string]$Ring            = 'RETAIL'
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

if (-not $LogDirectory) { $LogDirectory = $OutputDirectory }

$script:WorkDirectory  = Join-Path $OutputDirectory '.work'
$WorkDirectory         = $script:WorkDirectory
$script:buildDirectory = $null
$script:RollingLog     = Join-Path $LogDirectory 'uup-dump.log'
$script:RunLogFile     = Join-Path $LogDirectory ('{0}_{1}_{2}_{3}.log' -f
    (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss'), $WindowsTarget, $Language, $Edition)

New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
New-Item -ItemType Directory -Force $LogDirectory    | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try { Add-Content -Path $script:RollingLog -Value $line -Encoding UTF8 } catch {}
    try { Add-Content -Path $script:RunLogFile -Value $line -Encoding UTF8 } catch {}
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
    exit 1
}

Invoke-LogRotate

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

function Get-UupDumpIso([string]$name, [hashtable]$target, [string]$wantRing) {
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

    # Log a discovery table so the user can see which rings/builds are available
    Write-Log "Available builds (newest 15, set WINDOWS_RING to choose a channel):"
    $allBuilds | Select-Object -First 15 | ForEach-Object {
        $r = if ($_.Value.PSObject.Properties.Name -contains 'ring' -and $_.Value.ring) { $_.Value.ring } else { '?' }
        Write-Log ("    {0,-15} {1,-12} {2}" -f $_.Value.build, $r, $_.Value.title)
    }

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

$iso = Get-UupDumpIso $WindowsTarget $TARGETS.$WindowsTarget $Ring

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
    (Get-Date).ToString('yyyy-MM-dd'), $buildMajor, $buildMinor, $WindowsTarget, $Language, $Edition)
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
    $patched = $content -replace '--no-conf\b', '--no-conf --timeout=60 --max-tries=20 --retry-wait=15 --retry-on-http-error=429,500,502,503,504,522,524'
    [System.IO.File]::WriteAllText($linuxScript, $patched)
    & chmod +x $linuxScript
    Write-Log "Patched uup_download_linux.sh: --timeout=60 --max-tries=20 --retry-wait=15 --retry-on-http-error=429,5xx,522"
} else {
    Write-Log "uup_download_linux.sh not found in package — cannot continue" 'ERROR'
    exit 1
}

# ── Run download and conversion ───────────────────────────────────────────────

Write-Log "Starting download and ISO conversion (this may take 1-3 hours)..."
$startTime = Get-Date

Push-Location $buildDirectory
try {
    # Tee-Object writes bash output to both Docker stdout and the per-run log file
    & bash ./uup_download_linux.sh 2>&1 | Tee-Object -Append -FilePath $script:RunLogFile
    if ($LASTEXITCODE -ne 0) {
        throw "uup_download_linux.sh exited with code $LASTEXITCODE"
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
