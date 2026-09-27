# tests/smoke-webui.ps1 — API smoke test for web-ui.ps1 (the local dashboard).
#
# Starts web-ui.ps1 on a free loopback port against a THROWAWAY config (temp
# source plus one link target and one copy target) and then drives every
# endpoint exactly the way web-ui.html does, asserting:
#
#   * / serves the page with the per-start token already substituted in
#     (no __SB_TOKEN__ placeholder survives)
#   * every /api/ call WITHOUT that token is refused with 403 — that gate is the
#     whole CSRF defence, so it must not depend on which method or path is used
#   * GET /api/sync and GET /api/db-check are 405: both run something
#   * an unknown /api/ path with a valid token is 404
#   * GET /api/status is the shared snapshot (source, skill count, per-target
#     linked/missing) and it changes as the sync lands
#   * GET /api/skills is the skill browser's payload: description folded out of
#     the SKILL.md frontmatter, file count/size, and per-target link/copy/missing
#     (asserted before AND after the sync, when the kinds change)
#   * GET /api/log?lines=N honours the tail size
#   * POST /api/sync really runs sync-skills.ps1: the junction and the copy
#     appear on disk, exit code 0, and the run record is refreshed
#   * POST /api/db-check is report-only: cc-switch.db is byte-identical after it,
#     even when the check finds drift
#   * the listener is bound to loopback only, never 0.0.0.0
#   * POST /api/stop actually shuts the server down, cleanly
#
# Every assertion is one that can fail: if a command produced no output at all
# the test throws instead of passing (a `-notmatch` on an empty string is true).
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-webui.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# sync-skills.ps1 writes the repo's log and its run record, and the dashboard
# runs it. Back both up and restore them byte for byte.
$log = Join-Path $root 'sync-skills.log'
$logBackup = if (Test-Path $log) { [IO.File]::ReadAllBytes($log) } else { $null }
Import-Module (Join-Path $root 'common.psm1') -Force
$statusFile = Get-RunStatusPath $log
$statusBackup = if (Test-Path $statusFile) { [IO.File]::ReadAllBytes($statusFile) } else { $null }
# A warn/fail run record pops a toast on the machine running the suite.
$prevNoNotify = $env:SKILLBRIDGE_NO_NOTIFY
$env:SKILLBRIDGE_NO_NOTIFY = '1'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('sb-webui-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'src\demo-skill') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'tgt\own-skill') -Force | Out-Null
# A folded (`>-`) description on purpose: that is the shape the real skills use,
# and /api/skills has to join the indented lines into one line for the UI.
Set-Content -Path (Join-Path $tmp 'src\demo-skill\SKILL.md') -Value @'
---
name: demo-skill
description: >-
  冒烟测试用的技能。第一行描述，
  第二行仍然是同一段描述。
---
# demo
'@ -Encoding UTF8

$cfg = @{
    link_type = 'junction'
    source    = (Join-Path $tmp 'src')
    targets   = @{
        WebUi     = (Join-Path $tmp 'tgt')
        WebUiCopy = @{
            path = (Join-Path $tmp 'tgt-copy')
            mode = 'copy'
        }
    }
    # Off: the fixture source is not the real skills folder, so comparing it
    # against the real cc-switch.db would be pure noise. The db-check endpoint
    # is exercised on its own further down.
    check_db  = $false
} | ConvertTo-Json -Depth 8
$cfgPath = Join-Path $tmp 'cfg.json'
[System.IO.File]::WriteAllText($cfgPath, $cfg, (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------------ HTTP helpers ---
# Raw HttpWebRequest, so a 403 arrives as a status code instead of the
# terminating error Invoke-WebRequest throws under 5.1 (and so the Content-Type
# / Content-Length of a POST are fully under our control).
function Invoke-Api {
    param(
        [string]$Method = 'GET',
        [string]$Path = '',
        [string]$Token,
        [string]$Body = $null
    )
    $req = [System.Net.HttpWebRequest]::Create("http://localhost:$script:Port/$Path")
    $req.Method = $Method
    $req.KeepAlive = $false
    $req.Timeout = 180000
    $req.ServicePoint.Expect100Continue = $false
    if ($Token) { $req.Headers.Add('X-SB-Token', $Token) }
    # NOT `$null -ne $Body`: PowerShell binds $null into a [string] parameter as
    # an EMPTY string, so `$null -ne $Body` is true for a body-less GET — and
    # then HTTP.sys refuses it ("cannot send a content-body with this verb").
    if (-not [string]::IsNullOrEmpty($Body)) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/json'
        # The host decides the property name: PowerShell 5.1 (.NET Framework)
        # only has ContentLength, PowerShell 7 (.NET) has both. Sending a real
        # Content-Length is what keeps HTTP.sys from answering 411.
        $len = $req.PSObject.Properties['ContentLength64']
        if ($null -ne $len) { $len.Value = $bytes.Length } else { $req.ContentLength = $bytes.Length }
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    $code = -1
    $text = ''
    try {
        $res = $req.GetResponse()
        $code = [int]$res.StatusCode
        $reader = New-Object IO.StreamReader($res.GetResponseStream(), (New-Object Text.UTF8Encoding($false)))
        $text = $reader.ReadToEnd()
        $reader.Close()
    } catch [System.Net.WebException] {
        $err = $_.Exception
        if ($null -ne $err.Response) {
            $code = [int]$err.Response.StatusCode
        } else {
            # Refused / not listening yet: -1 tells the caller to retry.
            $code = -1
            return [pscustomobject]@{ code = $code; text = $text }
        }
        $reader = New-Object IO.StreamReader($err.Response.GetResponseStream(), (New-Object Text.UTF8Encoding($false)))
        $text = $reader.ReadToEnd()
        $reader.Close()
    }
    return [pscustomobject]@{ code = $code; text = $text }
}

function Get-JsonResult {
    param([pscustomobject]$Result, [string]$What)
    if ($Result.code -ne 200) {
        throw "FAIL: $What returned HTTP $($Result.code) (expected 200): $($Result.text)"
    }
    if ([string]::IsNullOrWhiteSpace($Result.text)) {
        throw "FAIL: $What returned no body (assertion would be vacuous)"
    }
    try {
        return $Result.text | ConvertFrom-Json
    } catch {
        throw "FAIL: $What did not return JSON: $($Result.text)"
    }
}

# ------------------------------------------------------------ start server ----
$ui = Join-Path $root 'web-ui.ps1'
if (-not (Test-Path -LiteralPath $ui)) { throw "FAIL: web-ui.ps1 not found: $ui" }

# Ask the OS for a free port, then release it: the server gets a port nothing
# else is on, so a collision cannot make the suite fail for the wrong reason.
$probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
$probe.Start()
$script:Port = $probe.LocalEndpoint.Port
$probe.Stop()

# System.Diagnostics.Process, not Start-Process: with redirected output the
# Process object Start-Process hands back never populates ExitCode, so "did it
# shut down cleanly" could not be asserted at all.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName  = 'powershell.exe'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ui`" -Port $script:Port -ConfigPath `"$cfgPath`" -NoBrowser"
$psi.WorkingDirectory    = $root
$psi.UseShellExecute     = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow      = $true
$proc = [System.Diagnostics.Process]::Start($psi)

# The server's own console output. Read from the pipes once it has exited; the
# server writes well under a pipe buffer's worth while it runs, so nothing
# deadlocks waiting for this.
function Get-ServerOutput {
    if (-not $proc.HasExited) { return '(the web UI is still running)' }
    try { $proc.WaitForExit() } catch { }
    return ($proc.StandardOutput.ReadToEnd() + "`n" + $proc.StandardError.ReadToEnd())
}

try {
    $deadline = (Get-Date).AddSeconds(60)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            throw "FAIL: the web UI exited before serving anything (exit code $($proc.ExitCode)):`n$(Get-ServerOutput)"
        }
        if ((Invoke-Api -Method 'GET' -Path '').code -eq 200) { $up = $true; break }
        Start-Sleep -Milliseconds 400
    }
    if (-not $up) {
        throw "FAIL: the web UI never answered on http://localhost:$script:Port/`n$(Get-ServerOutput)"
    }

    # -- the page, and the token it alone carries -----------------------------
    $page = Invoke-Api -Method 'GET' -Path ''
    if ($page.code -ne 200) { throw "FAIL: / returned HTTP $($page.code)" }
    if ($page.text -notmatch 'SkillBridge') { throw 'FAIL: / did not serve the dashboard page' }
    if ($page.text -match '__SB_TOKEN__') {
        throw 'FAIL: the page still contains the __SB_TOKEN__ placeholder (token not substituted)'
    }
    if ($page.text -notmatch 'name="sb-token" content="([0-9a-f]{32})"') {
        throw "FAIL: the page carries no per-start token, so the CSRF test below would be vacuous"
    }
    $Token = $Matches[1]

    # -- no token, no API -----------------------------------------------------
    foreach ($m in @(
        @{ m = 'GET';  p = 'api/status' },
        @{ m = 'GET';  p = 'api/skills' },
        @{ m = 'GET';  p = 'api/log' },
        @{ m = 'GET';  p = 'api/sync' },
        @{ m = 'POST'; p = 'api/sync'; b = '{}' },
        @{ m = 'POST'; p = 'api/db-check'; b = '{}' },
        @{ m = 'POST'; p = 'api/stop'; b = '{}' }
    )) {
        $r = Invoke-Api -Method $m.m -Path $m.p -Body $m.b
        if ($r.code -ne 403) {
            throw "FAIL: $($m.m) /$($m.p) without X-SB-Token returned HTTP $($r.code) (expected 403)"
        }
        if ($r.text -notmatch 'X-SB-Token') { throw "FAIL: the 403 body did not say why: $($r.text)" }
    }
    # A stale token from a previous server start must not be accepted either.
    $stale = Invoke-Api -Method 'GET' -Path 'api/status' -Token ('a' * 32)
    if ($stale.code -ne 403) {
        throw "FAIL: a wrong (not merely missing) token returned HTTP $($stale.code) (expected 403)"
    }

    # -- wrong methods / unknown paths ---------------------------------------
    $badMethod = Invoke-Api -Method 'GET' -Path 'api/sync' -Token $Token
    if ($badMethod.code -ne 405) {
        throw "FAIL: GET /api/sync returned HTTP $($badMethod.code) (expected 405 - it runs a sync)"
    }
    $badMethod2 = Invoke-Api -Method 'GET' -Path 'api/db-check' -Token $Token
    if ($badMethod2.code -ne 405) {
        throw "FAIL: GET /api/db-check returned HTTP $($badMethod2.code) (expected 405 - it runs a check)"
    }
    $unknown = Invoke-Api -Method 'GET' -Path 'api/nope' -Token $Token
    if ($unknown.code -ne 404) {
        throw "FAIL: an unknown /api/ path returned HTTP $($unknown.code) (expected 404)"
    }

    # -- the snapshot ---------------------------------------------------------
    $st1 = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/status' -Token $Token) 'GET /api/status'
    if ($st1.health -eq 'error' -or $st1.error) {
        throw "FAIL: the fixture snapshot is broken: $($st1.error)"
    }
    if ($st1.source -ne (Join-Path $tmp 'src')) {
        throw "FAIL: snapshot source is '$($st1.source)', expected the fixture source"
    }
    if ($st1.skill_count -ne 1) {
        throw "FAIL: snapshot expected skill_count=1, got $($st1.skill_count)"
    }
    $targets = @($st1.targets)
    if ($targets.Count -ne 2) {
        throw "FAIL: snapshot expected 2 targets, got $($targets.Count)"
    }
    $linkT = @($targets | Where-Object { $_.mode -ne 'copy' })[0]
    $copyT = @($targets | Where-Object { $_.mode -eq 'copy' })[0]
    if ($null -eq $linkT -or $null -eq $copyT) {
        throw "FAIL: snapshot does not expose one link-mode and one copy-mode target"
    }
    if ($st1.needs_sync -ne $true) {
        throw 'FAIL: before any sync the snapshot should report needs_sync (nothing is linked yet)'
    }
    if ($linkT.linked -ne 0 -or @($linkT.missing).Count -ne 1) {
        throw "FAIL: link target not reported as empty (linked=$($linkT.linked) missing=$(@($linkT.missing).Count))"
    }

    # -- the skill browser, before anything is synced -------------------------
    $sk1 = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/skills' -Token $Token) 'GET /api/skills'
    if ($sk1.count -ne 1) { throw "FAIL: /api/skills returned count=$($sk1.count), expected 1" }
    $one = @($sk1.skills)[0]
    if ($one.name -ne 'demo-skill') { throw "FAIL: /api/skills reported name '$($one.name)'" }
    # The folded block must arrive as ONE line, or the UI row wraps.
    if ($one.description -notmatch '第一行描述' -or $one.description -notmatch '第二行仍然是同一段描述') {
        throw "FAIL: /api/skills lost part of the folded description: '$($one.description)'"
    }
    if ($one.description -match "`r|`n") { throw "FAIL: the description was not folded into one line: '$($one.description)'" }
    if ($one.files -lt 1) { throw "FAIL: /api/skills reported files=$($one.files)" }
    if ($one.size -le 0) { throw "FAIL: /api/skills reported size=$($one.size)" }
    if ($one.modified -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$') {
        throw "FAIL: /api/skills reported modified='$($one.modified)' (expected yyyy-MM-dd HH:mm)"
    }
    # `has` is a JSON OBJECT (target name -> link/copy), not an array, so the
    # emptiness test has to look at its properties.
    if (@($one.has.PSObject.Properties).Count -ne 0) { throw 'FAIL: before the sync the skill must not be anywhere' }
    if (@($one.missing).Count -ne 2) {
        throw "FAIL: /api/skills expected 2 missing targets, got $(@($one.missing).Count)"
    }
    if (@($one.blocked).Count -ne 0) { throw 'FAIL: nothing in the fixture shadows the skill, so blocked must be empty' }
    if (@($sk1.targets).Count -ne 2) {
        throw "FAIL: /api/skills expected 2 targets listed, got $(@($sk1.targets).Count)"
    }

    # -- the log tail ---------------------------------------------------------
    $lg = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/log?lines=3' -Token $Token) 'GET /api/log?lines=3'
    if ($lg.exists -ne $true) { throw 'FAIL: /api/log says the log does not exist' }
    $tail = @($lg.lines)
    if ($tail.Count -lt 1 -or $tail.Count -gt 3) {
        throw "FAIL: /api/log?lines=3 returned $($tail.Count) lines (expected 1..3)"
    }
    if ($lg.total -lt $tail.Count) {
        throw "FAIL: /api/log reported total=$($lg.total) under the tail size $($tail.Count)"
    }
    $lgAll = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/log' -Token $Token) 'GET /api/log'
    if (@($lgAll.lines).Count -gt 200) {
        throw "FAIL: the default log tail exceeded the 200-line default"
    }

    # -- a real sync, through the UI -----------------------------------------
    $sy = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/sync' -Token $Token -Body '{}') 'POST /api/sync'
    if ($sy.ran -ne $true) { throw "FAIL: the dashboard did not run the sync: $($sy.output)" }
    if ($sy.ok -ne $true -or $sy.exit_code -ne 0) {
        throw "FAIL: the dashboard-driven sync failed (exit $($sy.exit_code)): $($sy.output)"
    }
    if ($sy.output -notmatch 'skills=1') {
        throw "FAIL: the sync output does not mention skills=1: $($sy.output)"
    }
    if ($null -eq $sy.status -or $sy.status.status -ne 'ok') {
        throw "FAIL: the sync result did not carry a refreshed ok run record: $($sy.output)"
    }
    if (-not (Test-Path (Join-Path $tmp 'tgt\demo-skill'))) {
        throw 'FAIL: the sync did not create the junction'
    }
    $copiedItem = Get-Item (Join-Path $tmp 'tgt-copy\demo-skill') -Force
    if ($copiedItem.LinkType) {
        throw "FAIL: the copy target holds a link instead of a real copy (LinkType=$($copiedItem.LinkType))"
    }
    if (-not (Test-Path (Join-Path $tmp 'tgt-copy\demo-skill\.skillbridge-copy'))) {
        throw 'FAIL: the copy is missing its .skillbridge-copy marker'
    }
    if (-not (Test-Path (Join-Path $tmp 'tgt\own-skill'))) {
        throw "FAIL: the sync removed the tool's own directory"
    }

    $st2 = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/status' -Token $Token) 'GET /api/status after sync'
    $linkT2 = @(@($st2.targets) | Where-Object { $_.mode -ne 'copy' })[0]
    if ($linkT2.linked -ne 1 -or @($linkT2.missing).Count -ne 0) {
        throw "FAIL: after the sync the snapshot still reports missing links (linked=$($linkT2.linked))"
    }
    if ($st2.needs_sync -ne $false) {
        throw 'FAIL: after a clean sync the snapshot still reports needs_sync'
    }

    # -- and the same browser, once both targets hold it ----------------------
    $sk2 = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/skills' -Token $Token) 'GET /api/skills after sync'
    $one2 = @($sk2.skills)[0]
    if (@($one2.missing).Count -ne 0 -or @($one2.blocked).Count -ne 0) {
        throw 'FAIL: after the sync the skill browser still reports it as missing somewhere'
    }
    # `has` names what is ACTUALLY on disk: the link target gets a link, the
    # copy target a real copy. A config that asked for copy but still shows
    # 'link' here is drift the sync repairs, which is the point of the field.
    $linkKind = $one2.has.'WebUi'
    $copyKind = $one2.has.'WebUiCopy'
    if ($linkKind -ne 'link') { throw "FAIL: WebUi holds '$linkKind' where a link was expected" }
    if ($copyKind -ne 'copy') { throw "FAIL: WebUiCopy holds '$copyKind' where a real copy was expected" }

    # -- db-check must report, never repair ----------------------------------
    # The byte hash is the assertion: the user's rule is that nothing automated
    # may delete rows from cc-switch.db, and a changed file means something did.
    $db = Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db'
    $dbHashBefore = if (Test-Path -LiteralPath $db) { (Get-FileHash -LiteralPath $db -Algorithm MD5).Hash } else { $null }
    $dbRun = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/db-check' -Token $Token -Body '{}') 'POST /api/db-check'
    if ($null -eq $dbRun.ran) {
        throw "FAIL: the db-check result has no `ran` field: $($dbRun | ConvertTo-Json -Compress)"
    }
    if ($dbRun.ran -eq $true) {
        # It really ran. Against the fixture source it must report drift (the
        # fixture skills are not in the real database) - and change nothing.
        if ($dbRun.exit_code -ne 0 -and $dbRun.output -notmatch 'DRIFT') {
            throw "FAIL: db-check exited $($dbRun.exit_code) without reporting drift: $($dbRun.output)"
        }
    } elseif (-not $dbRun.error) {
        throw "FAIL: db-check reports ran=false with no reason: $($dbRun | ConvertTo-Json -Compress)"
    }
    if ($null -ne $dbHashBefore) {
        $dbHashAfter = (Get-FileHash -LiteralPath $db -Algorithm MD5).Hash
        if ($dbHashAfter -ne $dbHashBefore) {
            throw 'FAIL: the dashboard db-check MODIFIED cc-switch.db (it must stay report-only)'
        }
    }

    # -- loopback only --------------------------------------------------------
    # 0.0.0.0 here would publish the dashboard to the whole network, which is
    # the one thing the design forbids.
    $listen = @()
    try { $listen = @(Get-NetTCPConnection -LocalPort $script:Port -State Listen -ErrorAction Stop) } catch { }
    if ($listen.Count -eq 0) {
        $net = netstat -an | Select-String ("^\s*TCP\s+\S+:" + $script:Port + "\s")
        if (-not $net) {
            throw "FAIL: cannot observe the listening socket on port $script:Port (assertion would be vacuous)"
        }
        foreach ($line in $net) {
            if ($line -match '^\s*TCP\s+(0\.0\.0\.0|::):') {
                throw "FAIL: the server listens on a non-loopback address: $($line.Line.Trim())"
            }
        }
    } else {
        foreach ($c in $listen) {
            if ($c.LocalAddress -notin '127.0.0.1', '::1') {
                throw "FAIL: the server listens on $($c.LocalAddress) - the dashboard would be exposed to the network"
            }
        }
    }
    # And the behaviour behind it: a connection aimed at this machine's own
    # LAN-facing address must be refused. (This is what HttpListener got wrong -
    # it answered such a connection, Host header and all.)
    $lan = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -ne '169.254.*' })
    if ($lan.Count -eq 0) {
        Write-Host '  (note: no non-loopback IPv4 address on this host, so the reachability probe was skipped)'
    } else {
        $probeIp = $lan[0].IPAddress
        $refused = $false
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $c.Connect($probeIp, $script:Port)
            $c.Close()
        } catch {
            $refused = $true
        }
        if (-not $refused) {
            throw "FAIL: the dashboard accepted a connection on $probeIp`:$script:Port - it is reachable from the network"
        }
    }
    # Loopback itself must still work: the browser reaches the page over it.
    if ((Invoke-Api -Method 'GET' -Path '').code -ne 200) {
        throw 'FAIL: the page stopped answering on loopback'
    }

    # -- a clean shutdown -----------------------------------------------------
    $stop = Invoke-Api -Method 'POST' -Path 'api/stop' -Token $Token -Body '{}'
    if ($stop.code -ne 200 -or $stop.text -notmatch 'stopping') {
        throw "FAIL: POST /api/stop returned HTTP $($stop.code): $($stop.text)"
    }
    if (-not $proc.WaitForExit(30000)) {
        throw 'FAIL: the server did not exit 30s after /api/stop'
    }
    if ($proc.ExitCode -ne 0) {
        throw "FAIL: the server exited with code $($proc.ExitCode) after a clean stop"
    }
    $srvOut = Get-ServerOutput
    if ($srvOut -notmatch 'listening \(loopback only') {
        throw "FAIL: the server never logged that it is loopback-only: $srvOut"
    }
    # A crash or a Ctrl+C kills the process before the accept loop's finally
    # prints this, so it is what "stopped on purpose" looks like.
    if ($srvOut -notmatch '\] stopped') {
        throw "FAIL: the server stopped without running its shutdown path: $srvOut"
    }
    if ($srvOut -match 'request failed') {
        throw "FAIL: the server logged a failed request during the run: $srvOut"
    }
    if ($srvOut -match 'response write failed') {
        throw "FAIL: the server could not write a response: $srvOut"
    }
    if ($srvOut -notmatch '403 GET /api/status') {
        throw "FAIL: the server did not log the refused unauthenticated call: $srvOut"
    }
    if ($srvOut -notmatch 'sync requested') {
        throw "FAIL: the server did not log the driven sync: $srvOut"
    }
    Write-Host 'OK: web-ui smoke (page+token, 403 gate, 405/404, snapshot, skill browser, log tail, driven sync, report-only db-check, loopback bind, clean stop)'
} finally {
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill() } catch { }
    }
    if ($null -ne $logBackup) {
        [System.IO.File]::WriteAllBytes($log, $logBackup)
    } else {
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $statusBackup) {
        [System.IO.File]::WriteAllBytes($statusFile, $statusBackup)
    } else {
        Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $prevNoNotify) { $env:SKILLBRIDGE_NO_NOTIFY = $prevNoNotify } else { $env:SKILLBRIDGE_NO_NOTIFY = '' }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
