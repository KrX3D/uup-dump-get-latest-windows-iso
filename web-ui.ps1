#!/usr/bin/env pwsh
# web-ui.ps1 — dot-sourced by build-iso.ps1 when MODE=web.
# Starts an HTTP server serving the configuration UI and build trigger API.

function Start-WebUi {
    param(
        [string]$BuildScriptPath,
        [int]$Port = 8080,
        [string]$OutputDirectory = '/output',
        [string]$WorkDirectory   = '/work',
        [string]$LogDirectory    = '/output'
    )

    $script:webBuildScriptPath = $BuildScriptPath
    $script:webOutputDir       = $OutputDirectory
    $script:webWorkDir         = $WorkDirectory
    $script:webLogDir          = $LogDirectory

    # Settings and status live in /config (mountable for persistence).
    # The live build log goes in the log directory (/logs) which is always
    # writable — /config may not be if the user hasn't mapped the volume.
    New-Item -ItemType Directory -Force '/config'      | Out-Null
    New-Item -ItemType Directory -Force $LogDirectory  | Out-Null
    $script:webSettingsPath    = '/config/settings.json'
    $script:webStatusPath      = '/config/build-status.json'
    $script:webCurrentBuildLog = Join-Path $LogDirectory 'current-build.log'

    if (-not (Test-Path $script:webStatusPath)) {
        '{"status":"idle"}' | Set-Content $script:webStatusPath -Encoding UTF8
    }

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://+:$Port/")
    try { $listener.Start() }
    catch {
        Write-Host "[WebUI] Failed to bind to port $Port`: $_"
        return
    }

    Write-Host "[WebUI] Listening on http://0.0.0.0:$Port"
    Write-Host "[WebUI] Open http://<host-ip>:$Port in your browser to configure and start builds."

    while ($listener.IsListening) {
        $task = $null
        try { $task = $listener.GetContextAsync() } catch { break }

        while (-not $task.IsCompleted) { Start-Sleep -Milliseconds 100 }
        if ($task.IsFaulted -or $task.IsCanceled) { continue }

        $ctx = $task.Result
        try   { Invoke-WebRequest-Handler $ctx }
        catch { try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch {} }
    }

    $listener.Stop()
}

function Invoke-WebRequest-Handler {
    param($ctx)
    $req    = $ctx.Request
    $res    = $ctx.Response
    $path   = $req.Url.AbsolutePath.TrimEnd('/')
    if ($path -eq '') { $path = '/' }
    $method = $req.HttpMethod

    try {
        switch ("$method $path") {
            { $_ -in 'GET /', 'GET' }        { Send-WebHtml $res }
            'GET /api/config'                 { Send-WebConfig $res }
            'POST /api/config'                { Set-WebConfig $req $res }
            'GET /api/builds'                 { Send-WebBuilds $req $res }
            'POST /api/start'                 { Start-WebBuild $req $res }
            'POST /api/stop'                  { Stop-WebBuild $res }
            'GET /api/log'                    { Send-WebLog $req $res }
            'GET /api/outputs'                { Send-WebOutputs $res }
            default {
                $res.StatusCode = 404
                Write-WebJson $res @{ error = 'Not found' }
            }
        }
    } finally {
        try { $res.OutputStream.Flush(); $res.Close() } catch {}
    }
}

function Write-WebJson {
    param($res, $obj, [int]$code = 200)
    $res.StatusCode    = $code
    $res.ContentType   = 'application/json; charset=utf-8'
    $json  = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-WebBody {
    param($req)
    (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
}

# ── API handlers ──────────────────────────────────────────────────────────────

function Send-WebHtml {
    param($res)
    $res.ContentType = 'text/html; charset=utf-8'
    $html  = Get-WebUiHtml
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-WebConfig {
    param($res)
    if (Test-Path $script:webSettingsPath) {
        $raw = Get-Content $script:webSettingsPath -Raw -EA SilentlyContinue
        if ($raw) {
            $res.StatusCode  = 200
            $res.ContentType = 'application/json; charset=utf-8'
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            return
        }
    }
    Write-WebJson $res @{
        windowsTarget = 'windows-11'; ring = 'RETAIL'; language = 'de-de'; edition = 'Professional'
        convertConfig = @{ AutoExit=$true; AddUpdates=$false; NetFx3=$true; ResetBase=$true; SkipWinRE=$true; CustomList=$true }
        writeChecksum = $true; writeMetadata = $true
    }
}

function Set-WebConfig {
    param($req, $res)
    $body = Read-WebBody $req
    New-Item -ItemType Directory -Force (Split-Path $script:webSettingsPath) | Out-Null
    $body | Set-Content $script:webSettingsPath -Encoding UTF8
    Write-WebJson $res @{ ok = $true }
}

function Send-WebBuilds {
    param($req, $res)
    $qs     = $req.QueryString
    $target = $qs['target'] ?? 'windows-11'

    $searchMap = @{
        'windows-10'   = 'windows 10 amd64'
        'windows-11'   = 'windows 11 amd64'
        'windows-2022' = 'microsoft server operating system amd64'
    }
    $keepMap = @{
        'windows-10'   = '*windows 10*'
        'windows-11'   = '*windows 11*'
        'windows-2022' = '*microsoft server operating system*'
    }
    $search  = $searchMap[$target] ?? 'windows 11 amd64'
    $keepPat = $keepMap[$target]   ?? '*'

    try {
        $r = Invoke-RestMethod -Method Get -Uri 'https://api.uupdump.net/listid.php' `
            -Body @{ search = $search } -TimeoutSec 20

        $builds = $r.response.builds.PSObject.Properties `
        | Where-Object {
            $t = $_.Value.title
            $t -like $keepPat -and
            $t -notlike '*team*'             -and
            $t -notlike '*insider*'          -and
            $t -notlike '*preview*'          -and
            $t -notlike '*next*'             -and
            $t -notlike '*-KB*'             -and   # KB hotfix/patch entries
            $t -notlike '*.NET Framework*'  -and   # .NET patch entries
            $t -notlike '*Security Update*' -and   # standalone security updates
            $t -notlike '*OOBE Update*'     -and   # OOBE patches
            $t -notlike '*Critical*Update*'        # critical update entries
        } `
        | Sort-Object { [version]$_.Value.build } -Descending `
        | Select-Object -First 25 `
        | ForEach-Object {
            @{
                id    = $_.Value.uuid
                build = $_.Value.build
                title = $_.Value.title
            }
        }
        Write-WebJson $res @($builds)
    } catch {
        Write-WebJson $res @{ error = $_.ToString() } 500
    }
}

function Start-WebBuild {
    param($req, $res)

    # Reject if already running
    if (Test-Path $script:webStatusPath) {
        $st = Get-Content $script:webStatusPath -Raw -EA SilentlyContinue | ConvertFrom-Json -EA SilentlyContinue
        if ($st -and $st.status -eq 'running' -and $st.pid) {
            if (Get-Process -Id ([int]$st.pid) -EA SilentlyContinue) {
                Write-WebJson $res @{ error = 'Build already running' } 409
                return
            }
        }
    }

    # Save settings from request body
    $body = Read-WebBody $req
    if ($body) {
        New-Item -ItemType Directory -Force (Split-Path $script:webSettingsPath) | Out-Null
        $body | Set-Content $script:webSettingsPath -Encoding UTF8
    }
    $cfg = if (Test-Path $script:webSettingsPath) {
        Get-Content $script:webSettingsPath -Raw | ConvertFrom-Json -EA SilentlyContinue
    }

    '' | Set-Content $script:webCurrentBuildLog -Encoding UTF8

    $psArgs = @(
        '-NonInteractive', '-File', $script:webBuildScriptPath,
        '-Mode',            'auto',   # always auto — child must not re-enter web server mode
        '-OutputDirectory', $script:webOutputDir,
        '-WorkDirectory',   $script:webWorkDir,
        '-LogDirectory',    $script:webLogDir,
        '-SettingsFile',    $script:webSettingsPath,
        '-CurrentBuildLog', $script:webCurrentBuildLog
    )
    if ($cfg) {
        if ($cfg.windowsTarget) { $psArgs += '-WindowsTarget', $cfg.windowsTarget }
        if ($cfg.language)      { $psArgs += '-Language',      $cfg.language }
        if ($cfg.edition)       { $psArgs += '-Edition',       $cfg.edition }
        if ($cfg.ring)          { $psArgs += '-Ring',          $cfg.ring }
        if ($cfg.buildId)       { $psArgs += '-BuildId',       $cfg.buildId }
    }

    $proc = Start-Process -FilePath 'pwsh' -ArgumentList $psArgs -NoNewWindow -PassThru

    @{ status = 'running'; pid = $proc.Id; startedAt = (Get-Date -Format 'o') } `
        | ConvertTo-Json | Set-Content $script:webStatusPath -Encoding UTF8

    Write-WebJson $res @{ ok = $true; pid = $proc.Id }
}

function Stop-WebBuild {
    param($res)
    if (Test-Path $script:webStatusPath) {
        $st = Get-Content $script:webStatusPath -Raw -EA SilentlyContinue | ConvertFrom-Json -EA SilentlyContinue
        if ($st -and $st.pid) {
            try { Stop-Process -Id ([int]$st.pid) -Force -EA Stop } catch {}
        }
    }
    @{ status = 'idle' } | ConvertTo-Json | Set-Content $script:webStatusPath -Encoding UTF8
    Write-WebJson $res @{ ok = $true }
}

function Send-WebLog {
    param($req, $res)
    $offset = [int]($req.QueryString['offset'] ?? '0')
    $lines  = @()
    $next   = $offset

    if (Test-Path $script:webCurrentBuildLog) {
        $all = @(Get-Content $script:webCurrentBuildLog -EA SilentlyContinue)
        if ($all.Count -gt $offset) {
            $lines = $all[$offset..($all.Count - 1)]
            $next  = $all.Count
        } else {
            $next = $all.Count
        }
    }

    $status = Get-WebBuildStatus
    Write-WebJson $res @{ lines = $lines; nextOffset = $next; status = $status }
}

function Send-WebOutputs {
    param($res)
    $files = @()
    if (Test-Path $script:webOutputDir) {
        $files = @(
            Get-ChildItem $script:webOutputDir -File -EA SilentlyContinue `
            | Where-Object { $_.Extension -in '.iso', '.json', '.txt' } `
            | Sort-Object LastWriteTimeUtc -Descending `
            | ForEach-Object {
                @{ name = $_.Name; size = $_.Length; modified = $_.LastWriteTimeUtc.ToString('o') }
            }
        )
    }
    Write-WebJson $res @($files)
}

function Get-WebBuildStatus {
    if (-not (Test-Path $script:webStatusPath)) { return 'idle' }
    $raw = Get-Content $script:webStatusPath -Raw -EA SilentlyContinue | ConvertFrom-Json -EA SilentlyContinue
    if (-not $raw) { return 'idle' }
    $status = [string]$raw.status
    # Build script now writes the status file before every exit. As a safety net,
    # if the process is gone but the file still says 'running', mark it failed.
    if ($status -eq 'running' -and $raw.pid) {
        if (-not (Get-Process -Id ([int]$raw.pid) -EA SilentlyContinue)) {
            $status = 'failed'
            ('{"status":"failed"}') | Set-Content $script:webStatusPath -Encoding UTF8 -EA SilentlyContinue
        }
    }
    return $status
}

# ── HTML / JS UI ──────────────────────────────────────────────────────────────

function Get-WebUiHtml {
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>UUP Dump ISO Builder</title>
<style>
:root{--bg:#0d1117;--bg2:#161b22;--bg3:#21262d;--border:#30363d;--text:#c9d1d9;--muted:#8b949e;--accent:#58a6ff;--green:#3fb950;--red:#f85149;--yellow:#e3b341}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font:13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;padding:16px}
h1{font-size:1.15rem;font-weight:600;margin-bottom:14px;color:var(--accent)}
h2{font-size:.68rem;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.08em}
.layout{display:grid;grid-template-columns:350px 1fr;gap:14px;max-width:1400px}
.col{display:flex;flex-direction:column;gap:12px}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:6px;padding:13px}
.card-hdr{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px}
.row{display:flex;gap:8px}
.field{flex:1;min-width:0}
.lbl{display:block;font-size:11px;color:var(--muted);margin-bottom:3px}
select,input[type="text"]{width:100%;padding:5px 8px;background:var(--bg3);border:1px solid var(--border);border-radius:5px;color:var(--text);font-size:12px;margin-bottom:10px}
select:last-child,input:last-child{margin-bottom:0}
select:focus,input:focus{outline:none;border-color:var(--accent)}
.cb{display:flex;align-items:flex-start;gap:7px;padding:5px 0;cursor:pointer;border-bottom:1px solid var(--border)}
.cb:last-child{border-bottom:none}
.cb input[type="checkbox"]{margin-top:2px;width:13px;height:13px;accent-color:var(--accent);flex-shrink:0;cursor:pointer}
.cb .cbl{font-size:12px;display:block}
.cb .cbd{font-size:11px;color:var(--muted);display:block;margin-top:1px}
.apps-grid{display:grid;grid-template-columns:1fr 1fr 1fr 1fr;gap:0}
.apps-grid .cb{border-bottom:none;padding:3px 0}
.apps-grid .cb .cbl{font-size:11px}
.btn{padding:5px 13px;border-radius:5px;border:none;cursor:pointer;font-size:12px;font-weight:500}
.btn:hover{filter:brightness(1.1)}
.btn:disabled{opacity:.4;cursor:not-allowed}
.btn-p{background:var(--accent);color:#0d1117}
.btn-s{background:var(--bg3);color:var(--text);border:1px solid var(--border)}
.btn-d{background:var(--red);color:#fff}
.btn-xs{padding:2px 9px;font-size:11px}
.btn-row{display:flex;gap:7px;align-items:center;margin-top:10px}
.badge{display:inline-flex;align-items:center;gap:5px;padding:2px 9px;border-radius:99px;font-size:11px;font-weight:600}
.b-idle{background:#1c2128;color:var(--muted);border:1px solid var(--border)}
.b-running{background:#1a3c2e;color:var(--green)}
.b-done{background:#1a3c2e;color:var(--green)}
.b-failed{background:#3d1a1a;color:var(--red)}
.dot{width:7px;height:7px;border-radius:50%;background:currentColor;flex-shrink:0}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
.pulsing{animation:pulse 1.4s ease-in-out infinite}
#log{background:#010409;border:1px solid var(--border);border-radius:5px;padding:10px 12px;font:11.5px/1.7 Consolas,"Courier New",monospace;height:calc(100vh - 370px);min-height:280px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.li{color:var(--muted)} .le{color:var(--red)} .lw{color:var(--yellow)} .ls{color:var(--accent);font-weight:600}
.builds-box{border:1px solid var(--border);border-radius:5px;max-height:170px;overflow-y:auto}
.bi{padding:6px 10px;cursor:pointer;border-bottom:1px solid var(--border);font-size:11px}
.bi:last-child{border-bottom:none}
.bi:hover{background:rgba(88,166,255,.07)}
.bi.sel{background:rgba(88,166,255,.13);border-left:2px solid var(--accent)}
.bi .bv{font-weight:600;color:var(--text)}
.bi .br{color:var(--muted);font-size:10px}
.spinner{display:inline-block;width:10px;height:10px;border:2px solid var(--border);border-top-color:var(--accent);border-radius:50%;animation:spin .7s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.toast{position:fixed;bottom:14px;right:14px;padding:6px 14px;border-radius:5px;font-size:12px;font-weight:600;opacity:0;transform:translateY(6px);transition:all .22s;pointer-events:none}
.toast.show{opacity:1;transform:none}
.out-item{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid var(--border);font-size:11px}
.out-item:last-child{border-bottom:none}
.out-item .fn{color:var(--text);font-weight:500;word-break:break-all;padding-right:12px}
.out-item .fs{color:var(--muted);white-space:nowrap}
</style>
</head>
<body>
<h1>UUP Dump ISO Builder</h1>
<div class="layout">

  <!-- ── Left column: settings ── -->
  <div class="col">
    <div class="card">
      <h2 style="margin-bottom:10px">Build Target</h2>
      <div class="row">
        <div class="field"><label class="lbl">OS</label>
          <select id="winTarget">
            <option value="windows-10">Windows 10</option>
            <option value="windows-11" selected>Windows 11</option>
            <option value="windows-2022">Server 2022</option>
          </select></div>
        <div class="field"><label class="lbl">Ring</label>
          <select id="ring">
            <option value="RETAIL" selected>Retail (Stable)</option>
            <option value="RP">Release Preview</option>
            <option value="BETA">Beta</option>
            <option value="DEV">Dev</option>
            <option value="CANARY">Canary</option>
            <option value="ANY">Any</option>
          </select></div>
      </div>
      <div class="row">
        <div class="field"><label class="lbl">Language</label>
          <input type="text" id="language" value="de-de" placeholder="de-de / en-us / fr-fr"></div>
        <div class="field"><label class="lbl">Edition</label>
          <select id="edition">
            <option value="Professional" selected>Professional</option>
            <option value="Home">Home</option>
            <option value="Education">Education</option>
            <option value="Enterprise">Enterprise</option>
            <option value="ServerStandard">Server Standard</option>
            <option value="ServerDatacenter">Server Datacenter</option>
          </select></div>
      </div>
    </div>

    <div class="card">
      <div class="card-hdr">
        <h2>Available Builds</h2>
        <div style="display:flex;gap:5px;align-items:center">
          <span id="bSpin" style="display:none"><span class="spinner"></span></span>
          <button class="btn btn-s btn-xs" onclick="fetchBuilds()">Fetch</button>
          <button class="btn btn-s btn-xs" id="bClear" onclick="clearBuild()" style="display:none">Clear</button>
        </div>
      </div>
      <div style="font-size:11px;color:var(--muted);margin-bottom:7px">
        Click <b>Fetch</b> to list available builds from UUP dump for the selected OS.<br>
        Click a build to <b>pin</b> it — the next build will download that exact version instead of the latest.<br>
        Leave unpinned to always build the newest available release.
      </div>
      <div id="bList" class="builds-box" style="padding:10px;color:var(--muted);font-size:11px">No builds loaded yet.</div>
      <div id="bPin" style="display:none;margin-top:7px;font-size:11px;color:var(--accent)"></div>
    </div>

    <div class="card">
      <h2 style="margin-bottom:10px">Conversion Options</h2>
      <div id="convOpts"></div>
    </div>

    <div class="card">
      <h2 style="margin-bottom:10px">Output Files</h2>
      <div id="outOpts">
        <label class="cb"><input type="checkbox" id="o_chk" checked>
          <span><span class="cbl">Generate .sha256.txt</span><span class="cbd">Write SHA-256 checksum file alongside the ISO</span></span></label>
        <label class="cb"><input type="checkbox" id="o_meta" checked>
          <span><span class="cbl">Generate .json metadata</span><span class="cbd">Write build info JSON (title, build number, UUP dump ID)</span></span></label>
      </div>
    </div>

    <div class="btn-row">
      <button class="btn btn-s" onclick="saveConfig()">Save</button>
      <button class="btn btn-p" id="startBtn" onclick="startBuild()">Start Build</button>
      <button class="btn btn-d" id="stopBtn" onclick="stopBuild()" style="display:none">Stop</button>
    </div>
  </div>

  <!-- ── Right column: apps + log + outputs ── -->
  <div class="col">
    <div class="card">
      <div class="card-hdr">
        <h2>Store Apps to Include</h2>
        <div style="display:flex;gap:5px">
          <button class="btn btn-s btn-xs" onclick="selApps(true)">All</button>
          <button class="btn btn-s btn-xs" onclick="selApps(false)">None</button>
        </div>
      </div>
      <div class="apps-grid" id="appsList"></div>
    </div>

    <div class="card" style="flex:1">
      <div class="card-hdr">
        <h2>Build Log</h2>
        <span class="badge b-idle" id="statusBadge">
          <span class="dot" id="statusDot"></span>
          <span id="statusTxt">Idle</span>
        </span>
      </div>
      <div id="log"></div>
    </div>

    <div class="card">
      <div class="card-hdr">
        <h2>Output Files</h2>
        <button class="btn btn-s btn-xs" onclick="loadOutputs()">Refresh</button>
      </div>
      <div id="outList"><span style="color:var(--muted);font-size:11px">No output files yet</span></div>
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
const COPTS = [
  {k:"AutoExit",   d:true,  l:"Auto-exit when done",     x:"Close automatically when conversion finishes"},
  {k:"AddUpdates", d:false, l:"Include Windows Updates",  x:"Bundle the latest cumulative update into the ISO"},
  {k:"NetFx3",     d:true,  l:".NET Framework 3.5",       x:"Pre-install .NET Framework 3.x (required by some older software)"},
  {k:"ResetBase",  d:true,  l:"Reset component base",     x:"Shrink WinSxS by removing superseded components"},
  {k:"SkipWinRE",  d:true,  l:"Skip Windows RE",          x:"Omit recovery environment — saves ~500 MB on the ISO"},
  {k:"CustomList", d:true,  l:"Use custom apps list",     x:"Apply the app selection to the right instead of the default list"},
];
const APPS = [
  ["Microsoft.Windows.Photos_8wekyb3d8bbwe","Photos"],
  ["Microsoft.WindowsCamera_8wekyb3d8bbwe","Camera"],
  ["Microsoft.WindowsNotepad_8wekyb3d8bbwe","Notepad"],
  ["Microsoft.Paint_8wekyb3d8bbwe","Paint"],
  ["Microsoft.WindowsTerminal_8wekyb3d8bbwe","Terminal"],
  ["MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy","Widgets"],
  ["Microsoft.WindowsAlarms_8wekyb3d8bbwe","Alarms"],
  ["Microsoft.WindowsCalculator_8wekyb3d8bbwe","Calculator"],
  ["Microsoft.WindowsMaps_8wekyb3d8bbwe","Maps"],
  ["Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe","Sticky Notes"],
  ["Microsoft.ScreenSketch_8wekyb3d8bbwe","Snipping Tool"],
  ["microsoft.windowscommunicationsapps_8wekyb3d8bbwe","Mail & Calendar"],
  ["Microsoft.People_8wekyb3d8bbwe","People"],
  ["Microsoft.WindowsFeedbackHub_8wekyb3d8bbwe","Feedback Hub"],
  ["Microsoft.GetHelp_8wekyb3d8bbwe","Get Help"],
  ["Microsoft.Getstarted_8wekyb3d8bbwe","Tips"],
  ["Microsoft.Todos_8wekyb3d8bbwe","To Do"],
  ["Microsoft.PowerAutomateDesktop_8wekyb3d8bbwe","Power Automate"],
  ["Microsoft.549981C3F5F10_8wekyb3d8bbwe","Cortana"],
  ["MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe","Quick Assist"],
  ["MicrosoftCorporationII.MicrosoftFamily_8wekyb3d8bbwe","Family Safety"],
  ["Clipchamp.Clipchamp_yxz26nhyzhsrt","Clipchamp"],
  ["Microsoft.ApplicationCompatibilityEnhancements_8wekyb3d8bbwe","Compat. Enhancements"],
  ["MicrosoftWindows.CrossDevice_cw5n1h2txyewy","Cross Device"],
  ["Microsoft.MicrosoftPCManager_8wekyb3d8bbwe","PC Manager"],
  ["Microsoft.YourPhone_8wekyb3d8bbwe","Phone Link"],
  ["Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe","Voice Recorder"],
  ["Microsoft.StartExperiencesApp_8wekyb3d8bbwe","Start Experience"],
  ["Microsoft.WidgetsPlatformRuntime_8wekyb3d8bbwe","Widgets Runtime"],
  ["Microsoft.WebMediaExtensions_8wekyb3d8bbwe","Web Media Ext."],
  ["Microsoft.RawImageExtension_8wekyb3d8bbwe","Raw Images"],
  ["Microsoft.HEIFImageExtension_8wekyb3d8bbwe","HEIF Images"],
  ["Microsoft.HEVCVideoExtension_8wekyb3d8bbwe","HEVC Video"],
  ["Microsoft.VP9VideoExtensions_8wekyb3d8bbwe","VP9 Video"],
  ["Microsoft.WebpImageExtension_8wekyb3d8bbwe","WebP Images"],
  ["Microsoft.DolbyAudioExtensions_8wekyb3d8bbwe","Dolby Audio"],
  ["Microsoft.AVCEncoderVideoExtension_8wekyb3d8bbwe","AVC Encoder"],
  ["Microsoft.MPEG2VideoExtension_8wekyb3d8bbwe","MPEG-2 Video"],
  ["Microsoft.AV1VideoExtension_8wekyb3d8bbwe","AV1 Video"],
  ["Microsoft.Whiteboard_8wekyb3d8bbwe","Whiteboard"],
  ["microsoft.microsoftskydrive_8wekyb3d8bbwe","OneDrive"],
];

let selBuildId=null, selBuildLabel=null, logOff=0, curStatus="idle";

window.addEventListener("DOMContentLoaded",()=>{
  document.getElementById("convOpts").innerHTML = COPTS.map(o=>
    `<label class="cb"><input type="checkbox" id="c_${o.k}"${o.d?" checked":""}><span><span class="cbl">${o.l}</span><span class="cbd">${o.x}</span></span></label>`
  ).join("");
  renderApps();
  loadConfig();
  loadOutputs();
  setInterval(poll,2000);
});

function renderApps(en){
  const e=en||APPS.map(a=>a[0]);
  document.getElementById("appsList").innerHTML=APPS.map(a=>
    `<label class="cb"><input type="checkbox" class="acb" data-id="${a[0]}"${e.includes(a[0])?" checked":""}><span class="cbl">${a[1]}</span></label>`
  ).join("");
}
function selApps(v){document.querySelectorAll(".acb").forEach(c=>c.checked=v);}

async function loadConfig(){
  try{const r=await fetch("/api/config");if(!r.ok)return;applyConfig(await r.json());}catch{}
}
function applyConfig(c){
  if(!c)return;
  if(c.windowsTarget)document.getElementById("winTarget").value=c.windowsTarget;
  if(c.ring)document.getElementById("ring").value=c.ring;
  if(c.language)document.getElementById("language").value=c.language;
  if(c.edition)document.getElementById("edition").value=c.edition;
  if(c.convertConfig)COPTS.forEach(o=>{const cb=document.getElementById("c_"+o.k);if(cb&&c.convertConfig[o.k]!==undefined)cb.checked=!!c.convertConfig[o.k];});
  if(c.enabledApps)renderApps(c.enabledApps);
  if(c.buildId){selBuildId=c.buildId;selBuildLabel=c.buildLabel||c.buildId;pinBuild();}
  const wc=document.getElementById("o_chk"),wm=document.getElementById("o_meta");
  if(wc&&c.writeChecksum!==undefined)wc.checked=!!c.writeChecksum;
  if(wm&&c.writeMetadata!==undefined)wm.checked=!!c.writeMetadata;
}
function getConfig(){
  const cc={};COPTS.forEach(o=>{cc[o.k]=!!(document.getElementById("c_"+o.k)?.checked);});
  return{
    windowsTarget:document.getElementById("winTarget").value,
    ring:document.getElementById("ring").value,
    language:document.getElementById("language").value,
    edition:document.getElementById("edition").value,
    buildId:selBuildId||null,
    buildLabel:selBuildLabel||null,
    convertConfig:cc,
    enabledApps:[...document.querySelectorAll(".acb:checked")].map(c=>c.dataset.id),
    writeChecksum:document.getElementById("o_chk")?.checked??true,
    writeMetadata:document.getElementById("o_meta")?.checked??true,
  };
}
async function saveConfig(){
  const r=await fetch("/api/config",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(getConfig())});
  if(r.ok)toast("Settings saved");
}
function toast(msg,col){
  const t=document.getElementById("toast");t.textContent=msg;t.style.background=col||"var(--green)";t.style.color=col?"#fff":"#0d1117";
  t.classList.add("show");setTimeout(()=>t.classList.remove("show"),2500);
}

async function fetchBuilds(){
  const t=document.getElementById("winTarget").value,l=document.getElementById("language").value,r=document.getElementById("ring").value;
  const el=document.getElementById("bList"),sp=document.getElementById("bSpin");
  el.innerHTML=`<div style="padding:10px;color:var(--muted)"><span class="spinner"></span> Fetching...</div>`;
  sp.style.display="inline";
  try{
    const res=await fetch(`/api/builds?target=${encodeURIComponent(t)}&lang=${encodeURIComponent(l)}&ring=${encodeURIComponent(r)}`);
    const data=await res.json();
    if(!res.ok||data.error){el.innerHTML=`<div style="padding:10px;color:var(--red)">Error: ${data.error||"Request failed"}</div>`;return;}
    if(!data.length){el.innerHTML=`<div style="padding:10px;color:var(--muted)">No builds found for these criteria</div>`;return;}
    el.innerHTML=data.map(b=>`<div class="bi${b.id===selBuildId?" sel":""}" onclick="pickBuild(${JSON.stringify(b.id)},${JSON.stringify(b.build+" — "+b.title)},this)"><div class="bv">${b.build}</div><div class="br">${b.title}</div></div>`).join("");
  }catch(e){el.innerHTML=`<div style="padding:10px;color:var(--red)">Request failed: ${e.message}</div>`;}
  finally{sp.style.display="none";}
}
function pickBuild(id,label,el){
  document.querySelectorAll(".bi").forEach(e=>e.classList.remove("sel"));
  el.classList.add("sel");selBuildId=id;selBuildLabel=label;pinBuild();
}
function pinBuild(){
  const p=document.getElementById("bPin"),c=document.getElementById("bClear");
  p.style.display="";p.textContent="Pinned: "+selBuildLabel;c.style.display="";
}
function clearBuild(){
  selBuildId=null;selBuildLabel=null;
  document.querySelectorAll(".bi").forEach(e=>e.classList.remove("sel"));
  document.getElementById("bPin").style.display="none";
  document.getElementById("bClear").style.display="none";
}

async function startBuild(){
  if(curStatus==="running")return;
  document.getElementById("startBtn").disabled=true;
  document.getElementById("stopBtn").style.display="";
  logOff=0;document.getElementById("log").innerHTML="";
  const r=await fetch("/api/start",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(getConfig())});
  const j=await r.json();
  if(!r.ok){toast("Error: "+(j.error||"Failed to start"),"var(--red)");document.getElementById("startBtn").disabled=false;document.getElementById("stopBtn").style.display="none";}
}
async function stopBuild(){
  if(!confirm("Stop the running build? Partial downloads are kept for a retry."))return;
  await fetch("/api/stop",{method:"POST"});
  document.getElementById("stopBtn").style.display="none";
  document.getElementById("startBtn").disabled=false;
}

async function poll(){
  try{
    const r=await fetch(`/api/log?offset=${logOff}`);
    const d=await r.json();
    if(d.lines&&d.lines.length){d.lines.forEach(l=>appendLog(l));logOff=d.nextOffset;}
    setStatus(d.status);
  }catch{}
}
function appendLog(line){
  const log=document.getElementById("log");
  const atBot=log.scrollHeight-log.scrollTop<=log.clientHeight+60;
  const d=document.createElement("div");
  d.className=line.includes("[ERROR]")?"le":line.includes("[WARN")?"lw":line.match(/^=/)?"ls":"li";
  d.textContent=line;log.appendChild(d);
  if(atBot)log.scrollTop=log.scrollHeight;
}
function setStatus(s){
  if(s===curStatus)return;curStatus=s||"idle";
  const badge=document.getElementById("statusBadge"),txt=document.getElementById("statusTxt"),dot=document.getElementById("statusDot");
  badge.className="badge b-"+curStatus;
  txt.textContent={idle:"Idle",running:"Building...",done:"Done",failed:"Failed"}[curStatus]||"Idle";
  dot.className="dot"+(curStatus==="running"?" pulsing":"");
  if(curStatus!=="running"){
    document.getElementById("startBtn").disabled=false;
    document.getElementById("stopBtn").style.display="none";
    if(curStatus==="done"){toast("Build complete!");loadOutputs();}
    if(curStatus==="failed")toast("Build failed — check the log","var(--red)");
  }
}
async function loadOutputs(){
  try{
    const r=await fetch("/api/outputs");const files=await r.json();
    const el=document.getElementById("outList");
    if(!files.length){el.innerHTML=`<span style="color:var(--muted);font-size:11px">No output files yet</span>`;return;}
    el.innerHTML=files.map(f=>`<div class="out-item"><span class="fn">${f.name}</span><span class="fs">${(f.size/1024/1024).toFixed(1)} MB</span></div>`).join("");
  }catch{}
}
</script>
</body>
</html>
'@
}
