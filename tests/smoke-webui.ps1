# tests/smoke-webui.ps1 — API smoke test for web-ui.ps1 (the local dashboard).
#
# Starts web-ui.ps1 on a free loopback port against a THROWAWAY config (temp
# source plus one link target and one copy target) and then drives every
# endpoint exactly the way web-ui.html does, asserting:
#
#   * / serves the page with the per-start token already substituted in
#     (no __SB_TOKEN__ placeholder survives), is not cacheable, and keeps
#     `align-items: start` on the target-card grid
#   * every /api/ call WITHOUT that token is refused with 403 — that gate is the
#     whole CSRF defence, so it must not depend on which method or path is used
#   * GET /api/sync and GET /api/db-check are 405: both run something
#   * an unknown /api/ path with a valid token is 404
#   * the vendored assets (/assets/vendor/…: Lucide, Motion One, Inter,
#     JetBrains Mono) are served without a token, with the right MIME type, a
#     real length and no-store — and that the whitelist refuses anything else,
#     including a directory, a name that is not installed and a `..` that
#     escapes assets/ (sent over a raw socket, because a normal HTTP client
#     normalises `..` away before the server ever sees it)
#   * GET /api/status is the shared snapshot (source, skill count, per-target
#     linked/missing) and it changes as the sync lands
#   * GET /api/skills is the skill browser's payload: description folded out of
#     the SKILL.md frontmatter, file count/size, the Chinese intro and category
#     from skill-catalog.zh-CN.json (a skill the catalog omits falls back to the
#     catch-all bucket with its own description), the category summary, and
#     per-target link/copy/missing (asserted before AND after the sync, when the
#     kinds and the coverage counts change)
#   * GET /api/log?lines=N honours the tail size
#   * POST /api/sync really runs sync-skills.ps1: the junction and the copy
#     appear on disk, exit code 0, and the run record is refreshed
#   * POST /api/skills/add installs the skills inside an uploaded .zip into the
#     configured source: a valid package lands (SKILL.md and its nested folders),
#     a package whose name is already taken is reported as skipped and changes
#     nothing, an entry that tries to escape the package (`..\..\x`) is refused
#     without abandoning the rest of the upload and without leaving staging,
#     non-zip bytes are refused, and a 49 MB body is answered with 413 while the
#     server keeps serving afterwards
#   * POST /api/skills/delete removes one skill folder from the source, refuses
#     an illegal name, a folder that is not there, and a folder without SKILL.md
#     — and leaves the targets holding the link, which shows up as a residual the
#     next sync prunes
#   * POST /api/skills/delete-many does the same for several names at once: a
#     body that is not a non-empty array is a 400, over the size ceiling it is
#     refused whole, a name that does not exist (or is not a skill, or is
#     illegal) is refused per entry without taking the valid ones down with it,
#     and a batch that partly went through reports which names still stand
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

# One request over a raw socket, so the path goes on the wire exactly as it is
# written. Invoke-Api (HttpWebRequest) cannot do this: the Uri class compacts
# ".." out of a path before it is sent, so a traversal check made through it
# would be testing the client's own normalisation and nothing else. This one is
# also the only way to read the response head of a font without dragging its
# bytes through a string.
function Invoke-Raw {
    param([string]$Method = 'GET', [string]$Path)
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect([System.Net.IPAddress]::Loopback, $script:Port)
    $stream = $client.GetStream()
    $reqHead = "$Method /$Path HTTP/1.0`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n"
    $bytes = [Text.Encoding]::ASCII.GetBytes($reqHead)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $ms = New-Object IO.MemoryStream
    $buf = New-Object 'byte[]' 8192
    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
    $stream.Close()
    $client.Close()
    $all = [Text.Encoding]::ASCII.GetString($ms.ToArray())
    $split = $all.IndexOf("`r`n`r`n")
    $headText = if ($split -ge 0) { $all.Substring(0, $split) } else { $all }
    $head = @{}
    $code = 0
    foreach ($line in ($headText -split "`r?`n")) {
        if ($line -match '^HTTP/\d\.\d\s+(\d+)') { $code = [int]$Matches[1] }
        elseif ($line -match '^([^:]+):\s*(.*)$') { $head[$Matches[1]] = $Matches[2] }
    }
    return [pscustomobject]@{
        code   = $code
        type   = $head['Content-Type']
        cache  = $head['Cache-Control']
        length = if ($head['Content-Length']) { [int]$head['Content-Length'] } else { 0 }
        text   = $all
    }
}

# ------------------------------------------------------------ start server ----
$ui = Join-Path $root 'web-ui.ps1'
if (-not (Test-Path -LiteralPath $ui)) { throw "FAIL: web-ui.ps1 not found: $ui" }

# A zip the server can import, written with the same assembly it uses. On this
# machine Add-Type is the only way to reach it ([Reflection.Assembly]::Load
# looks in the GAC, and the assembly is not in it), and the client side of the
# test needs the type as much as the server does.
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-TestZip {
    param([string]$Path, [scriptblock]$Fill)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $archive = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try { & $Fill $archive } finally { $archive.Dispose() }
}
function Write-ZipText {
    param($Archive, [string]$EntryName, [string]$Text)
    $entry = $Archive.CreateEntry($EntryName)
    $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
    $writer.Write($Text)
    $writer.Close()
}
function Ask-Import {
    param([byte[]]$Bytes, [string]$What = 'POST /api/skills/add')
    $body = '{"data":"' + [Convert]::ToBase64String($Bytes) + '"}'
    return (Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/skills/add' -Token $Token -Body $body) $What)
}

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

    # -- the page must not be cacheable, and its card grid must not stretch ----
    # The page is read into the server process ONCE at startup, so a copy the
    # browser keeps shows the previous build after a restart: `no-store` is what
    # makes an edited web-ui.html visible on the next plain reload.
    $raw = [System.Net.HttpWebRequest]::Create("http://localhost:$script:Port/")
    $raw.Method = 'GET'
    $raw.KeepAlive = $false
    $raw.Timeout = 20000
    try {
        $res = $raw.GetResponse()
        $cache = [string]$res.Headers['Cache-Control']
        $res.Close()
    } catch [System.Net.WebException] {
        throw "FAIL: could not read the page's headers: $($_.Exception.Message)"
    }
    if ($cache -notmatch 'no-store') {
        throw "FAIL: the page is served with Cache-Control '$cache' (want no-store), so a restarted server leaves the browser on the previous build"
    }
    # Grid items stretch to the tallest card in their row by default, so opening
    # one card ballooned the collapsed ones beside it — it looked like one click
    # had expanded the whole row. This declaration is the only thing that stops
    # that, and nothing else in the page can assert a layout.
    if ($page.text -notmatch '\.targets\s*\{[^}]*align-items:\s*start') {
        throw 'FAIL: .targets no longer sets align-items: start, so an expanded card stretches every card in its row again'
    }
    # -- the option bar and its two views ------------------------------------
    # The skill browser reads 100+ SKILL.md files, so it starts hidden and is
    # fetched when its view is opened; a page that shows both views at once
    # (or fetches the list with the page) has lost that split.
    if ($page.text -notmatch 'data-view="sync"' -or $page.text -notmatch 'data-view="skills"') {
        throw 'FAIL: the option bar no longer offers 同步状况 and 技能列表 as two views'
    }
    if ($page.text -notmatch 'id="view-skills"\s+hidden') {
        throw 'FAIL: the skills view no longer starts hidden, so the page reads the skill list on every open'
    }
    # The chip row is now painted by renderCats() from the payload, so the
    # 全部 chip is a literal in the script rather than a static button here.
    if ($page.text -notmatch 'id="skill-cats"') {
        throw 'FAIL: the category filter row is gone from the skill view'
    }
    if ($page.text -notmatch "id:\s*'all',\s*name:\s*'全部'") {
        throw 'FAIL: the category filter no longer builds the 全部 chip, so skills of every category cannot be listed again'
    }
    if ($page.text -notmatch "skill-cats'\)\.innerHTML") {
        throw 'FAIL: nothing writes the category chips into #skill-cats, so the filter row stays empty'
    }
    if ($page.text -notmatch '\.cat-chip\b' -or $page.text -notmatch '\.skill-group-head\b') {
        throw 'FAIL: the skill view lost the styles for the category chips and the per-category group headers'
    }
    if ($page.text -notmatch 's\.intro' -or $page.text -notmatch 'skillState\.cat') {
        throw "FAIL: the skill list no longer renders the Chinese intro (`s.intro`) or filters by category"
    }
    # -- the vendored libraries the page is built on --------------------------
    # The icons, the animation and the type are all downloaded once into the
    # repository (see assets/README.md) and served from /assets/, so the page
    # needs no network at runtime. If a link here goes stale the page silently
    # degrades - no icons, no motion - so the guards check the page really names
    # the files and that the server really ships them.
    foreach ($asset in @('assets/vendor/lucide.min.js', 'assets/vendor/motion.min.js',
                         'assets/vendor/inter-var.woff2', 'assets/vendor/jetbrains-mono-var.woff2')) {
        if ($page.text -notmatch [regex]::Escape($asset)) {
            throw "FAIL: the page no longer references $asset, so the vendored asset is dead weight"
        }
    }
    if ($page.text -notmatch 'lucide\.icons') {
        throw 'FAIL: the page does not read window.lucide.icons, so it has no icon source'
    }
    if ($page.text -notmatch 'prefers-reduced-motion') {
        throw 'FAIL: the page never checks prefers-reduced-motion, so its animations ignore the OS setting'
    }
    if ($page.text -notmatch '@font-face') {
        throw 'FAIL: the page declares no @font-face, so the vendored fonts are never loaded'
    }
    if ($page.text -notmatch 'Motion\.animate|window\.Motion') {
        throw 'FAIL: the page never calls the animation library it loads'
    }
    # The option bar is a real ARIA tablist, not two buttons that happen to sit
    # together: a screen reader has to be told which view is selected.
    if ($page.text -notmatch 'role="tablist"' -or $page.text -notmatch 'role="tab"' -or $page.text -notmatch 'aria-controls="view-skills"') {
        throw 'FAIL: the option bar is not an ARIA tablist (no role=tablist/role=tab/aria-controls)'
    }
    if ($page.text -notmatch 'aria-selected="true"') {
        throw 'FAIL: no tab is marked aria-selected, so the selected view is not exposed to assistive tech'
    }
    # One token set, two themes: everything else in the stylesheet asks for a
    # semantic name, which is the only way the light theme is a different
    # palette instead of a second page. The two asserted here are the ones the
    # page actually consumes - an alias nothing asks for is dead weight and the
    # shadcn names have already lost a couple that way.
    if ($page.text -notmatch 'html\[data-theme="light"\]') {
        throw 'FAIL: the page has no light theme block, so the theme button has nothing to switch to'
    }
    if ($page.text -notmatch '--muted-foreground\s*:' -or $page.text -notmatch '--background\s*:') {
        throw 'FAIL: the semantic token set (--muted-foreground / --background) is gone from the stylesheet'
    }
    # Deleting a skill is irreversible and touches CC Switch's own skills
    # directory, so it is a blocking modal that names the consequences - never a
    # one-click confirm().
    if ($page.text -notmatch 'id="del-overlay"' -or $page.text -notmatch 'id="del-confirm"') {
        throw 'FAIL: the delete confirmation dialog is missing from the page'
    }
    if ($page.text -notmatch 'aria-modal="true"' -or $page.text -notmatch 'aria-labelledby="del-title"') {
        throw 'FAIL: the delete dialog is not an ARIA modal dialog (aria-modal / aria-labelledby)'
    }
    # And adding one, from a .zip.
    if ($page.text -notmatch 'id="add-overlay"' -or $page.text -notmatch 'id="add-drop"' -or $page.text -notmatch 'id="add-file"') {
        throw 'FAIL: the add-skill dialog (drop zone + file input) is missing from the page'
    }
    if ($page.text -notmatch 'data-del=' -or $page.text -notmatch 'row-del') {
        throw 'FAIL: the skill rows have no delete action any more'
    }
    # Multi-select: every row carries its own tick box, the header one means
    # "what I can see", and the batch actions only exist once something is
    # ticked. Without all of them the feature is a promise the page cannot keep.
    if ($page.text -notmatch 'data-check=' -or $page.text -notmatch 'row-check') {
        throw 'FAIL: the skill rows have no tick box, so nothing can be selected in bulk'
    }
    if ($page.text -notmatch 'id="skills-check-all"' -or $page.text -notmatch 'id="skills-selbar"' -or
        $page.text -notmatch 'id="sel-delete"') {
        throw 'FAIL: the batch action bar (header box / selbar / delete-selected) is missing from the page'
    }
    if ($page.text -notmatch 'id="del-names"') {
        throw 'FAIL: the delete dialog cannot list the names a batch delete is about to remove'
    }
    if ($page.text -notmatch 'delete-many') {
        throw 'FAIL: the page never calls the batch delete route'
    }
    # The grid gained a track for the tick boxes, so the header, the rows and
    # the responsive variant all have to agree on it - a column that only one
    # of them declares shifts every cell under a checkbox that is not there.
    if ($page.text -notmatch '--cols:\s*26px minmax\(150px') {
        throw 'FAIL: the skills grid does not open with a 26px track for the tick boxes'
    }
    if ($page.text -notmatch '--cols:\s*26px minmax\(120px') {
        throw 'FAIL: the responsive skills grid does not open with the tick-box track'
    }
    # The tick box is the row's first cell, or it will not line up with the
    # header's box.
    $rowSrc = [regex]::Match($page.text, 'function skillRow\(s\) \{[\s\S]*?\n  \}').Value
    if ($rowSrc -notmatch 'cell-sel[\s\S]*cell-name' -or $rowSrc.IndexOf('cell-sel') -gt $rowSrc.IndexOf('cell-name')) {
        throw 'FAIL: the tick box is not the first cell of a skill row'
    }
    # A tick must not also open the row's detail: the click handler has to look
    # for the box BEFORE it looks for the row, or every click toggles both.
    $handlerSrc = [regex]::Match($page.text, "list\.addEventListener\('click'[\s\S]*?\n    \}\);").Value
    if ($handlerSrc -notmatch 'data-check' -or $handlerSrc.IndexOf('data-check') -gt $handlerSrc.IndexOf('skill-group-head')) {
        throw 'FAIL: the row click handler can open a detail on a tick-box click (data-check is not checked first)'
    }
    # The label is wider than the 14px box it wraps, so most of the cell is label
    # padding, and a click there is a click on the label: the browser forwards it
    # to the box while the original click keeps bubbling to the row. One gesture,
    # two outcomes (checked in a real browser). The handler has to swallow the
    # cell itself, before the row branch can see it.
    if ($handlerSrc -notmatch "contains\('cell-sel'\)" -or $handlerSrc -notmatch 'preventDefault') {
        throw 'FAIL: the tick cell swallows no click of its own, so the label padding ticks the box AND opens the row'
    }
    if ($handlerSrc.IndexOf('cell-sel') -gt $handlerSrc.IndexOf('skill-group-head')) {
        throw 'FAIL: the tick cell is handled after the row, so its padding still opens the detail'
    }
    # A shift range has to follow the rows as they are on screen. The grouped
    # view buckets them by category, so a range built from the skills list ticks
    # a different set than the operator dragged across.
    if ($page.text -notmatch 'function domRowNames' -or $page.text -notmatch "querySelectorAll\('\.skill-row'\)") {
        throw 'FAIL: nothing reads the rows off the screen, so a shift range cannot follow them'
    }
    $tickSrc = [regex]::Match($page.text, 'function selTick\(name, on, ev\) \{[\s\S]*?\n  \}').Value
    if ($tickSrc -notmatch 'domRowNames' -or $tickSrc -match 'visibleSkills') {
        throw 'FAIL: the shift range is built from the skills list, not from the rows on screen'
    }
    # What is ticked has to be announced, from a region that is always in the
    # DOM: the bar is hidden until the first tick, and a live region that appears
    # together with its text is not read out.
    if ($page.text -notmatch 'id="sel-live"' -or $page.text -notmatch 'aria-live="polite"' -or
        $page.text -notmatch 'role="status"' -or $page.text -notmatch '\.sr-only') {
        throw 'FAIL: the selection is not announced to a screen reader from a permanent off-screen region'
    }
    # A batch that half-succeeded must re-arm with only the names that are left,
    # or the next press posts the deleted ones again and reports them as failures.
    # Extracted from the response handler's failure branch, because the page is
    # one file and the only defence against this being written but unreachable
    # is to read exactly what that branch does.
    $failSrc = [regex]::Match($page.text, "var done = \(data && data\.deleted\) \|\| \[\];[\s\S]*?loadSkills\(true\);").Value
    if ($failSrc -notmatch 'pendingDeletes = left' -or $failSrc -notmatch "del-confirm'\)\.textContent" -or
        $failSrc -notmatch "del-names'\)\.innerHTML" -or $failSrc -match 'if \(false\)') {
        throw 'FAIL: a partial delete does not re-arm the dialog with the names that remain'
    }
    # ... and that call picks its route by how many names are left. The retry
    # after a half-finished batch carries one name, which belongs on the
    # single-delete route (with a "name"), not back on the batch one.
    $deleteSrc = [regex]::Match($page.text, "api\(one \? '/api/skills/delete'[\s\S]*?function \(data\) \{").Value
    if ($deleteSrc -notmatch "'/api/skills/delete-many'" -or $deleteSrc -notmatch 'names\[0\]' -or
        $deleteSrc -notmatch 'names: names') {
        throw 'FAIL: the delete call does not choose its route and payload by count'
    }
    # Keyboard users get a visible ring; the rest of the page relies on it.
    if ($page.text -notmatch ':focus-visible') {
        throw 'FAIL: the page has no :focus-visible ring, so it is unusable without a mouse'
    }
    # The sidebar card is the only place outside the hero that repeats which
    # directory every change acts on; it starts on a placeholder, so something has
    # to fill it in or it reads 读取中… forever (which is exactly what happened).
    if ($page.text -notmatch 'id="src-v"' -or $page.text -notmatch 'id="src-n"' -or $page.text -notmatch 'id="btn-copy-src"') {
        throw 'FAIL: the sidebar source card lost its elements (src-v / src-n / btn-copy-src)'
    }
    if ($page.text -notmatch 'function renderSourceCard' -or $page.text -notmatch 'renderSourceCard\(data\)') {
        throw 'FAIL: renderSourceCard is not called on the status snapshot, so the sidebar source card stays on its placeholder'
    }

    # The scan button: the page must both offer it and call the route that runs
    # the detection. A button with no handler is the failure mode here (it looks
    # like the feature is there and nothing happens).
    if ($page.text -notmatch 'id="btn-scan"' -or $page.text -notmatch 'id="scan-card"' -or $page.text -notmatch 'id="scan-list"') {
        throw 'FAIL: the tool scan button / result card is missing from the page'
    }
    if ($page.text -notmatch "api/scan-tools" -or $page.text -notmatch 'function runScan' -or $page.text -notmatch "btn-scan'\).onclick = runScan") {
        throw 'FAIL: the 扫描工具 button is not wired to POST /api/scan-tools'
    }
    # ... and the answer has to land near the button, not below the target grid:
    # a result card buried under two dozen targets reads as "nothing happened".
    if ($page.text.IndexOf('id="scan-card"') -gt $page.text.IndexOf('id="targets"')) {
        throw 'FAIL: the scan result card sits below the 同步目标 grid instead of near the 扫描工具 button'
    }

    # -- no token, no API -----------------------------------------------------
    foreach ($m in @(
        @{ m = 'GET';  p = 'api/status' },
        @{ m = 'GET';  p = 'api/skills' },
        @{ m = 'GET';  p = 'api/log' },
        @{ m = 'GET';  p = 'api/sync' },
        @{ m = 'POST'; p = 'api/sync'; b = '{}' },
        @{ m = 'POST'; p = 'api/db-check'; b = '{}' },
        @{ m = 'POST'; p = 'api/scan-tools'; b = '{}' },
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
    $badMethod3 = Invoke-Api -Method 'GET' -Path 'api/scan-tools' -Token $Token
    if ($badMethod3.code -ne 405) {
        throw "FAIL: GET /api/scan-tools returned HTTP $($badMethod3.code) (expected 405 - it scans the machine)"
    }
    $unknown = Invoke-Api -Method 'GET' -Path 'api/nope' -Token $Token
    if ($unknown.code -ne 404) {
        throw "FAIL: an unknown /api/ path returned HTTP $($unknown.code) (expected 404)"
    }

    # -- the vendored assets -------------------------------------------------
    # The fonts, the icon library and the animation library are the only files
    # the server hands out from disk, and only by these exact names: the route
    # is a whitelist, so a name that is not in it must 404 rather than fall
    # through to "read whatever was asked for".
    $assetCases = @(
        @{ p = 'assets/vendor/lucide.min.js';             ct = 'text/javascript' },
        @{ p = 'assets/vendor/motion.min.js';             ct = 'text/javascript' },
        @{ p = 'assets/vendor/inter-var.woff2';           ct = 'font/woff2' },
        @{ p = 'assets/vendor/jetbrains-mono-var.woff2';  ct = 'font/woff2' }
    )
    foreach ($a in $assetCases) {
        # No token on purpose: a font is not a secret, and the page asks for it
        # before any JS can attach a header.
        $r = Invoke-Raw -Path $a.p
        if ($r.code -ne 200) { throw "FAIL: GET /$($a.p) returned HTTP $($r.code) (expected 200)" }
        if ($r.type -notmatch [regex]::Escape($a.ct)) { throw "FAIL: /$($a.p) was served as '$($r.type)'" }
        if ($r.length -lt 1024) {
            throw "FAIL: /$($a.p) is only $($r.length) bytes - a truncated or placeholder file"
        }
        # no-store, not immutable: the point of these files is that a newer
        # version can be dropped in, and a browser holding a year-old lucide
        # would make that a silent no-op.
        if ($r.cache -notmatch 'no-store') {
            throw "FAIL: /$($a.p) is served with Cache-Control '$($r.cache)' (want no-store)"
        }
    }
    $va = Invoke-Raw -Path 'assets/vendor/motion.min.js'
    if (-not $va.text -or $va.text -notmatch 'Motion') {
        throw 'FAIL: assets/vendor/motion.min.js is not the Motion One bundle'
    }
    $la = Invoke-Raw -Path 'assets/vendor/lucide.min.js'
    if (-not $la.text -or $la.text -notmatch 'createIcons|icons') {
        throw 'FAIL: assets/vendor/lucide.min.js is not the Lucide bundle'
    }

    # -- the brand icon for the browser tab ------------------------------------
    # Served untokened like the other disk files: the browser asks for the icon
    # before any JS can attach a header. An icon nobody links is invisible - the
    # tab keeps the default globe - so the page head is asserted too.
    $fav = Invoke-Raw -Path 'assets/brand/skillbridge.svg'
    if ($fav.code -ne 200) {
        throw "FAIL: GET /assets/brand/skillbridge.svg returned HTTP $($fav.code) (expected 200)"
    }
    if ($fav.type -notmatch 'image/svg\+xml') { throw "FAIL: the icon was served as '$($fav.type)'" }
    if ($fav.length -lt 300) {
        throw "FAIL: the icon is only $($fav.length) bytes - truncated or a placeholder"
    }
    if ($fav.cache -notmatch 'no-store') {
        throw "FAIL: the icon is served with Cache-Control '$($fav.cache)' (want no-store)"
    }
    if ($fav.text -notmatch '<svg' -or $fav.text -notmatch 'viewBox') {
        throw 'FAIL: the served icon is not an SVG document'
    }
    # Brand teal. An icon that quietly drifts off-palette is a design regression
    # no functional test would ever catch.
    if ($fav.text -notmatch '#2dd4bf') {
        throw 'FAIL: the brand icon lost the brand colour (#2dd4bf)'
    }
    $favMiss = Invoke-Raw -Path 'assets/brand/nope.svg'
    if ($favMiss.code -eq 200) {
        throw 'FAIL: an unlisted name under assets/brand/ was served - the whitelist let something through'
    }
    $pageIcon = Invoke-Raw -Path ''
    if ($pageIcon.code -ne 200 -or
        $pageIcon.text -notmatch 'rel="icon"[^>]*assets/brand/skillbridge\.svg') {
        throw 'FAIL: the page does not link the brand icon (the tab would keep the default icon)'
    }
    foreach ($bad in @(
        @{ p = 'assets/vendor/../web-ui.ps1';        why = 'a traversal out of assets/' },
        @{ p = 'assets/../config.json';              why = 'a traversal to a config file' },
        @{ p = 'assets/vendor/nope.js';              why = 'a file that is not installed' },
        @{ p = 'assets/vendor/';                     why = 'a directory, not a file' }
    )) {
        $r = Invoke-Raw -Path $bad.p
        if ($r.code -eq 200) {
            throw "FAIL: /$($bad.p) was served ($why) - the whitelist let something through"
        }
    }
    $assetPost = Invoke-Api -Method 'POST' -Path 'assets/vendor/lucide.min.js' -Body '{}'
    if ($assetPost.code -ne 405) {
        throw "FAIL: POST /assets/vendor/lucide.min.js returned HTTP $($assetPost.code) (expected 405)"
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
    # -- the Chinese catalog overlay -----------------------------------------
    # demo-skill is a fixture, so it is in no category of the real
    # skill-catalog.zh-CN.json: it has to fall through to the catch-all bucket
    # with its own description as the intro, not vanish from the list.
    foreach ($field in 'intro', 'cat', 'cat_name', 'covered') {
        if ($null -eq $one.PSObject.Properties[$field]) {
            throw "FAIL: /api/skills no longer returns $field"
        }
    }
    if ([string]$one.intro -ne '') {
        throw "FAIL: a skill the catalog says nothing about must not get an intro, got '$($one.intro)'"
    }
    if ($one.cat -ne 'other') { throw "FAIL: /api/skills filed an unknown skill under cat '$($one.cat)'" }
    if ($one.cat_name -ne '其他') { throw "FAIL: the catch-all bucket is named '$($one.cat_name)'" }
    if ($null -eq $sk1.PSObject.Properties['categories']) { throw 'FAIL: /api/skills no longer returns categories' }
    if (@($sk1.categories).Count -ne 1) {
        throw "FAIL: with one uncatalogued skill only the catch-all bucket should exist, got $(@($sk1.categories).Count)"
    }
    $bucket = @($sk1.categories)[0]
    if ($bucket.id -ne 'other' -or $bucket.count -ne 1) {
        throw "FAIL: the catch-all bucket reported id=$($bucket.id) count=$($bucket.count)"
    }
    if ($bucket.covered -ne 0) {
        throw "FAIL: before the sync the skill is in no target, so the bucket must report covered=0, got $($bucket.covered)"
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
    if ($one2.covered -ne $true) {
        throw "FAIL: after the sync the skill is in every target, so covered must be `true`, got '$($one2.covered)'"
    }
    if ([string]$one2.intro -ne '') {
        throw "FAIL: the sync must not invent a Chinese intro, got '$($one2.intro)'"
    }
    # The bucket's coverage count has to follow the sync: 0 -> 1 is the number
    # the category chip shows next to 其他, so a stale one is a lie on screen.
    $bucket2 = @($sk2.categories)[0]
    if ($bucket2.count -ne 1 -or $bucket2.covered -ne 1) {
        throw "FAIL: the catch-all bucket reports count=$($bucket2.count) covered=$($bucket2.covered) after the sync, expected 1/1"
    }

    # -- adding and deleting skills, against the configured source ------------
    # Both routes write to the fixture source ($tmp\src, standing in for
    # config.json's `source`). A round trip has to work here or it does not work
    # at all: the same two functions run against CC Switch's own skills folder.
    $srcDir = Join-Path $tmp 'src'

    $zipGood = Join-Path $tmp 'good.zip'
    New-TestZip $zipGood {
        param($a)
        Write-ZipText $a 'inbox-skill/SKILL.md' "---`nname: inbox-skill`ndescription: >-`n  安装包导入的技能。`n---`n# inbox`n"
        Write-ZipText $a 'inbox-skill/notes/ref.md' 'reference body'
    }
    $goodBytes = [IO.File]::ReadAllBytes($zipGood)
    $add = Ask-Import -Bytes $goodBytes
    if ($add.ok -ne $true) { throw "FAIL: importing a valid zip was refused: $($add.error)" }
    if (@($add.added) -notcontains 'inbox-skill') {
        throw "FAIL: the import added $(@($add.added) -join ', ') — 'inbox-skill' is not among them"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $srcDir 'inbox-skill\SKILL.md'))) {
        throw 'FAIL: the imported skill has no SKILL.md in the source'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $srcDir 'inbox-skill\notes\ref.md'))) {
        throw 'FAIL: the import dropped the nested folder of the package'
    }

    # The same package a second time: an existing skill is never overwritten,
    # because overwriting is how a person loses a skill they were editing.
    $add2 = Ask-Import -Bytes $goodBytes -What 'POST /api/skills/add (again)'
    if ($add2.ok -ne $false) { throw 'FAIL: re-importing an existing skill reported ok' }
    $skippedNames = @(@($add2.skipped) | ForEach-Object { $_.name })
    if ($skippedNames -notcontains 'inbox-skill') {
        throw "FAIL: the duplicate import reported skipped=$(($skippedNames) -join ', ')"
    }
    if ((Get-Content -LiteralPath (Join-Path $srcDir 'inbox-skill\notes\ref.md') -Raw) -ne 'reference body') {
        throw 'FAIL: the duplicate import overwrote the file already in the source'
    }

    # Zip-slip. .NET Framework's ExtractToDirectory would happily write
    # ..\..\out.txt, so the guard is the whole defence and it has to be tested
    # with an entry that actually tries to escape.
    $marker = 'sb-smoke-escaped.txt'
    $escapedPath = Join-Path $env:TEMP $marker
    if (Test-Path -LiteralPath $escapedPath) { Remove-Item -LiteralPath $escapedPath -Force }
    $zipSlip = Join-Path $tmp 'slip.zip'
    New-TestZip $zipSlip {
        param($a)
        Write-ZipText $a 'slip-skill/SKILL.md' "---`nname: slip-skill`ndescription: >-`n  带穿越项的安装包。`n---`n# slip`n"
        Write-ZipText $a ('..\..\' + $marker) 'escaped'
    }
    $add3 = Ask-Import -Bytes ([IO.File]::ReadAllBytes($zipSlip)) -What 'POST /api/skills/add (zip-slip)'
    $escapedRefused = [bool](@($add3.refused) | Where-Object { [string]$_.entry -like "*$marker*" })
    if (-not $escapedRefused) {
        throw "FAIL: the escaping entry was not refused (the zip-slip guard is gone): $(@($add3.refused) | ConvertTo-Json -Compress)"
    }
    if (Test-Path -LiteralPath $escapedPath) {
        throw "FAIL: the zip-slip entry escaped into $env:TEMP"
    }
    # The harmless half of the same package still installs: refusing one entry
    # must not abandon the rest of the upload.
    if (@($add3.added) -notcontains 'slip-skill') {
        throw "FAIL: refusing the escaping entry also refused the rest of the package"
    }
    # Nothing may be left in the source: a staging directory that survives the
    # import would show up as a phantom skill the next time the list is read.
    $staging = @(Get-ChildItem -LiteralPath $srcDir -Directory -Force | Where-Object { $_.Name -like '.sb-import-*' })
    if ($staging.Count -ne 0) {
        throw "FAIL: the import left its staging directory behind: $($staging[0].FullName)"
    }

    # Not a zip at all.
    $add4 = Ask-Import -Bytes ([Text.Encoding]::UTF8.GetBytes('this is not a zip')) -What 'POST /api/skills/add (not a zip)'
    if ($add4.ok -ne $false -or $add4.error -notmatch 'PK|zip') {
        throw "FAIL: non-zip bytes were not refused: ok=$($add4.ok) error=$($add4.error)"
    }

    # -- the routes' guards ----------------------------------------------------
    $addGet = Invoke-Api -Method 'GET' -Path 'api/skills/add' -Token $Token
    if ($addGet.code -ne 405) {
        throw "FAIL: GET /api/skills/add returned HTTP $($addGet.code) (expected 405)"
    }
    $delGet = Invoke-Api -Method 'GET' -Path 'api/skills/delete' -Token $Token
    if ($delGet.code -ne 405) {
        throw "FAIL: GET /api/skills/delete returned HTTP $($delGet.code) (expected 405)"
    }
    foreach ($call in @(
        @{ m = 'POST'; p = 'api/skills/add';    b = '{}' },
        @{ m = 'POST'; p = 'api/skills/delete'; b = '{"name":"demo-skill"}' }
    )) {
        $r = Invoke-Api -Method $call.m -Path $call.p -Body $call.b
        if ($r.code -ne 403) {
            throw "FAIL: $($call.m) /$($call.p) without X-SB-Token returned HTTP $($r.code) (expected 403)"
        }
    }
    $noName = Invoke-Api -Method 'POST' -Path 'api/skills/delete' -Token $Token -Body '{}'
    if ($noName.code -ne 400) {
        throw "FAIL: a delete with no name returned HTTP $($noName.code) (expected 400)"
    }
    $badZip = Invoke-Api -Method 'POST' -Path 'api/skills/add' -Token $Token -Body '{"nope":1}'
    if ($badZip.code -ne 400) {
        throw "FAIL: an add with no base64 package returned HTTP $($badZip.code) (expected 400)"
    }
    # The body is capped, and the cap is answered with 413 rather than by
    # buffering gigabytes into the server's memory. The cap is 48 MiB, so this is
    # ~49.6 MiB of 'A' - deliberately not valid JSON, because the size gate runs
    # before anything parses it.
    $toobig = Invoke-Api -Method 'POST' -Path 'api/skills/add' -Token $Token -Body ([string]::new('A', 52000000))
    if ($toobig.code -ne 413) {
        throw "FAIL: a 49 MB body was answered with HTTP $($toobig.code) (expected 413): $($toobig.text)"
    }
    if ($toobig.text -notmatch 'limit') { throw "FAIL: the 413 body does not explain the limit: $($toobig.text)" }
    # And the server is still healthy: the refused body is drained, or the
    # connection is reset and the next request fails for no visible reason.
    if ((Invoke-Api -Method 'GET' -Path 'api/status' -Token $Token).code -ne 200) {
        throw 'FAIL: the server stopped answering after refusing an oversized body'
    }

    # -- deleting is refused until it is provably a skill ----------------------
    $badName = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/skills/delete' -Token $Token -Body '{"name":".."}') 'POST /api/skills/delete (..)'
    if ($badName.ok -ne $false -or $badName.error -notmatch 'illegal') {
        throw "FAIL: the name '..' was not refused as illegal: ok=$($badName.ok) error=$($badName.error)"
    }
    $gone = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/skills/delete' -Token $Token -Body '{"name":"no-such-skill"}') 'POST /api/skills/delete (missing)'
    if ($gone.ok -ne $false -or $gone.error -notmatch 'no such skill') {
        throw "FAIL: deleting a skill that is not there was not refused: ok=$($gone.ok) error=$($gone.error)"
    }
    # The source also holds a directory that is not a skill (the tool's own
    # stuff). Deleting must refuse it, not treat every folder as removable.
    New-Item -ItemType Directory -Path (Join-Path $srcDir 'notaskill') -Force | Out-Null
    $notSkill = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/skills/delete' -Token $Token -Body '{"name":"notaskill"}') 'POST /api/skills/delete (no SKILL.md)'
    if ($notSkill.ok -ne $false -or $notSkill.error -notmatch 'SKILL.md') {
        throw "FAIL: a folder without SKILL.md was not refused: ok=$($notSkill.ok) error=$($notSkill.error)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $srcDir 'notaskill'))) {
        throw 'FAIL: the refusal still deleted the folder'
    }

    # -- the real delete, and what it leaves behind ----------------------------
    $del = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/skills/delete' -Token $Token -Body '{"name":"demo-skill"}') 'POST /api/skills/delete'
    if ($del.ok -ne $true) { throw "FAIL: deleting demo-skill was refused: $($del.error)" }
    if ($del.name -ne 'demo-skill' -or $del.files -lt 1 -or $del.size -le 0) {
        throw "FAIL: the delete result does not report what it removed: $($del | ConvertTo-Json -Compress)"
    }
    if (Test-Path -LiteralPath (Join-Path $srcDir 'demo-skill')) {
        throw 'FAIL: the source still holds the deleted skill'
    }
    # The 21 targets are not part of the delete, so the link and the copy are
    # still on disk — as orphans, which is what the next sync prunes.
    $st3 = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/status' -Token $Token) 'GET /api/status after delete'
    if ($st3.skill_count -ne 2) {
        throw "FAIL: after deleting one of three skills the snapshot reports skill_count=$($st3.skill_count)"
    }
    if ($st3.needs_sync -ne $true) {
        throw 'FAIL: deleting a skill leaves links behind, so the snapshot must report needs_sync'
    }
    $linkT3 = @(@($st3.targets) | Where-Object { $_.mode -ne 'copy' })[0]
    if (@($linkT3.orphans).Count -lt 1) {
        throw 'FAIL: the junction left by the deleted skill is not reported as a residual (orphan)'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tmp 'tgt\demo-skill'))) {
        throw 'FAIL: the link target no longer holds the junction the residual claim is about'
    }
    $sy2 = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/sync' -Token $Token -Body '{}') 'POST /api/sync after delete'
    if ($sy2.ok -ne $true) { throw "FAIL: the sync after the delete failed: $($sy2.output)" }
    if ($sy2.output -notmatch 'skills=2') {
        throw "FAIL: the sync after the delete does not mention skills=2: $($sy2.output)"
    }
    if (Test-Path -LiteralPath (Join-Path $tmp 'tgt\demo-skill')) {
        throw 'FAIL: the sync did not prune the junction left by the deleted skill'
    }
    if (Test-Path -LiteralPath (Join-Path $tmp 'tgt-copy\demo-skill')) {
        throw 'FAIL: the sync did not remove the copy of the deleted skill (it carries our marker, so it is ours)'
    }

    # -- deleting several at once ---------------------------------------------
    # Same guards as the single delete, one name at a time: a batch that names a
    # skill that does not exist (or a folder that is not a skill) must not take
    # the valid entries down with it, and must not quietly delete the ones it
    # refused to look at.
    foreach ($n in 'batch-a', 'batch-b', 'batch-c', 'batch-d') {
        New-Item -ItemType Directory -Path (Join-Path $tmp "src\$n") -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tmp "src\$n\SKILL.md"),
            "---`nname: $n`ndescription: >-`n  批量删除夹具。`n---`n# $n`n", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $tmp "src\$n\notes.md"), "body of $n", (New-Object System.Text.UTF8Encoding($false)))
    }
    # A folder with no SKILL.md is not a skill, and the batch must refuse it for
    # the same reason the single delete does.
    New-Item -ItemType Directory -Path (Join-Path $tmp 'src\batch-notaskill') -Force | Out-Null
    $syBatch = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/sync' -Token $Token -Body '{}') 'POST /api/sync before the batch'
    if ($syBatch.ok -ne $true) { throw "FAIL: the sync of the batch fixtures failed: $($syBatch.output)" }

    $batchGet = Invoke-Api -Method 'GET' -Path 'api/skills/delete-many' -Token $Token
    if ($batchGet.code -ne 405) {
        throw "FAIL: GET /api/skills/delete-many returned HTTP $($batchGet.code) (expected 405)"
    }
    $batchNoTok = Invoke-Api -Method 'POST' -Path 'api/skills/delete-many' -Body '{"names":["batch-a"]}'
    if ($batchNoTok.code -ne 403) {
        throw "FAIL: POST /api/skills/delete-many without X-SB-Token returned HTTP $($batchNoTok.code) (expected 403)"
    }
    # A string where an array belongs is a 400, not a one-skill batch: the route
    # is explicit about what it takes, so a client mistake cannot pass as intent.
    foreach ($body in '{}', '{"names":[]}', '{"names":"batch-a"}', '{"names":["  ",""]}', 'not json') {
        $r = Invoke-Api -Method 'POST' -Path 'api/skills/delete-many' -Token $Token -Body $body
        if ($r.code -ne 400) {
            throw "FAIL: POST /api/skills/delete-many with body '$body' returned HTTP $($r.code) (expected 400)"
        }
    }
    # The size ceiling comes before anything is touched: asking for more skills
    # than the library can plausibly mean is refused whole, not in part.
    $huge = @()
    for ($i = 0; $i -lt 201; $i++) { $huge += "flood-$i" }
    $over = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/skills/delete-many' -Token $Token -Body (@{ names = $huge } | ConvertTo-Json -Compress)) 'POST /api/skills/delete-many (over the limit)'
    if ($over.ok -ne $false -or $over.error -notmatch 'too many at once') {
        throw "FAIL: 201 names were not refused as a batch: ok=$($over.ok) error=$($over.error)"
    }
    if (@($over.deleted).Count -ne 0 -or @($over.failed).Count -ne 0) {
        throw 'FAIL: the refused over-limit batch reports entries it never looked at'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tmp 'src\batch-a'))) {
        throw 'FAIL: the over-limit refusal touched the skills folder'
    }

    # Partial: one name that is there, one that is not. The valid one goes, the
    # invalid one is reported, and the run says so instead of answering "ok".
    $partial = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/skills/delete-many' -Token $Token -Body '{"names":["batch-a","no-such-skill"]}') 'POST /api/skills/delete-many (one missing)'
    if ($partial.ok -ne $false -or $partial.error -notmatch 'deleted 1, refused 1') {
        throw "FAIL: the partial batch did not report what it did: ok=$($partial.ok) error=$($partial.error)"
    }
    if (@($partial.deleted).Count -ne 1 -or @($partial.deleted)[0].name -ne 'batch-a' -or @($partial.deleted)[0].files -lt 1) {
        throw "FAIL: the partial batch did not report the entry it deleted: $($partial | ConvertTo-Json -Compress)"
    }
    if (@($partial.failed).Count -ne 1 -or @($partial.failed)[0].name -ne 'no-such-skill') {
        throw "FAIL: the partial batch did not name the refused entry: $($partial | ConvertTo-Json -Compress)"
    }
    if (Test-Path -LiteralPath (Join-Path $tmp 'src\batch-a')) {
        throw 'FAIL: batch-a survived a batch that reported deleting it'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tmp 'src\batch-b'))) {
        throw 'FAIL: the partial batch deleted batch-b, which it was never asked about'
    }
    # A non-skill folder and an illegal name in the same request: both refused,
    # neither deleted, and the folder is still there afterwards.
    $refuse = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/skills/delete-many' -Token $Token -Body '{"names":["batch-b","..","batch-notaskill"]}') 'POST /api/skills/delete-many (mixed)'
    if ($refuse.ok -ne $false -or @($refuse.deleted).Count -ne 1 -or @($refuse.deleted)[0].name -ne 'batch-b') {
        throw "FAIL: the batch did not delete the one valid entry among refusals: $($refuse | ConvertTo-Json -Compress)"
    }
    if (@($refuse.failed).Count -ne 2) {
        throw "FAIL: the batch did not refuse exactly the illegal name and the non-skill folder: $($refuse | ConvertTo-Json -Compress)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tmp 'src\batch-notaskill'))) {
        throw 'FAIL: a folder without SKILL.md was deleted by a batch that had to refuse it'
    }
    # A batch of all-valid names: clean answer, and the orphans it leaves behind
    # are the next sync's to prune.
    $stBefore = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/status' -Token $Token) 'GET /api/status before the clean batch'
    $clean = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/skills/delete-many' -Token $Token -Body '{"names":["batch-c","batch-d"]}') 'POST /api/skills/delete-many (clean)'
    if ($clean.ok -ne $true -or @($clean.failed).Count -ne 0) {
        throw "FAIL: the clean batch was not clean: ok=$($clean.ok) error=$($clean.error)"
    }
    if (@($clean.deleted).Count -ne 2 -or $clean.files -lt 2 -or $clean.size -le 0) {
        throw "FAIL: the clean batch did not report its totals: $($clean | ConvertTo-Json -Compress)"
    }
    foreach ($n in 'batch-c', 'batch-d') {
        if (Test-Path -LiteralPath (Join-Path $tmp "src\$n")) { throw "FAIL: $n survived a clean batch that reported deleting it" }
    }
    if (@($stBefore.targets | Where-Object { $_.mode -ne 'copy' })[0].orphans.Count -lt 1) {
        throw 'FAIL: a deleted skill left no residual behind, so there is nothing for the next sync to prune'
    }
    $st5b = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/status' -Token $Token) 'GET /api/status after the clean batch'
    if ($st5b.skill_count -ne ($stBefore.skill_count - 2)) {
        throw "FAIL: after the clean batch the snapshot reports skill_count=$($st5b.skill_count) (expected $($stBefore.skill_count - 2))"
    }
    $sy3 = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/sync' -Token $Token -Body '{}') 'POST /api/sync after the clean batch'
    if ($sy3.ok -ne $true) { throw "FAIL: the sync after the clean batch failed: $($sy3.output)" }
    if (Test-Path -LiteralPath (Join-Path $tmp 'tgt\batch-c')) {
        throw 'FAIL: the sync did not prune the residual left by the clean batch'
    }
    # The two added skills made it into every target, which proves the import
    # installed something a sync can actually link.
    $st4 = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/status' -Token $Token) 'GET /api/status after the second sync'
    if ($st4.needs_sync -ne $false) {
        throw "FAIL: after a clean sync the snapshot still reports needs_sync: $($st4.error)"
    }
    foreach ($t in @($st4.targets)) {
        if (@($t.missing).Count -ne 0) {
            throw "FAIL: target $($t.name) still misses $($t.missing -join ', ')"
        }
    }

    # -- the copy-mode target must name WHICH copies went stale -----------------
    # The 过期 badge used to be a count with nothing behind it: the name lived
    # only in an issue string. Drift a copy on disk and the snapshot has to hand
    # the page a list the detail chips can show.
    $drift = Join-Path $tmp 'tgt-copy\inbox-skill\drift-marker.txt'
    [System.IO.File]::WriteAllText($drift, 'stale on purpose')
    $st5 = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/status' -Token $Token) 'GET /api/status after copy drift'
    $copyT5 = @(@($st5.targets) | Where-Object { $_.mode -eq 'copy' })[0]
    if ($copyT5.stale -ne 1) {
        throw "FAIL: a drifted copy did not raise stale (got $($copyT5.stale))"
    }
    if (@($copyT5.stale_list) -notcontains 'inbox-skill') {
        throw "FAIL: the snapshot did not name the stale copy (stale_list: $($copyT5.stale_list -join ', '))"
    }
    # the link target must NOT be dragged in: a junction follows the source by
    # definition, so "stale" there would be a false alarm on every card.
    $linkT5 = @(@($st5.targets) | Where-Object { $_.mode -ne 'copy' })[0]
    if ($linkT5.stale -ne 0) {
        throw "FAIL: a link-mode target reported stale=$($linkT5.stale) (junctions cannot go stale)"
    }

    # -- and the browser payload shows the new state --------------------------
    $sk3 = Get-JsonResult (Invoke-Api -Method 'GET' -Path 'api/skills' -Token $Token) 'GET /api/skills after CRUD'
    $names3 = @($sk3.skills | ForEach-Object { $_.name })
    if ($names3 -contains 'demo-skill') { throw 'FAIL: the deleted skill is still in the browser payload' }
    foreach ($n in 'inbox-skill', 'slip-skill') {
        if ($names3 -notcontains $n) { throw "FAIL: the added skill '$n' is missing from the browser payload" }
    }
    $boxed = @($sk3.skills | Where-Object { $_.name -eq 'inbox-skill' })[0]
    if ($boxed.description -notmatch '安装包导入的技能') {
        throw "FAIL: the imported skill's description was lost: '$($boxed.description)'"
    }
    if (@($boxed.has.PSObject.Properties).Count -ne 2) {
        throw "FAIL: the imported skill is not in both targets: $($boxed.has | ConvertTo-Json -Compress)"
    }

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

    # -- the tool scan adds, and only adds -----------------------------------
    # The button answers "which agent software is installed on this machine".
    # The fixture config holds two custom targets and no catalog target, so the
    # scan has to add every installed catalog tool - while the two named in
    # `exclude` stay out even though their marker directories are on disk, and
    # nothing the user configured moves underneath. (That is the Codex / Doubao
    # rule, tested against whichever tools happen to be installed here.)
    $scanProbe = Find-InstalledAgentTools
    if (-not $scanProbe.ok) { throw "FAIL: the tool catalog cannot be read: $($scanProbe.error)" }
    # Two of the installed ones are named in `exclude` below, so a machine with
    # only two would leave nothing to add and the assertions become vacuous.
    if (@($scanProbe.installed).Count -lt 3) {
        throw "FAIL: only $(@($scanProbe.installed).Count) installed tool(s) here - the scan assertions below would be vacuous"
    }
    $optOut = @($scanProbe.installed | Select-Object -First 2 | ForEach-Object { $_.Name })

    # Written as bytes with a hand-made comment that contains UTF-8, because a
    # scan reads the config back before rewriting it and an ANSI read turns that
    # comment into mojibake for good.
    $scanJson = ConvertTo-SkillBridgeConfig `
        -Comment '扫描夹具注释 - scan fixture note' `
        -LinkType 'junction' `
        -Source (Join-Path $tmp 'src') `
        -Exclude $optOut `
        -Targets ([ordered]@{
            WebUi     = (Join-Path $tmp 'tgt')
            WebUiCopy = @{ path = (Join-Path $tmp 'tgt-copy'); mode = 'copy' }
        }) `
        -Autolink @{ enabled = $false; at_logon = $true; interval_minutes = 0 } `
        -CheckDb $true
    [System.IO.File]::WriteAllText($cfgPath, $scanJson, (New-Object System.Text.UTF8Encoding($false)))

    # The dashboard runs against this config and must write nothing else: the
    # repo's own config.json is the operator's file, and a route that writes it
    # would silently rewrite their real target list.
    $repoCfg = Join-Path $root 'config.json'
    $repoBefore = if (Test-Path -LiteralPath $repoCfg) { [IO.File]::ReadAllBytes($repoCfg) } else { $null }

    $scan = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/scan-tools' -Token $Token -Body '{}') 'POST /api/scan-tools'
    if (-not $scan.ok) { throw "FAIL: the tool scan failed: $($scan.error)" }
    if (-not $scan.wrote) { throw 'FAIL: the scan reported nothing to add on a config with no catalog target' }
    $scanAfter = Read-ConfigFile $cfgPath
    if ($null -eq $scanAfter) { throw "FAIL: the scan left config.json unreadable: $cfgPath" }
    $namesAfter = @($scanAfter.targets.PSObject.Properties.Name | Where-Object { $_ })
    if ($namesAfter -notcontains 'WebUi') { throw "FAIL: the scan dropped the custom target WebUi: $($namesAfter -join ', ')" }
    if ($scanAfter.targets.WebUi -ne (Join-Path $tmp 'tgt')) { throw 'FAIL: the scan changed the path of a target it did not touch' }
    if ($scanAfter.targets.WebUiCopy.mode -ne 'copy') { throw "FAIL: the scan changed a copy target's mode: $($scanAfter.targets.WebUiCopy.mode)" }

    # Every name it added has to be a real catalog tool, and it has to be in the
    # file afterwards - a reported add that is not written is the silent kind.
    $catalogNames = @($scanProbe.tools | ForEach-Object { $_.Name })
    foreach ($n in @($scan.added)) {
        if ($catalogNames -notcontains $n) { throw "FAIL: the scan added '$n', which is not in supported-tools.json" }
        if ($namesAfter -notcontains $n) { throw "FAIL: the scan reported adding '$n' but config.json does not contain it" }
    }
    if (@($scan.added).Count -lt 1) { throw 'FAIL: the scan wrote the file but reported no added tool' }
    foreach ($n in $optOut) {
        if ($namesAfter -contains $n) { throw "FAIL: the scan re-added '$n', which config exclude removes on purpose" }
    }
    if ($scanAfter.source -ne (Join-Path $tmp 'src')) { throw "FAIL: the scan changed source: $($scanAfter.source)" }
    if ($scanAfter.check_db -ne $true) { throw 'FAIL: the scan changed check_db' }
    if ($scanAfter.autolink.enabled -ne $false) { throw 'FAIL: the scan changed autolink' }
    if ($scanAfter.exclude -join ',' -ne ($optOut -join ',')) { throw "FAIL: the scan rewrote exclude: $($scanAfter.exclude -join ',')" }
    if ($scanAfter.'$comment' -notmatch '扫描夹具注释') {
        throw ('FAIL: the UTF-8 $comment entry did not survive the scan: ' + $scanAfter.'$comment')
    }
    if (@($scan.installed).Count -lt 1) { throw 'FAIL: the scan payload reports no installed tool at all' }

    # A second scan has nothing left to add, and must not rewrite the file at
    # all: a scan that reorders the operator's config for nothing is noise.
    $bytesBefore = [IO.File]::ReadAllBytes($cfgPath)
    $scan2 = Get-JsonResult (Invoke-Api -Method 'POST' -Path 'api/scan-tools' -Token $Token -Body '{}') 'POST /api/scan-tools (second)'
    if (-not $scan2.ok) { throw "FAIL: the second scan failed: $($scan2.error)" }
    if ($scan2.wrote) { throw "FAIL: the second scan rewrote config.json with nothing to add: $($scan2.added -join ', ')" }
    if (@($scan2.added).Count -ne 0) { throw "FAIL: the second scan reported a change it did not write: $($scan2.added -join ', ')" }
    $bytesAfter = [IO.File]::ReadAllBytes($cfgPath)
    if ($bytesAfter.Length -ne $bytesBefore.Length) { throw 'FAIL: the second scan changed the size of config.json' }
    for ($i = 0; $i -lt $bytesBefore.Length; $i++) {
        if ($bytesAfter[$i] -ne $bytesBefore[$i]) { throw "FAIL: the second scan rewrote config.json at byte $i" }
    }

    if ($null -ne $repoBefore) {
        $repoAfter = [IO.File]::ReadAllBytes($repoCfg)
        if ($repoAfter.Length -ne $repoBefore.Length) {
            throw "FAIL: the scan wrote the repo's own config.json ($($repoCfg))"
        }
        for ($i = 0; $i -lt $repoBefore.Length; $i++) {
            if ($repoAfter[$i] -ne $repoBefore[$i]) { throw "FAIL: the scan modified the repo's config.json at byte $i" }
        }
    }
    Write-Host 'OK: the tool scan adds installed tools, honours exclude, rewrites nothing else'

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
    if ($srvOut -notmatch 'delete requested: demo-skill' -or $srvOut -notmatch 'deleted demo-skill') {
        throw "FAIL: the server did not log the driven delete: $srvOut"
    }
    if ($srvOut -notmatch 'import requested' -or $srvOut -notmatch 'imported: inbox-skill') {
        throw "FAIL: the server did not log the driven import: $srvOut"
    }
    if ($srvOut -notmatch 'delete refused \(\.\.\)') {
        throw "FAIL: the server did not log the refused delete attempt: $srvOut"
    }
    if ($srvOut -notmatch 'delete requested: 2 skills' -or $srvOut -notmatch 'deleted 2 skills') {
        throw "FAIL: the server did not log the driven batch delete: $srvOut"
    }
    if ($srvOut -notmatch 'batch delete not clean' -or $srvOut -notmatch 'refused \(no-such-skill\)') {
        throw "FAIL: the server did not log the partial batch as not clean: $srvOut"
    }
    Write-Host 'OK: web-ui smoke (page+token, 403 gate, 405/404, add/delete round trip, batch delete, zip-slip, snapshot, skill browser, log tail, driven sync, report-only db-check, loopback bind, clean stop)'
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
