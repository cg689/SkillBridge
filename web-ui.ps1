# web-ui.ps1 — a local dashboard for SkillBridge (Windows, PowerShell 5.1 compatible).
#
# Serves one self-contained HTML page on http://localhost:<port>/ and a small
# JSON API next to it, so the whole state of the sync can be looked at (and
# driven) from a browser instead of reading sync-skills.log by hand:
#
#   GET  /              the dashboard (web-ui.html, token injected)
#   GET  /assets/*      the vendored fonts / icon library / animation library,
#                        and the brand icon for the browser tab
#   GET  /api/status    one snapshot: source, every target, last run
#   GET  /api/skills    every source skill: description, size, where it landed
#   POST /api/sync      run sync-skills.ps1 and return its output
#   GET  /api/log       the tail of sync-skills.log
#   POST /api/db-check  compare the skills folder with cc-switch.db (report only)
#   POST /api/scan-tools  find the agent tools installed here and add the
#                         missing ones to config.json's targets (additive)
#   POST /api/skills/delete   remove one skill folder from the source
#   POST /api/skills/add      install the skills inside an uploaded .zip
#   POST /api/stop      shut the server down
#
# Security has two layers, both of them load-bearing:
#
#   1. The listening sockets are bound to 127.0.0.1 (plus ::1 when the stack has
#      it) and to nothing else. This is why the server is a plain TcpListener
#      instead of HttpListener: HTTP.sys opens a WILDCARD socket for the port
#      whatever prefixes you give it and does its own routing on the Host header,
#      so a client on the LAN that sends "Host: localhost:<port>" is served the
#      dashboard - and with it the token. Measured on this machine: HttpListener
#      200s that request, this listener refuses the connection at TCP level.
#
#   2. Every /api/ call must carry the per-start token the page was served with.
#      That is what stops an unrelated web page open in the same browser from
#      POSTing a sync at us (CSRF). The page on / is the only place the token is
#      written, and a fresh one is minted on every start.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\web-ui.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\web-ui.ps1 -Port 9001 -NoBrowser
param(
    [int]$Port = 8765,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force

$Root    = $PSScriptRoot
$LogFile = Join-Path $Root 'sync-skills.log'
# Per-start token. Anyone holding it already has this page, so it is not a
# secret - it only proves a request came from the page we served, not from
# another site's JavaScript running in the same browser.
$Token   = [Guid]::NewGuid().ToString('N')

function Write-ServerLine {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Text) -ForegroundColor $Color
}

# --------------------------------------------------------------- transport ---
# Minimal HTTP/1.1: parse the request head, hand a hash to Handle-Request, write
# one response, close. Every response says `Connection: close`, so nothing here
# has to keep state between requests and the browser never holds a socket the
# loop needs.

$script:Reasons = @{
    200 = 'OK'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'
    405 = 'Method Not Allowed'; 411 = 'Length Required'; 413 = 'Payload Too Large'
    500 = 'Internal Server Error'
}
# A request body is only ever a base64 zip inside JSON. 32 MB of zip is ~44 MB
# of text once encoded, so this ceiling leaves room for the JSON around it and
# refuses before the process has to buffer more.
$MaxBodyBytes = 50331648   # 48 MB

# The four files web-ui.html loads from /assets/, plus the brand icon the tab
# shows. Exact names, exact MIME types: a whitelist, not a directory listing,
# so there is nothing for a traversal attempt to name. Serving them is
# deliberately NOT behind the token gate — they are the same bytes for every
# visitor and hiding them breaks nothing except the page itself, while the
# token's job is to stop other sites from acting on the skills, which only the
# /api/ routes do.
$script:StaticFiles = [ordered]@{
    'assets/vendor/motion.min.js'             = 'text/javascript; charset=utf-8'
    'assets/vendor/lucide.min.js'             = 'text/javascript; charset=utf-8'
    'assets/vendor/inter-var.woff2'           = 'font/woff2'
    'assets/vendor/jetbrains-mono-var.woff2'  = 'font/woff2'
    'assets/brand/skillbridge.svg'            = 'image/svg+xml'
}

function Send-Response {
    param(
        $Context,
        [int]$Code = 200,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [string]$Body = '',
        # Binary body (fonts). Kept separate from $Body so a font is never
        # round-tripped through a string and back.
        [byte[]]$Raw,
        [switch]$NoCache
    )
    $bytes = if ($null -ne $Raw) { $Raw } else { [Text.Encoding]::UTF8.GetBytes($Body) }
    $reason = $script:Reasons[$Code]
    if (-not $reason) { $reason = 'OK' }
    $head = New-Object System.Text.StringBuilder
    [void]$head.Append("HTTP/1.1 $Code $reason`r`n")
    [void]$head.Append("Content-Type: $ContentType`r`n")
    [void]$head.Append("Content-Length: $($bytes.Length)`r`n")
    if ($NoCache) { [void]$head.Append('Cache-Control: no-store' + "`r`n") }
    # The page is served over the loopback addresses only, so the browser never
    # needs a cached copy: stale status is worse than a re-fetch.
    [void]$head.Append("Connection: close`r`n`r`n")
    try {
        $stream = $Context.Client.GetStream()
        $headBytes = [Text.Encoding]::ASCII.GetBytes($head.ToString())
        $stream.Write($headBytes, 0, $headBytes.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $stream.Close()
    } catch {
        # The client went away (tab closed, request aborted): a response nobody
        # reads. Log it anyway - a silent write failure here is indistinguishable
        # from a bug in this function, and telling those apart matters.
        Write-ServerLine "response write failed: $($_.Exception.Message)" 'Red'
    }
}

function Send-Json {
    param($Context, $Value, [int]$Code = 200)
    $json = ($Value | ConvertTo-Json -Depth 8 -Compress)
    Send-Response -Context $Context -Code $Code -ContentType 'application/json; charset=utf-8' -Body $json -NoCache
}

function Read-Request {
    # Read ONE request from a connected client. Returns $null when the peer sent
    # nothing usable (an empty probe, a browser that navigated away mid-connect).
    param($Client)
    $stream = $Client.GetStream()
    $buffer = New-Object 'byte[]' 8192
    $ms     = New-Object IO.MemoryStream
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        # Read blocks until a byte arrives; $Client.ReceiveTimeout (set on accept)
        # turns "connected and never wrote anything" into an exception instead of
        # a permanently hung server.
        $n = $stream.Read($buffer, 0, $buffer.Length)
        if ($n -le 0) { break }
        $ms.Write($buffer, 0, $n)
        if ($ms.Length -gt 65536) { break }  # a request head is never this big
        $probe = [Text.Encoding]::ASCII.GetString($ms.ToArray())
        if ($probe.Contains("`r`n`r`n")) { break }
    }
    $all = $ms.ToArray()
    if ($all.Length -eq 0) { return $null }
    $headText = [Text.Encoding]::UTF8.GetString($all)
    $split = $headText.IndexOf("`r`n`r`n")
    if ($split -lt 0) { return $null }

    $lines = $headText.Substring(0, $split) -split "`r?`n"
    $parts = ($lines[0] -split '\s+', 3)
    if ($parts.Count -lt 2) { return $null }
    $headers = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^([^:]+):\s*(.*)$') {
            $headers[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    # A client that will wait for "100 Continue" before sending its body must be
    # answered first, or it stalls and this read blocks until the deadline.
    if ($headers['Expect'] -match '100-continue') {
        try {
            $ack = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
            $stream.Write($ack, 0, $ack.Length)
            $stream.Flush()
        } catch { }
    }

    $bodyStart  = $split + 4
    $leftover   = [Math]::Max(0, $all.Length - $bodyStart)
    $bodyLength = 0
    if ($headers['Content-Length']) {
        $parsed = 0
        if ([int]::TryParse($headers['Content-Length'], [ref]$parsed)) { $bodyLength = $parsed }
    }
    # Chunked only ever shows up here if a caller hands no Content-Length; this
    # API needs no request body at all, so refuse it the way HTTP.sys used to.
    $chunked = ($headers['Transfer-Encoding'] -match 'chunked')

    # Drain the body even though nothing reads it: closing a socket with unread
    # bytes pending makes TCP send RST, and the client can lose the response we
    # are about to write.
    $bodyBytes = @()
    $bodyTooBig = $false
    if (-not $chunked -and $bodyLength -gt 0) {
        # Bound the allocation before allocating it. The only body this API
        # takes is a base64 zip inside JSON: 32 MB of zip is ~44 MB of text, so
        # anything past this is refused instead of buffered — but the socket is
        # still drained first, or the client never sees the refusal.
        $readLength = $bodyLength
        if ($bodyLength -gt $MaxBodyBytes) {
            $readLength = $MaxBodyBytes
            $bodyTooBig = $true
        }
        $bodyBuffer = New-Object 'byte[]' $readLength
        $got = if ($leftover -gt 0) { [Math]::Min($leftover, $readLength) } else { 0 }
        if ($got -gt 0) { [Array]::Copy($all, $bodyStart, $bodyBuffer, 0, $got) }
        $bodyDeadline = (Get-Date).AddSeconds(20)
        while ($got -lt $readLength -and (Get-Date) -lt $bodyDeadline) {
            $n = $stream.Read($bodyBuffer, $got, $readLength - $got)
            if ($n -le 0) { break }
            $got += $n
        }
        $bodyBytes = $bodyBuffer
        if ($bodyTooBig) {
            # Swallow the rest without keeping it.
            $drain = New-Object 'byte[]' 65536
            $drained = $got
            while ($drained -lt $bodyLength -and (Get-Date) -lt $bodyDeadline) {
                $n = $stream.Read($drain, 0, [Math]::Min(65536, $bodyLength - $drained))
                if ($n -le 0) { break }
                $drained += $n
            }
        }
    }

    $target = $parts[1]
    $path   = $target
    $query  = ''
    $qmark  = $target.IndexOf('?')
    if ($qmark -ge 0) {
        $path  = $target.Substring(0, $qmark)
        $query = $target.Substring($qmark + 1)
    }
    if ($path.Length -gt 1) { $path = $path.TrimEnd('/') }
    if ($path -eq '') { $path = '/' }

    return [pscustomobject]@{
        Client  = $Client
        method  = $parts[0].ToUpperInvariant()
        path    = $path
        query   = $query
        headers = $headers
        chunked   = $chunked
        body      = $bodyBytes
        bodyTooBig = $bodyTooBig
    }
}

function Get-LogTail {
    # $AllLines is deliberately NOT called $lines: PowerShell variables are
    # case-insensitive, so `$lines` would silently overwrite the [int] $Lines
    # parameter and Select-Object -Last would fail to bind it.
    param([int]$Lines = 200)
    if (-not (Test-Path -LiteralPath $LogFile)) {
        return [pscustomobject]@{ exists = $false; total = 0; lines = @() }
    }
    # Get-Content decodes as ANSI under 5.1, which turns the Chinese lines
    # check-db-sync.py appends into mojibake. Read the bytes as UTF-8 instead.
    $text     = [IO.File]::ReadAllText($LogFile, [Text.Encoding]::UTF8)
    $allLines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
    $tail     = @($allLines | Select-Object -Last $Lines)
    return [pscustomobject]@{ exists = $true; total = $allLines.Count; lines = $tail }
}

function Invoke-Sync {
    # Run in a child process: the server keeps no state about a sync, and the
    # exit code / trap inside sync-skills.ps1 stay the single source of truth.
    $script = Join-Path $Root 'sync-skills.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        return [pscustomobject]@{ ran = $false; error = "sync-skills.ps1 not found: $script" }
    }
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -ConfigPath $ConfigPath 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = -1 }
    return [pscustomobject]@{
        ran       = $true
        ok        = ($code -eq 0)
        exit_code = $code
        output    = (($out -replace "`r?`n", "`n").Trim())
        status    = (Read-RunStatus (Get-RunStatusPath $LogFile))
    }
}

function Invoke-DbCheck {
    # Report only. check-db-sync.py --fix deletes rows from CC Switch's own
    # database, and a row is the only record of a skill's origin, so no
    # automatic caller is ever allowed to pass it.
    $py        = Resolve-PythonExe
    $pyScript  = Join-Path $Root 'check-db-sync.py'
    if (-not $py -or -not (Test-Path -LiteralPath $pyScript)) {
        return [pscustomobject]@{ ran = $false; error = 'python or check-db-sync.py not found' }
    }
    $db = Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db'
    if (-not (Test-Path -LiteralPath $db)) {
        return [pscustomobject]@{ ran = $false; error = "database not found: $db" }
    }
    $snap = Get-SkillBridgeStatus -ConfigPath $ConfigPath -SkipFingerprints
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    $out = & $py $pyScript --source $snap.source --db $db 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = -1 }
    return [pscustomobject]@{
        ran       = $true
        ok        = ($code -eq 0)
        exit_code = $code
        output    = (($out -replace "`r?`n", "`n").Trim())
    }
}

function Read-JsonField {
    # Reads one string field out of a small JSON request body. A malformed body
    # returns '' rather than throwing: the caller answers 400, not a stack trace.
    param([byte[]]$Body, [string]$Field)
    if ($null -eq $Body -or $Body.Length -eq 0) { return '' }
    try {
        $obj = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
    } catch { return '' }
    if ($null -eq $obj) { return '' }
    $prop = $obj.PSObject.Properties[$Field]
    if ($null -eq $prop -or $null -eq $prop.Value) { return '' }
    return ([string]$prop.Value).Trim()
}

function Read-Base64Field {
    # Reads the "data" field (a base64 zip) out of the request body, or $null
    # when it is missing or not valid base64. $null is the only "no" this
    # answers on purpose: an empty array is a valid body that carries no zip.
    param([byte[]]$Body)
    if ($null -eq $Body -or $Body.Length -eq 0) { return $null }
    try {
        $obj = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
    } catch { return $null }
    if ($null -eq $obj) { return $null }
    $prop = $obj.PSObject.Properties['data']
    if ($null -eq $prop -or $null -eq $prop.Value) { return $null }
    $b64 = (([string]$prop.Value) -replace '\s', '')
    if (-not $b64) { return $null }
    try { return [Convert]::FromBase64String($b64) } catch { return $null }
}

function Handle-Request {
    param($req)
    if ($req.path -eq '/') {
        # -NoCache: the HTML is inlined into the process at startup, so a browser
        # that keeps a copy shows the previous build after the server is
        # restarted. The comment on Send-Response already covers why caching a
        # loopback-only page buys nothing.
        Send-Response -Context $req -ContentType 'text/html; charset=utf-8' -Body $script:Page -NoCache
        return
    }

    # The fonts, the icon library and the animation library. Only names in the
    # whitelist above can be answered, and the resolved path is re-checked to sit
    # under the repo root before anything is read off disk.
    if ($req.path -like '/assets/*') {
        if ($req.method -ne 'GET') {
            Send-Json -Context $req -Code 405 -Value @{ error = 'GET only' }
            return
        }
        $rel = $req.path.TrimStart('/')
        $full = Join-Path $Root ($rel -replace '/', '\')
        $resolved = [IO.Path]::GetFullPath($full)
        # An ordered dictionary has Contains, not ContainsKey: the hashtable
        # spelling would throw (and answer 500) on every asset request.
        if (-not $script:StaticFiles.Contains($rel) -or
            $rel -notmatch '^[a-z0-9/._-]+$' -or
            -not $resolved.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
            Send-Json -Context $req -Code 404 -Value @{ error = "not found: $($req.path)" }
            return
        }
        if (-not (Test-Path -LiteralPath $resolved)) {
            Send-Json -Context $req -Code 404 -Value @{ error = "not installed: $rel" }
            return
        }
        # no-store, not immutable: the point of these files is that they can be
        # swapped for a newer version, and a browser holding a year-old copy of
        # lucide would make that a silent no-op.
        Send-Response -Context $req -ContentType $script:StaticFiles[$rel] -Raw ([IO.File]::ReadAllBytes($resolved)) -NoCache
        return
    }

    # Everything below is an action: prove the caller is our own page.
    if (-not $req.headers.ContainsKey('X-SB-Token') -or $req.headers['X-SB-Token'] -ne $script:Token) {
        Write-ServerLine "403 $($req.method) $($req.path) (missing/incorrect token)"
        Send-Json -Context $req -Code 403 -Value @{ error = 'bad or missing X-SB-Token' }
        return
    }
    if ($req.chunked) {
        Send-Json -Context $req -Code 411 -Value @{ error = 'send Content-Length, not chunked' }
        return
    }
    if ($req.bodyTooBig) {
        Send-Json -Context $req -Code 413 -Value @{ error = "the request body is over the $($MaxBodyBytes / 1MB) MB limit" }
        return
    }

    switch -Regex ($req.path) {
        '^/api/status$' {
            Send-Json -Context $req -Value (Get-SkillBridgeStatus -ConfigPath $ConfigPath)
            return
        }
        '^/api/skills$' {
            # Fetched on demand only: it reads every SKILL.md and walks every
            # skill folder, which is far more work than the 15-second poll pays.
            Send-Json -Context $req -Value (Get-SkillBridgeSkills -ConfigPath $ConfigPath)
            return
        }
        '^/api/log$' {
            $lines = 200
            # The query is everything AFTER the '?' and is '&'-separated, so the
            # anchor has to be "start of string" or '&' - never '?'.
            if ($req.query -match '(?:^|&)lines=(\d+)') {
                $lines = [Math]::Min(2000, [int]$Matches[1])
            }
            Send-Json -Context $req -Value (Get-LogTail -Lines $lines)
            return
        }
        '^/api/sync$' {
            if ($req.method -ne 'POST') {
                Send-Json -Context $req -Code 405 -Value @{ error = 'POST only' }
                return
            }
            Write-ServerLine 'sync requested' 'Cyan'
            $result = Invoke-Sync
            Write-ServerLine ("sync finished: exit={0}" -f $result.exit_code) $(if ($result.ok) { 'Green' } else { 'Red' })
            Send-Json -Context $req -Value $result
            return
        }
        '^/api/db-check$' {
            if ($req.method -ne 'POST') {
                Send-Json -Context $req -Code 405 -Value @{ error = 'POST only' }
                return
            }
            Write-ServerLine 'database check requested' 'Cyan'
            Send-Json -Context $req -Value (Invoke-DbCheck)
            return
        }
        '^/api/scan-tools$' {
            if ($req.method -ne 'POST') {
                Send-Json -Context $req -Code 405 -Value @{ error = 'POST only' }
                return
            }
            # Same catalog and marker checks detect-tools.ps1 runs, but additive:
            # the answer to "which agent software is installed here" must not
            # cost the user a target whose marker directory is merely absent, nor
            # re-add one that `exclude` removed on purpose.
            Write-ServerLine 'tool scan requested' 'Cyan'
            $result = Merge-SkillBridgeToolTargets -ConfigPath $ConfigPath
            if ($result.ok) {
                if ($result.wrote) {
                    Write-ServerLine ('tool scan added: ' + (@($result.added) -join ', ')) 'Green'
                } else {
                    Write-ServerLine 'tool scan: every installed tool is already a target' 'Gray'
                }
            } else {
                Write-ServerLine ("tool scan failed: $($result.error)") 'Red'
            }
            Send-Json -Context $req -Value $result
            return
        }
        '^/api/stop$' {
            Send-Json -Context $req -Value @{ stopping = $true }
            $script:Stopping = $true
            return
        }
        '^/api/skills/delete$' {
            # Deleting a source skill is destructive and there is no undo, so the
            # route itself does nothing clever: it only forwards the caller's
            # decision to common.psm1, which re-checks everything (name, that the
            # folder is a skill) and reports what it removed.
            if ($req.method -ne 'POST') {
                Send-Json -Context $req -Code 405 -Value @{ error = 'POST only' }
                return
            }
            $name = Read-JsonField -Body $req.body -Field 'name'
            if (-not $name) {
                Send-Json -Context $req -Code 400 -Value @{ error = 'send JSON with a "name" field' }
                return
            }
            Write-ServerLine "delete requested: $name" 'Yellow'
            $result = Remove-SkillBridgeSkill -Name $name -ConfigPath $ConfigPath
            if ($result.ok) {
                Write-ServerLine ("deleted {0}: {1} files, {2:N0} bytes" -f $result.name, $result.files, $result.size) 'Green'
            } else {
                Write-ServerLine ("delete refused ({0}): {1}" -f $name, $result.error) 'Red'
            }
            Send-Json -Context $req -Value $result
            return
        }
        '^/api/skills/add$' {
            if ($req.method -ne 'POST') {
                Send-Json -Context $req -Code 405 -Value @{ error = 'POST only' }
                return
            }
            $bytes = Read-Base64Field -Body $req.body
            if ($null -eq $bytes) {
                Send-Json -Context $req -Code 400 -Value @{ error = 'send JSON with a base64 "data" field' }
                return
            }
            Write-ServerLine ("import requested: {0:N1} KB of package" -f ($bytes.Length / 1KB)) 'Cyan'
            $result = Import-SkillBridgeSkillZip -Bytes $bytes -ConfigPath $ConfigPath
            if ($result.ok) {
                Write-ServerLine ("imported: " + (($result.added) -join ', ')) 'Green'
            } else {
                # No prefix: common.psm1 already says what went wrong, and a
                # doubled prefix ("import failed: import failed: ...") reads like
                # two failures.
                Write-ServerLine $result.error 'Red'
            }
            foreach ($w in @($result.warnings)) { Write-ServerLine ("import warning: " + $w) 'Yellow' }
            Send-Json -Context $req -Value $result
            return
        }
    }
    Send-Json -Context $req -Code 404 -Value @{ error = "not found: $($req.path)" }
}

# ---------------------------------------------------------------- listener ---
$pagePath = Join-Path $Root 'web-ui.html'
if (-not (Test-Path -LiteralPath $pagePath)) {
    Write-Host "[ERROR] web-ui.html not found next to web-ui.ps1: $pagePath" -ForegroundColor Red
    exit 1
}
$script:Page = ([IO.File]::ReadAllText($pagePath, [Text.Encoding]::UTF8)).Replace('__SB_TOKEN__', $Token)
$script:Stopping = $false

# Loopback only. Two listeners because the browser may resolve `localhost` to
# ::1 first and would otherwise wait out its fallback before the page loads.
$script:Listeners = @()
try {
    $v4 = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $Port
    $v4.Start()
    $script:Listeners += $v4
} catch {
    Write-ServerLine ("cannot listen on 127.0.0.1:{0} : {1}" -f $Port, $_.Exception.Message) 'Red'
}
try {
    $v6 = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::IPv6Loopback), $Port
    $v6.Start()
    $script:Listeners += $v6
} catch {
    # No IPv6 stack (or the port is IPv4-only). The page falls back to 127.0.0.1.
}
if ($script:Listeners.Count -eq 0) {
    Write-Host ''
    Write-Host "[ERROR] could not open port $Port. Another SkillBridge UI (or another" -ForegroundColor Red
    Write-Host "        program) may already be using it. Try: -Port <another number>" -ForegroundColor Red
    exit 1
}

$url = "http://localhost:$Port/"
Write-Host ''
Write-Host '  SkillBridge Web UI' -ForegroundColor Cyan
Write-Host "  $url" -ForegroundColor White
Write-Host ''
Write-ServerLine 'listening (loopback only: 127.0.0.1 / ::1)'
Write-ServerLine 'press Ctrl+C, or use the 停止服务 button, to shut down'

if (-not $NoBrowser) {
    try { Start-Process $url } catch { }
}

try {
    while (-not $script:Stopping) {
        $client = $null
        foreach ($l in $script:Listeners) {
            if ($l.Pending()) { $client = $l.AcceptTcpClient(); break }
        }
        if ($null -eq $client) { Start-Sleep -Milliseconds 20; continue }
        try {
            # A client that connects and sends nothing (or a scanner) must not
            # wedge the single-threaded loop; 20s of silence and it is dropped.
            $client.ReceiveTimeout = 20000
            $client.SendTimeout    = 20000
            # One request at a time. Every response closes its connection, so the
            # browser is never left holding a socket this loop needs.
            $request = Read-Request $client
            if ($null -ne $request) { Handle-Request $request }
        } catch {
            # A broken request (client aborted, serialization error) must not
            # take the server down with it.
            Write-ServerLine "request failed: $($_.Exception.Message)" 'Red'
            try { Send-Json -Context @{ Client = $client } -Code 500 -Value @{ error = $_.Exception.Message } } catch { }
        } finally {
            try { $client.Close() } catch { }
        }
    }
} finally {
    foreach ($l in $script:Listeners) { try { $l.Stop() } catch { } }
    Write-ServerLine 'stopped'
}
