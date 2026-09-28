# common.psm1 — shared helpers for the SkillBridge PowerShell scripts.
#
# Imported (dot-sourced) from sync-skills.ps1, detect-tools.ps1,
# install-autolink.ps1 and web-ui.ps1 so that env-var path expansion, config
# loading and log writes live in ONE place across all scripts.

function Expand-EnvPath {
    param([string]$Path)
    # Windows: expand any %VAR% (USERPROFILE/APPDATA/HERMES_HOME/...) from the real environment
    if ($env:OS -eq 'Windows_NT') {
        return [Environment]::ExpandEnvironmentVariables($Path)
    }
    # Unix: expand $HOME
    return $Path.Replace('$HOME', $HOME)
}

function Assert-ExpandablePath {
    param(
        [string]$Path,
        [string]$What
    )
    # A path that still contains %...% after expansion means an env var was
    # undefined; creating it would litter a literal "%VAR%" directory in CWD.
    # An empty path is never a usable target dir either.
    if ($Path -match '%[A-Za-z_][A-Za-z0-9_]*%') {
        Write-Warning "SKIP $What : unresolved env var in '$Path' (e.g. %HERMES_HOME% unset?)"
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Warning "SKIP $What : empty path"
        return $false
    }
    return $true
}

function Read-ConfigFile {
    param([string]$Path)
    # Safe config read: missing file or malformed JSON yields $null instead of
    # a terminating error. Callers decide how to react to $null.
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bytes = $null
    try { $bytes = [IO.File]::ReadAllBytes($Path) } catch { return $null }
    try {
        # Get-Content decodes as ANSI under 5.1, and the config holds a
        # hand-written $comment that is often the only machine-specific record
        # there is. Decoding it wrong and writing it back (detect-tools.ps1
        # rewrites the whole file) turns that record into mojibake for good, so
        # read the bytes as what JSON is: UTF-8, minus a BOM if present.
        $text = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
        return $text | ConvertFrom-Json
    } catch {
        # A config hand-edited in ANSI (an old one, before this) still has to
        # open; only the characters it holds are then read as the shell reads
        # them, which is the behaviour this branch deliberately avoids above.
        try { return (Get-Content $Path -Raw) | ConvertFrom-Json } catch { return $null }
    }
}

function Get-AutolinkDefaults {
    param($Autolink)
    # The `autolink` block of config.json, with the documented defaults applied.
    # Shared so install-autolink.ps1 and detect-tools.ps1 never drift on them.
    return [pscustomobject]@{
        enabled          = if ($Autolink -and $null -ne $Autolink.enabled)          { [bool]$Autolink.enabled }          else { $true }
        at_logon         = if ($Autolink -and $null -ne $Autolink.at_logon)         { [bool]$Autolink.at_logon }         else { $true }
        interval_minutes = if ($Autolink -and $null -ne $Autolink.interval_minutes) { [int]$Autolink.interval_minutes } else { 0 }
    }
}

function Write-Log {
    param(
        [string[]]$Lines,
        [string]$Path
    )
    # Append under an exclusive lock so concurrent runs (login task + manual
    # double-click) never interleave partial lines in the shared log.
    $retries = 5
    $fs = $null
    for ($i = 0; $i -lt $retries; $i++) {
        try {
            $fs = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read)
            break
        } catch {
            if ($i -eq $retries - 1) {
                # Don't let a contended log kill the whole sync — the links are
                # already made; warn and skip the log write instead.
                Write-Warning "Write-Log: could not lock '$Path' after $retries tries; skipping log write."
                return
            }
            Start-Sleep -Milliseconds 100
        }
    }
    try {
        $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
        foreach ($line in $Lines) { $sw.WriteLine($line) }
        $sw.Dispose()
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
}

function Resolve-TargetPath {
    param([string]$Path)
    # Expand env vars, then turn a relative path (e.g. .cursor/skills) into an
    # absolute one so copy-mode targets and --CopyInto work from any CWD.
    $expanded = Expand-EnvPath $Path
    if ([string]::IsNullOrWhiteSpace($expanded)) { return $expanded }
    # Leave unresolved %VAR% paths alone so Assert-ExpandablePath can skip them
    # (do not Join-Path them onto CWD or the warning shows a bogus absolute).
    if ($expanded -match '%[A-Za-z_][A-Za-z0-9_]*%') { return $expanded }
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = [IO.Path]::GetFullPath((Join-Path (Get-Location) $expanded))
    }
    return $expanded
}

function Get-CopyMarkerName {
    return '.skillbridge-copy'
}

function Test-CursorCopyTarget {
    param(
        [string]$Name,
        [string]$Path
    )
    # Cursor (by name or ~/.cursor/skills path) cannot follow junctions.
    # A leftover string target would keep creating a dead link for Cloud Agents.
    if ($Name -and $Name.Equals('Cursor', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $norm = $Path.Replace('\', '/').TrimEnd('/')
    if ($norm.EndsWith('/.cursor/skills', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($norm.Equals('.cursor/skills', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Get-TargetSpec {
    param(
        $Value,
        [string]$Name = ''
    )
    # A target is either a path string (link mode) or { path, mode } where
    # mode is "link" (junction/symlink) or "copy" (real files, for Cloud Agents).
    # Cursor string paths are promoted to copy so an old config.json still works.
    if ($null -eq $Value) {
        return [pscustomobject]@{ Path = ''; Mode = 'link'; Promoted = $false }
    }
    $path = ''
    $mode = 'link'
    if ($Value -is [string]) {
        $path = [string]$Value
    } else {
        if ($null -ne $Value.path) { $path = [string]$Value.path }
        elseif ($null -ne $Value.skills) { $path = [string]$Value.skills }
        if ($null -ne $Value.mode) { $mode = ([string]$Value.mode).ToLowerInvariant() }
        if ($mode -in @('junction', 'symlink')) { $mode = 'link' }
        if ($mode -ne 'copy') { $mode = 'link' }
    }
    $promoted = $false
    if ($mode -ne 'copy' -and (Test-CursorCopyTarget -Name $Name -Path $path)) {
        $mode = 'copy'
        $promoted = $true
    }
    return [pscustomobject]@{ Path = $path; Mode = $mode; Promoted = $promoted }
}

function Test-SameResolvedPath {
    param(
        [string]$Left,
        [string]$Right
    )
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    try {
        $a = [IO.Path]::GetFullPath($Left.TrimEnd('\', '/'))
        $b = [IO.Path]::GetFullPath($Right.TrimEnd('\', '/'))
        return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-CopyMarker {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    return Test-Path -LiteralPath (Join-Path $Dir (Get-CopyMarkerName)) -PathType Leaf
}

function Write-CopyMarker {
    param([string]$Dir)
    $marker = Join-Path $Dir (Get-CopyMarkerName)
    [IO.File]::WriteAllText($marker, "skillbridge-copy`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Test-ReparsePoint {
    param($Item)
    # pwsh sometimes leaves LinkType empty on junctions; Attributes is reliable.
    if ($null -eq $Item) { return $false }
    if ($Item.LinkType) { return $true }
    try {
        return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } catch {
        return $false
    }
}

function Get-SkillFingerprint {
    param([string]$Dir)
    # Hash every regular file except the copy marker, in relative-path order.
    # The marker is dest-only, so including it would make every refresh a miss.
    # Read bytes directly so we do not depend on Get-FileHash (EAP Continue
    # can swallow a failure and yield two empty hashes that compare equal).
    if (-not (Test-Path -LiteralPath $Dir)) { return 'missing:0' }
    $marker = Get-CopyMarkerName
    $prefixLen = $Dir.TrimEnd('\', '/').Length
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ne $marker -and -not (Test-ReparsePoint $_)
        } |
        Sort-Object {
            $_.FullName.Substring($prefixLen).TrimStart('\', '/').Replace('\', '/')
        })
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $zero = [byte[]](0)
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($prefixLen).TrimStart('\', '/').Replace('\', '/')
            $relBytes = [Text.Encoding]::UTF8.GetBytes($rel)
            if ($relBytes.Length -gt 0) {
                [void]$sha.TransformBlock($relBytes, 0, $relBytes.Length, $null, 0)
            }
            [void]$sha.TransformBlock($zero, 0, 1, $null, 0)
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            if ($bytes.Length -gt 0) {
                [void]$sha.TransformBlock($bytes, 0, $bytes.Length, $null, 0)
            }
            [void]$sha.TransformBlock($zero, 0, 1, $null, 0)
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $hash = [BitConverter]::ToString($sha.Hash).Replace('-', '')
        return "${hash}:$($files.Count)"
    } finally {
        $sha.Dispose()
    }
}

function Read-ManagedSkills {
    param([string]$TargetDir)
    $file = Join-Path $TargetDir '.skillbridge-managed.json'
    $cfg = Read-ConfigFile $file
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($cfg -and $cfg.skills) {
        foreach ($n in @($cfg.skills)) { [void]$set.Add([string]$n) }
    }
    # Unary comma: PowerShell enumerates a returned HashSet, so an empty one
    # becomes $null and the caller cannot .Add.
    return , $set
}

function Write-ManagedSkills {
    param(
        [string]$TargetDir,
        # Untyped on purpose: [string[]] / [IEnumerable] make PowerShell
        # enumerate a HashSet (or call a missing ToArray) before the function runs.
        $Names
    )
    $file = Join-Path $TargetDir '.skillbridge-managed.json'
    $list = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $Names) {
        foreach ($n in $Names) {
            if ($n) { $list.Add([string]$n) }
        }
    }
    $list.Sort()
    $escaped = foreach ($n in $list) {
        '"' + ([string]$n).Replace('\', '\\').Replace('"', '\"') + '"'
    }
    $json = '{ "skills": [' + ($escaped -join ', ') + '] }'
    [IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-OurSkillEntry {
    param(
        $Item,
        [string]$SourceRoot
    )
    # Ownership is proven by a dest-side marker or a link into the source.
    # .skillbridge-managed.json is only an index — a polluted or stale list
    # must never authorize deleting a tool's own directory.
    if ($null -eq $Item) { return $false }
    if (-not (Test-ReparsePoint $Item) -and (Test-CopyMarker $Item.FullName)) {
        return $true
    }
    $t = $null
    if ($Item.LinkType) { $t = [string]$Item.Target }
    elseif (Test-ReparsePoint $Item) { $t = [string]$Item.Target }
    if ($t) {
        $normSrc = $SourceRoot.TrimEnd('\', '/')
        $normT = $t.TrimEnd('\', '/')
        # The separator matters: without it a link into a sibling folder
        # ('...\skills-backup\demo') string-matches the source prefix
        # ('...\skills') and a foreign link gets treated as ours. Mirrors the
        # "$srcn"|"$srcn"/* case in sync-skills.sh.
        if ($normT.Equals($normSrc, [StringComparison]::OrdinalIgnoreCase) -or
            $normT.StartsWith("$normSrc\", [StringComparison]::OrdinalIgnoreCase) -or
            $normT.StartsWith("$normSrc/", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Copy-SkillDirectory {
    param(
        [string]$Source,
        [string]$Destination,
        [switch]$WriteMarker
    )
    # Copy file-by-file. Copy-Item -Recurse of a directory can produce a
    # reparse point on some Windows hosts; Cloud Agents cannot follow those.
    # Skip reparse points / the dest-only marker so we never re-copy a link.
    if (Test-Path -LiteralPath $Destination) {
        Remove-SkillEntry $Destination
        # Do not claim a directory we failed to clear: writing the marker below
        # into a tool's own folder would make it ours on every later run.
        if (Test-Path -LiteralPath $Destination) {
            throw "could not remove existing entry: $Destination"
        }
    }
    [void][IO.Directory]::CreateDirectory($Destination)
    # Claim ownership BEFORE copying. Writing the marker last meant a copy that
    # died halfway left an unmarked directory, which the next run classified as
    # the tool's own folder and skipped forever — stale content, no warning.
    # The marker is excluded from the fingerprint, so this changes no comparison.
    if ($WriteMarker) {
        Write-CopyMarker $Destination
    }
    $marker = Get-CopyMarkerName
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        if ($item.Name -eq $marker) { continue }
        if (Test-ReparsePoint $item) { continue }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-SkillDirectory -Source $item.FullName -Destination $target
        } else {
            [IO.File]::Copy($item.FullName, $target, $true)
        }
    }
}

function Remove-SkillEntry {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    # Never Remove-Item -Recurse a reparse point: it can walk into the target
    # and delete the CC Switch source skill.
    if (Test-ReparsePoint $item) {
        try { [IO.Directory]::Delete($item.FullName, $false) } catch {
            try { [IO.File]::Delete($item.FullName) } catch { }
        }
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-PythonExe {
    # Locate an interpreter for the optional database consistency check
    # (check-db-sync.py). Returns $null when none is found, so callers can skip
    # the check instead of failing the whole sync over a missing extra.
    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    return $null
}

function Get-RunStatusPath {
    # Next to sync-skills.log, so one folder holds the whole run history.
    param([string]$LogPath)
    Join-Path (Split-Path -Parent $LogPath) '.skillbridge-status.json'
}

function Write-RunStatus {
    # The scheduled run is hidden, so a failure is invisible unless it records
    # itself somewhere a person will look. Overwritten every run on purpose:
    # only the latest outcome matters.
    param(
        [string]$Path,
        [ValidateSet('ok', 'warn', 'fail')][string]$Status,
        [string]$Message = ''
    )
    try {
        $record = [ordered]@{
            status  = $Status
            at      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            message = $Message
        }
        [IO.File]::WriteAllText(
            $Path,
            ($record | ConvertTo-Json -Compress -Depth 3),
            (New-Object Text.UTF8Encoding($false)))
    } catch {
        # A failure to record a failure must not create a second one.
    }
}

function Read-RunStatus {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Show-StatusToast {
    # Surfaced for runs nobody is watching (the scheduled task runs hidden).
    # Best effort: no desktop, or CI, means silently stay quiet.
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet('ok', 'warn', 'fail')][string]$Status = 'fail',
        [int]$Seconds = 10
    )
    if ($Status -eq 'ok') { return }
    if ($env:CI -or $env:SKILLBRIDGE_NO_NOTIFY) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Warning
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText  = $Message
        $icon.Visible = $true
        $icon.ShowBalloonTip($Seconds * 1000)
        # Without a wait, the process exits and the balloon dies with it.
        Start-Sleep -Seconds $Seconds
        $icon.Dispose()
    } catch {
        # No interactive desktop (or no WinForms): the status file is the record.
    }
}

function Get-SkillFrontMatter {
    param([string]$Path)
    # SKILL.md opens with a YAML block: `---` at the top, then `name:` and
    # `description:`, then `---` again. The description is usually a folded
    # scalar (`>-` with the text on the indented lines underneath), so reading
    # only the `description:` line loses most of it. Only these two fields are
    # ever wanted, so they are parsed by hand rather than by a YAML parser.
    $empty = [pscustomobject]@{ name = ''; description = '' }
    try {
        $lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
    } catch {
        return $empty
    }
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { return $empty }

    $block = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { break }
        $block.Add($lines[$i])
    }

    $name = ''
    $description = ''
    for ($i = 0; $i -lt $block.Count; $i++) {
        $line = $block[$i]
        if ($line -match '^name:\s*(.*)$') {
            $name = $Matches[1].Trim().Trim('"', "'")
            continue
        }
        if ($line -notmatch '^description:\s*(.*)$') { continue }
        $head = $Matches[1].Trim()
        if ($head -match '^[>|][+-]?$') {
            $parts = New-Object 'System.Collections.Generic.List[string]'
            for ($j = $i + 1; $j -lt $block.Count; $j++) {
                if ($block[$j].Trim() -eq '') { continue }
                # Anything not indented belongs to the next key.
                if (-not ($block[$j].StartsWith(' ') -or $block[$j].StartsWith("`t"))) { break }
                $parts.Add($block[$j].Trim())
            }
            $description = ($parts -join ' ')
        } else {
            $description = $head.Trim('"', "'")
        }
    }
    # A folded block keeps its line breaks as single spaces; collapse whatever
    # is left so the UI never renders a raw newline inside a one-line row.
    $description = ($description -replace '\s+', ' ').Trim()
    return [pscustomobject]@{ name = $name; description = $description }
}

function Get-SkillCatalog {
    param([string]$Path = (Join-Path $PSScriptRoot 'skill-catalog.zh-CN.json'))
    # Hand-maintained Chinese overlay for the dashboard's skill browser: a
    # one-line intro and a category per skill. It is data, not authority — the
    # skill's own SKILL.md is still what a tool reads, and the original
    # description stays in the payload as a fallback.
    $empty = [pscustomobject]@{
        categories = @()
        notes      = @{}   # skill name -> @{ cat = ''; desc = '' }
        unknown    = @()   # category ids used by a skill but not declared
        path       = $Path
        loaded     = $false
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $empty }

    try {
        $json = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        # A broken hand-edited file must not take the whole skill browser down:
        # the page falls back to each skill's own description.
        Write-Verbose "skill-catalog: $($_.Exception.Message)"
        return $empty
    }
    if ($null -eq $json -or $null -eq $json.categories -or $null -eq $json.skills) { return $empty }

    $known = @{}
    foreach ($c in @($json.categories)) {
        if ($c.id) { $known[[string]$c.id] = $true }
    }
    $notes = @{}
    foreach ($p in @($json.skills.PSObject.Properties)) {
        $cat = [string]$p.Value.cat
        if (-not $cat) { continue }
        $notes[$p.Name] = [pscustomobject]@{ cat = $cat; desc = [string]$p.Value.desc }
        if (-not $known.ContainsKey($cat)) { $empty.unknown += $cat }
    }
    $empty.categories = @($json.categories | ForEach-Object {
        [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name; desc = [string]$_.desc }
    })
    $empty.notes  = $notes
    $empty.loaded = $true
    return $empty
}

function Get-SkillBridgeSkills {
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
        [string]$CatalogPath = (Join-Path $PSScriptRoot 'skill-catalog.zh-CN.json')
    )
    # The per-skill view behind the dashboard's skill browser: what a skill is
    # (name, description, how many files, how big, when it last changed), which
    # category the catalog puts it in, and where it landed (link or copy, per
    # target). Deliberately separate from Get-SkillBridgeStatus: this reads 100+
    # SKILL.md files and walks every skill folder, which is far more work than
    # the 15-second snapshot should pay for. The UI asks for it when the browser
    # is opened, not every poll.
    $result = [ordered]@{
        generated_at  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        source        = ''
        source_exists = $false
        count         = 0
        targets       = @()
        categories    = @()
        skills        = @()
        error         = ''
    }

    $snapshot = Get-SkillBridgeStatus -ConfigPath $ConfigPath -SkipFingerprints -IncludeSyncMap
    $result.source        = $snapshot.source
    $result.source_exists = $snapshot.source_exists
    # Just enough per target for the skill rows to explain the coverage numbers.
    $result.targets       = @($snapshot.targets | ForEach-Object {
        [pscustomobject]@{ name = $_.name; mode = $_.mode; exists = $_.exists }
    })
    if ($snapshot.error) {
        $result.error = $snapshot.error
        return [pscustomobject]$result
    }

    $src = $snapshot.source
    $catalog = Get-SkillCatalog -Path $CatalogPath
    $catName = @{}
    foreach ($c in $catalog.categories) { $catName[$c.id] = $c.name }
    # Skills the catalog says nothing about land in one bucket rather than
    # disappearing from the list — an uncatalogued skill is a documentation gap,
    # not something to hide.
    $otherId = 'other'
    $catCount = @{}
    $catCovered = @{}

    # Same two rules as sync-skills.ps1: `_archived/` is not a skill, and a
    # folder without SKILL.md is not one either.
    $skillDirs = @(Get-ChildItem -LiteralPath $src -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Name.StartsWith('_') -and (Test-Path (Join-Path $_.FullName 'SKILL.md'))
        } | Sort-Object Name)

    $skills = @()
    foreach ($dir in $skillDirs) {
        # A reparse point here would be a link into somewhere else; counting the
        # files behind it would report the wrong size and could loop.
        $files = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-ReparsePoint $_) })
        $size = [long]0
        $modified = $null
        foreach ($f in $files) {
            $size += [long]$f.Length
            if ($null -eq $modified -or $f.LastWriteTime -gt $modified) { $modified = $f.LastWriteTime }
        }
        $meta = Get-SkillFrontMatter (Join-Path $dir.FullName 'SKILL.md')
        $note = $null
        if ($catalog.notes.ContainsKey($dir.Name)) { $note = $catalog.notes[$dir.Name] }
        $catId = if ($note -and $note.cat) { [string]$note.cat } else { $otherId }
        $catCount[$catId] = 1 + $(if ($catCount.ContainsKey($catId)) { $catCount[$catId] } else { 0 })
        $covered = $false

        # `has` maps target name -> what is actually on disk there ("link" or
        # "copy"); the mode the config asks for comes from result.targets, and
        # the two disagreeing (a link left inside a copy target) is exactly the
        # drift the sync repairs, so a row has to be able to show it.
        # Plain arrays and hashtables on purpose: PowerShell 5.1 cannot bind a
        # List[object] into an object property (ArgumentException at runtime, with
        # nothing in the message pointing back here).
        $has = @{}
        $missing = @()
        $blocked = @()
        foreach ($t in $snapshot.targets) {
            $kind = $null
            if ($t.sync_map -and $t.sync_map.ContainsKey($dir.Name)) {
                $kind = [string]$t.sync_map[$dir.Name]
            }
            if ($kind) {
                # `kind` is what is actually on disk, `mode` what the config asks
                # for: a link inside a copy target is exactly the drift the sync
                # fixes, and the row should say so.
                $has[$t.name] = $kind
            } elseif (@($t.shadowed) -contains $dir.Name) {
                # The tool ships its own folder under this name, so the sync will
                # never place this skill there. Reporting it as missing would
                # suggest a sync could fix it, which it cannot.
                $blocked += $t.name
            } else {
                $missing += $t.name
            }
        }
        # Fully covered = every configured target holds it. The category counts
        # use it to say "12/12 个已同步" next to the category name.
        if (@($missing).Count -eq 0) {
            $covered = $true
            $catCovered[$catId] = 1 + $(if ($catCovered.ContainsKey($catId)) { $catCovered[$catId] } else { 0 })
        }

        $skills += [pscustomobject]@{
            name        = $dir.Name
            description = $meta.description
            intro       = if ($note) { [string]$note.desc } else { '' }
            cat         = $catId
            cat_name    = if ($catName.ContainsKey($catId)) { $catName[$catId] } else { '其他' }
            covered     = $covered
            files       = $files.Count
            size        = $size
            modified    = if ($modified) { $modified.ToString('yyyy-MM-dd HH:mm') } else { '' }
            has         = $has
            missing     = @($missing)
            blocked     = @($blocked)
            path        = $dir.FullName
        }
    }

    # Category summary in the catalog's order, then the catch-all last. Only
    # categories that actually hold a skill are listed, so a category the user
    # is not using does not clutter the filter bar.
    $cats = @()
    foreach ($c in $catalog.categories) {
        if (-not $catCount.ContainsKey($c.id)) { continue }
        $cats += [pscustomobject]@{
            id = $c.id; name = $c.name; desc = $c.desc
            count = [int]$catCount[$c.id]; covered = [int]$catCovered[$c.id]
        }
    }
    if ($catCount.ContainsKey($otherId)) {
        $cats += [pscustomobject]@{
            id = $otherId; name = '其他'; desc = '中文分类表里还没有的技能，按源目录里的原始描述显示。'
            count = [int]$catCount[$otherId]; covered = [int]$catCovered[$otherId]
        }
    }
    $result.categories = @($cats)
    $result.count  = $skills.Count
    $result.skills = @($skills)
    return [pscustomobject]$result
}

# -------------------------------------------------------------- skill CRUD
# Editing the source folder is a different class of operation from anything
# else here: the source IS CC Switch's own skills directory, so adding or
# deleting a skill changes what every tool on this machine sees. Both
# functions therefore validate hard, say exactly what they did, and touch
# nothing they were not asked to touch. Neither runs a sync: the caller (the
# dashboard) asks for one separately, so the two effects stay visible.
function Test-SkillName {
    param([string]$Name)
    # The folder name is the identity — the sync maps names, not paths — so a
    # "name" that is really a path must not reach the filesystem.
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return $false }
    # CON/PRN/AUX/NUL/COM1../LPT1.. are directories Windows cannot delete again,
    # and a trailing dot or space silently vanishes from paths.
    if ($Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { return $false }
    if ($Name.EndsWith('.') -or $Name.EndsWith(' ')) { return $false }
    return $true
}

function Get-SkillBridgeSourceDir {
    param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))
    $config = Read-ConfigFile $ConfigPath
    if ($null -eq $config) { return '' }
    return ([string](Expand-EnvPath ([string]$config.source))).Trim()
}

function Remove-SkillDirectoryTree {
    param([string]$Path)
    # Never Remove-Item -Recurse on the tree itself: going through
    # Remove-SkillEntry for each child is what keeps a reparse point inside a
    # skill folder (a link someone left there) a link, instead of following it
    # into CC Switch's source skill.
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        Remove-SkillEntry -Path $item.FullName
    }
    [IO.Directory]::Delete($Path)
}

function Remove-SkillBridgeSkill {
    param(
        [string]$Name,
        [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
    )
    # Deletes one source skill folder, after proving it is one of ours to
    # delete. Deliberately not a sync: the 21 targets then hold orphans, which
    # the next sync prunes, and the cc-switch.db row stays behind as drift the
    # report-only check shows — both consequences are stated in the UI before
    # the button is pressed.
    $result = [ordered]@{
        ok    = $false
        name  = $Name
        path  = ''
        files = 0
        size  = [long]0
        error = ''
    }
    $src = Get-SkillBridgeSourceDir -ConfigPath $ConfigPath
    if (-not $src -or -not (Test-Path -LiteralPath $src)) {
        $result.error = "source dir not found: $src (check config.json)"
        return [pscustomobject]$result
    }
    if (-not (Test-SkillName $Name)) {
        $result.error = "illegal skill name: '$Name'"
        return [pscustomobject]$result
    }
    $dir = Join-Path $src $Name
    $result.path = $dir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $result.error = "no such skill: $Name"
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'SKILL.md'))) {
        # Same rule as the sync: a folder without SKILL.md is not a skill, so
        # this is somebody else's directory and must not be removed.
        $result.error = "refusing: '$Name' has no SKILL.md, so the sync does not treat it as a skill"
        return [pscustomobject]$result
    }
    # Counted for the response (the UI echoes it back), not for a guard.
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-ReparsePoint $_) })
    $result.files = $files.Count
    foreach ($f in $files) { $result.size += [long]$f.Length }
    try {
        Remove-SkillDirectoryTree -Path $dir
    } catch {
        $result.error = "delete failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
    if (Test-Path -LiteralPath $dir) {
        $result.error = "delete failed: $dir still exists"
        return [pscustomobject]$result
    }
    $result.ok = $true
    return [pscustomobject]$result
}

function Import-ZipSupport {
    # Makes [IO.Compression.ZipFile] usable and says whether it worked.
    # [Reflection.Assembly]::Load() only searches the GAC, and this assembly is
    # not in the GAC on this machine (it sits in the framework directory), so it
    # throws "cannot find the file" where Add-Type — which also knows the
    # framework directory — succeeds. Loading it twice is harmless.
    #
    # The probe has to be a try/catch, not `[IO.Compression.ZipFile] -as [type]`:
    # the type literal on the left has to resolve BEFORE `-as` ever runs, so the
    # "is it there?" check throws exactly the error it is asking about.
    try { if ($null -ne [IO.Compression.ZipFile]) { return $true } } catch { }
    try { Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction Stop } catch { return $false }
    try { return ($null -ne [IO.Compression.ZipFile]) } catch { return $false }
}

function Install-SkillFromStaging {
    # Moves one unpacked skill directory from the staging area into the source.
    # $Result is the caller's ordered result dictionary, updated in place; only
    # a real failure is an error, everything else is reported back to the user.
    param(
        [string]$Dir,
        [string]$Src,
        [System.Collections.Specialized.OrderedDictionary]$Result,
        # Set when $Dir is the staging area itself, i.e. the package had its
        # SKILL.md at the root instead of inside a folder.
        [switch]$Root
    )
    $meta = Get-SkillFrontMatter (Join-Path $Dir 'SKILL.md')
    $name = Split-Path -Leaf $Dir
    if ($Root) {
        # The staging directory name is not a name anyone chose, so the name
        # has to come from the skill's own front matter.
        if (-not $meta.name) {
            $Result.refused += [pscustomobject]@{ entry = 'SKILL.md'; reason = 'a skill at the package root needs `name:` in its front matter' }
            return
        }
        $name = $meta.name
    }
    if (-not (Test-SkillName $name)) {
        $Result.refused += [pscustomobject]@{ entry = $name; reason = 'not a usable folder name' }
        return
    }
    $dest = Join-Path $Src $name
    if (Test-Path -LiteralPath $dest) {
        # An existing skill is never overwritten: the user has to remove the
        # old one first, which is a decision they can see.
        $Result.skipped += [pscustomobject]@{ name = $name; reason = '同名技能已存在' }
        return
    }
    if ($Root) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        foreach ($child in @(Get-ChildItem -LiteralPath $Dir -Force)) {
            # A child folder that is itself a skill was already handled above
            # (or refused on purpose); folding it into this one would hide it.
            if ($child.PSIsContainer -and (Test-Path -LiteralPath (Join-Path $child.FullName 'SKILL.md'))) { continue }
            if ($child.PSIsContainer) {
                [IO.Directory]::Move($child.FullName, (Join-Path $dest $child.Name))
            } else {
                [IO.File]::Move($child.FullName, (Join-Path $dest $child.Name))
            }
        }
    } else {
        [IO.Directory]::Move($Dir, $dest)
    }
    if ($meta.name -and $meta.name -ne $name) {
        $Result.warnings += ('SKILL.md 里的 name 是「' + $meta.name + '」，与文件夹名「' + $name + '」不一致；同步以文件夹名为准')
    }
    $Result.added += $name
}

function Import-SkillBridgeSkillZip {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
        [int]$MaxUploadBytes    = 33554432,   # 32 MB of packet
        [int]$MaxExtractedBytes = 268435456,  # 256 MB unpacked (zip bomb ceiling)
        [int]$MaxFiles          = 20000
    )
    # Installs the skill folders inside an uploaded .zip into the source.
    #
    # Extraction is done entry by entry rather than with ExtractToDirectory on
    # purpose: .NET Framework's version does not sanitise the entry names, so a
    # zip can name an entry "..\..\Windows\System32\x" and win. Every entry is
    # checked for that (and for being a symlink, which .NET would happily
    # materialise as a regular file with the mode bits set) before it is written.
    $result = [ordered]@{
        ok      = $false
        added   = @()
        skipped = @()
        refused = @()
        warnings = @()
        error   = ''
    }
    if ($Bytes.Length -gt $MaxUploadBytes) {
        $result.error = "the package is {0:N1} MB, over the {1:N0} MB limit" -f ($Bytes.Length / 1MB), ($MaxUploadBytes / 1MB)
        return [pscustomobject]$result
    }
    if ($Bytes.Length -lt 4 -or $Bytes[0] -ne 0x50 -or $Bytes[1] -ne 0x4B) {
        $result.error = 'not a zip file (a zip starts with the bytes PK)'
        return [pscustomobject]$result
    }
    $src = Get-SkillBridgeSourceDir -ConfigPath $ConfigPath
    if (-not $src -or -not (Test-Path -LiteralPath $src)) {
        $result.error = "source dir not found: $src (check config.json)"
        return [pscustomobject]$result
    }

    # Staging inside the source volume: the last step is a rename, which is
    # instant and cannot half-copy a skill into place.
    if (-not (Import-ZipSupport)) {
        $result.error = 'System.IO.Compression.FileSystem is unavailable, so .zip packages cannot be read'
        return [pscustomobject]$result
    }
    $stage = Join-Path $src ('.sb-import-' + [Guid]::NewGuid().ToString('N'))
    $zip   = Join-Path $env:TEMP ('sb-import-' + [Guid]::NewGuid().ToString('N') + '.zip')
    $archive = $null
    try {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        [IO.File]::WriteAllBytes($zip, $Bytes)
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        $stagePath = [IO.Path]::GetFullPath($stage)
        $stageFull = $stagePath
        if (-not $stageFull.EndsWith([IO.Path]::DirectorySeparatorChar)) {
            $stageFull += [IO.Path]::DirectorySeparatorChar
        }
        $total = [long]0
        $count = 0
        foreach ($entry in $archive.Entries) {
            # A directory entry is only a name ending in a separator.
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
            # macOS archive noise, never a skill.
            if ($entry.FullName -match '(^|/)__MACOSX/') { continue }
            if ($entry.FullName -match '(^|/)\._') { continue }
            if ($entry.FullName -match '(^|/)\.DS_Store$') { continue }
            $rel = $entry.FullName.Replace('\', '/').TrimStart('/')
            while ($rel.StartsWith('./')) { $rel = $rel.Substring(2) }
            if ($rel -match '^[A-Za-z]:' -or $rel.StartsWith('/') -or $rel -match '(^|/)\.\.(/|$)') {
                $result.refused += [pscustomobject]@{ entry = $entry.FullName; reason = 'the entry is not inside the package' }
                continue
            }
            # A symlink entry would land as a regular file with the link mode
            # bits set — a skill that is half a link. Refuse instead.
            $mode = ([int]$entry.ExternalAttributes -shr 16) -band 0xF000
            if ($mode -eq 0xA000) {
                $result.refused += [pscustomobject]@{ entry = $entry.FullName; reason = 'the entry is a symbolic link' }
                continue
            }
            $total += [long]$entry.Length
            $count++
            if ($total -gt $MaxExtractedBytes -or $count -gt $MaxFiles) {
                $result.error = 'the package unpacks to far more than a skill should'
                return [pscustomobject]$result
            }
            $dest = [IO.Path]::GetFullPath([IO.Path]::Combine($stage, $rel.Replace('/', [IO.Path]::DirectorySeparatorChar)))
            if (-not $dest.StartsWith($stageFull, [StringComparison]::OrdinalIgnoreCase)) {
                $result.refused += [pscustomobject]@{ entry = $entry.FullName; reason = 'the entry escapes the package directory' }
                continue
            }
            $parent = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        }

        # Skills are the folders that hold a SKILL.md — the same rule the sync
        # uses — so `docs/` or `scripts/` in the zip are simply left behind.
        # Nested skills are installed first and a root-level SKILL.md takes
        # whatever is left, so a package root can never swallow a skill folder.
        $stageRootMd = Join-Path $stage 'SKILL.md'
        $skillDirs = @()
        foreach ($md in @(Get-ChildItem -LiteralPath $stage -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue)) {
            if ($md.DirectoryName -eq $stagePath) { continue }
            $skillDirs += $md.Directory.FullName
        }
        if (-not $skillDirs.Count -and -not (Test-Path -LiteralPath $stageRootMd)) {
            $result.error = 'the package contains no SKILL.md, so there is no skill in it'
            return [pscustomobject]$result
        }
        foreach ($sd in $skillDirs) {
            if (-not (Test-Path -LiteralPath $sd)) { continue }   # already taken with an earlier skill
            Install-SkillFromStaging -Dir $sd -Src $src -Result $result
        }
        if (Test-Path -LiteralPath $stageRootMd) {
            Install-SkillFromStaging -Dir $stagePath -Src $src -Result $result -Root
        }
        if (-not $result.added.Count -and $result.refused.Count) {
            $result.error = ('安装被拒绝：' + $result.refused[0].reason)
        } elseif (-not $result.added.Count) {
            $result.error = '没有新技能被安装'
        } else {
            $result.ok = $true
        }
    } catch {
        $result.error = "import failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    } finally {
        if ($null -ne $archive) { try { $archive.Dispose() } catch { }
        }
        if (Test-Path -LiteralPath $stage) {
            try { Remove-SkillDirectoryTree -Path $stage } catch { }
        }
        if (Test-Path -LiteralPath $zip) {
            try { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    return [pscustomobject]$result
}

function Get-SkillBridgeStatus {
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
        # Hashing every file of every copy-mode target is the slow part of this
        # function (seconds with 100+ skills). Callers that only need link
        # counts pass this and get no stale/out-of-date detection.
        [switch]$SkipFingerprints,
        # Every target then also gets `sync_map`: skill name -> "link" | "copy"
        # for the entries of ours that match a source skill. Only the skill
        # browser needs it; the snapshot the UI polls every 15 seconds stays
        # small without it (~2000 fewer strings on this machine).
        [switch]$IncludeSyncMap
    )
    # ONE snapshot of the whole setup - source, every target, last run - shared
    # by detect-tools.ps1, the health check and the web UI. They read the same
    # object so they can never disagree about what is missing, dead, stale or
    # owned by the tool itself.
    #
    # Field meanings (the sync acts on exactly these):
    #   linked  - a live link into the source, counted once per source skill
    #   copied  - copy-mode skills we own; `stale` is how many of them differ
    #             from the source by content hash
    #   missing - source skills with no entry of ours in the target
    #   orphans - entries we own whose source skill is gone (sync prunes these)
    #   dead    - links that are not ours and do not resolve (never touched)
    #   foreign - the tool's own folders; shadowed = name collides with a source
    #             skill, which makes the sync skip that skill silently
    $snapshot = [ordered]@{
        generated_at  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        health        = 'error'
        error         = ''
        config_path   = $ConfigPath
        source        = ''
        source_exists = $false
        skill_count   = 0
        skills        = @()
        link_type     = 'junction'
        check_db      = $false
        autolink      = $null
        targets       = @()
        totals        = $null
        needs_sync    = $false
        last_run      = $null
    }

    $config = Read-ConfigFile $ConfigPath
    if ($null -eq $config) {
        $snapshot.error = if (Test-Path -LiteralPath $ConfigPath) {
            "could not parse config: $ConfigPath"
        } else {
            "config not found: $ConfigPath"
        }
        return [pscustomobject]$snapshot
    }

    $src = ([string](Expand-EnvPath ([string]$config.source))).Trim()
    $snapshot.source        = $src
    $snapshot.source_exists = [bool](Test-Path -LiteralPath $src)
    $snapshot.link_type     = if ($config.link_type) { [string]$config.link_type } else { 'junction' }
    $snapshot.check_db      = if ($null -ne $config.check_db) { [bool]$config.check_db } else { $false }
    $defaults = Get-AutolinkDefaults $config.autolink
    $snapshot.autolink = [pscustomobject]@{
        enabled          = $defaults.enabled
        at_logon         = $defaults.at_logon
        interval_minutes = $defaults.interval_minutes
    }

    $skillDirs = @()
    if ($snapshot.source_exists) {
        $skillDirs = @(Get-ChildItem -LiteralPath $src -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                # Same two rules as sync-skills.ps1: `_archived/` is not a skill,
                # and a folder without SKILL.md is not one either.
                -not $_.Name.StartsWith('_') -and (Test-Path (Join-Path $_.FullName 'SKILL.md'))
            } | Sort-Object Name)
    }
    $skillNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $skillDirs) { [void]$skillNames.Add($s.Name) }
    $snapshot.skill_count = $skillDirs.Count
    $snapshot.skills      = @($skillDirs | ForEach-Object { $_.Name })

    # One hash per source skill, reused by every copy target below.
    $sourceFingerprints = @{}
    if (-not $SkipFingerprints -and $skillDirs.Count -gt 0) {
        foreach ($s in $skillDirs) {
            $sourceFingerprints[$s.Name] = Get-SkillFingerprint $s.FullName
        }
    }

    $targets = @()
    if ($config.targets) {
        foreach ($entry in $config.targets.PSObject.Properties) {
            $spec = Get-TargetSpec $entry.Value -Name $entry.Name
            $row = [pscustomobject]@{
                name          = [string]$entry.Name
                path          = $spec.Path
                mode          = $spec.Mode
                resolved_path = ''
                exists        = $false
                linked        = 0
                copied        = 0
                stale         = 0
                missing       = @()
                orphans       = @()
                dead          = @()
                foreign       = @()
                shadowed      = @()
                issues        = @()
                # name -> "link" | "copy", but only when the caller asks for it
                # (see Get-SkillBridgeSkills). Built with the same
                # case-insensitive comparer as $skillNames, so lookups match.
                sync_map      = $null
            }
            if ($IncludeSyncMap) {
                $row.sync_map = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
            }
            $targets += $row

            $tdir = Resolve-TargetPath $spec.Path
            if (-not (Assert-ExpandablePath $tdir $row.name)) {
                $row.issues += "unresolved path: $($spec.Path)"
                continue
            }
            $row.resolved_path = $tdir
            $row.exists = [bool](Test-Path -LiteralPath $tdir)
            if (-not $row.exists) {
                # Not a fault: the first sync creates the directory.
                $row.issues += 'directory does not exist yet (the next sync creates it)'
                $row.missing = @($snapshot.skills)
                continue
            }
            if (Test-SameResolvedPath $tdir $src) {
                $row.issues += 'target path is the source itself - nothing to sync into'
                continue
            }

            $present = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $marker = Get-CopyMarkerName
            foreach ($item in @(Get-ChildItem -LiteralPath $tdir -Force -ErrorAction SilentlyContinue)) {
                if (-not $item.PSIsContainer) { continue }
                # Our own bookkeeping files: never an entry, never a target's skill.
                if ($item.Name -eq $marker -or $item.Name -eq '.skillbridge-managed.json') { continue }

                if (Test-OurSkillEntry $item $src) {
                    if ($skillNames.Contains($item.Name)) {
                        [void]$present.Add($item.Name)
                        if ($row.sync_map) {
                            $row.sync_map[$item.Name] = if (Test-ReparsePoint $item) { 'link' } else { 'copy' }
                        }
                        if ($spec.Mode -eq 'copy') {
                            $row.copied++
                            if (Test-ReparsePoint $item) {
                                # A link left behind by an older config: Cloud
                                # Agents cannot follow one, so the next sync
                                # replaces it with a real copy.
                                $row.issues += "$($item.Name): still a link in a copy target (next sync replaces it)"
                            } elseif (-not $SkipFingerprints) {
                                if ($sourceFingerprints[$item.Name] -ne (Get-SkillFingerprint $item.FullName)) {
                                    $row.stale++
                                    $row.issues += "$($item.Name): copy differs from the source (next sync refreshes it)"
                                }
                            }
                        } else {
                            $row.linked++
                        }
                    } else {
                        # Ours, but the skill is gone from the source: a dead
                        # junction or a copy left behind. The sync prunes these.
                        $row.orphans += $item.Name
                    }
                    continue
                }

                if (Test-ReparsePoint $item) {
                    # Someone else's link. We never delete what is not ours, so
                    # only report it when it does not resolve at all.
                    $t = [string]$item.Target
                    $resolved = $t
                    if ($t -and -not [IO.Path]::IsPathRooted($t)) {
                        # A relative target resolves against the link's own
                        # directory, not the process CWD.
                        $resolved = [IO.Path]::GetFullPath(
                            (Join-Path (Split-Path -Parent $item.FullName) $t))
                    }
                    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved)) {
                        $row.dead += $item.Name
                    }
                    continue
                }

                if ($skillNames.Contains($item.Name)) {
                    # The tool ships its own folder under this skill's name, so
                    # the sync skips the source skill for this target forever.
                    $row.shadowed += $item.Name
                    $row.foreign   += $item.Name
                    $row.issues    += "$($item.Name): the tool's own folder uses this name, so the source skill is skipped"
                } else {
                    $row.foreign += $item.Name
                }
            }

            $row.missing = @($snapshot.skills | Where-Object { -not $present.Contains($_) })
        }
    }
    $snapshot.targets = $targets

    $sum = @{
        targets = $targets.Count; linked = 0; copied = 0; stale = 0
        missing = 0; orphans = 0; dead = 0; foreign = 0; shadowed = 0; issues = 0
    }
    foreach ($t in $targets) {
        $sum.linked   += $t.linked
        $sum.copied   += $t.copied
        $sum.stale    += $t.stale
        $sum.missing  += @($t.missing).Count
        $sum.orphans  += @($t.orphans).Count
        $sum.dead     += @($t.dead).Count
        $sum.foreign  += @($t.foreign).Count
        $sum.shadowed += @($t.shadowed).Count
        $sum.issues   += @($t.issues).Count
    }
    $snapshot.totals = [pscustomobject]$sum
    $snapshot.needs_sync = ($sum.missing -gt 0 -or $sum.stale -gt 0 -or $sum.orphans -gt 0)

    $snapshot.last_run = Read-RunStatus (Get-RunStatusPath (Join-Path (Split-Path -Parent $ConfigPath) 'sync-skills.log'))

    if (-not $snapshot.source_exists) {
        $snapshot.error = "source dir not found: $src`n        Is CC Switch installed? Set the right path in config.json (source)."
    } elseif ($snapshot.skill_count -eq 0) {
        $snapshot.error = "no skills found in source dir: $src (no subfolder contains SKILL.md)"
    }

    if ($snapshot.error) {
        $snapshot.health = 'error'
    } elseif ($sum.issues -gt 0) {
        $snapshot.health = 'warn'
    } else {
        $snapshot.health = 'ok'
    }
    return [pscustomobject]$snapshot
}

function Find-InstalledAgentTools {
    <#
    .SYNOPSIS
      Reads supported-tools.json and reports which agent tools are installed here.
    .DESCRIPTION
      The catalog is the single source of truth shared with detect-tools.sh, so a
      tool only has to be described once. "Installed" means the tool's marker
      directory exists on disk - not that it is running. A tool named in
      $Exclude is never reported as installed, because the user removed it from
      the sync on purpose and its marker directory outlives the uninstall.
    .OUTPUTS
      ok, error, tools (every catalog entry), installed, not_installed, excluded
      (all catalog objects: Name/Marker/Skills/Mode) and unknown_exclude (names
      the exclude list asked for that the catalog does not have).
    #>
    param(
        [string]$CatalogPath = (Join-Path $PSScriptRoot 'supported-tools.json'),
        [string[]]$Exclude = @(),
        [switch]$All
    )
    $result = [pscustomobject]@{
        ok              = $false
        error           = ''
        tools           = @()
        installed       = @()
        not_installed   = @()
        excluded        = @()
        unknown_exclude = @()
    }
    $catalog = Read-ConfigFile $CatalogPath
    if ($null -eq $catalog -or $null -eq $catalog.tools -or @($catalog.tools).Count -lt 1) {
        $result.error = "catalog missing or empty: $CatalogPath"
        return $result
    }

    $tools = @()
    foreach ($t in @($catalog.tools)) {
        $name = [string]$t.name
        if (-not $name) { continue }
        $tools += [pscustomobject]@{
            Name   = $name
            Marker = [string]$t.marker
            Skills = [string]$t.skills
            Mode   = if ($t.mode) { [string]$t.mode } else { '' }
        }
    }

    # Case-insensitive, like every name comparison in this project: the catalog
    # and the config's `exclude` are edited by hand, by different people, at
    # different times.
    $excludedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @($Exclude)) { if (-not [string]::IsNullOrWhiteSpace([string]$n)) { [void]$excludedSet.Add([string]$n) } }
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $tools) { [void]$known.Add($t.Name) }

    foreach ($t in $tools) {
        if ($excludedSet.Contains($t.Name)) {
            $result.excluded += $t
            continue
        }
        # -LiteralPath: a marker is a directory name, not a wildcard, and a '['
        # in one must not turn the check into a pattern match that never hits.
        if ($All -or (Test-Path -LiteralPath (Expand-EnvPath $t.Marker))) {
            $result.installed += $t
        } else {
            $result.not_installed += $t
        }
    }
    foreach ($n in $excludedSet) {
        if (-not $known.Contains($n)) { $result.unknown_exclude += $n }
    }

    $result.tools = $tools
    $result.ok   = $true
    return $result
}

function ConvertTo-SkillBridgeConfig {
    <# The fixed-shape serializer for config.json. Shared by detect-tools.ps1
       (which rewrites the whole file) and Merge-SkillBridgeToolTargets (which
       only adds to it) so the two can never drift into different formats.
       PS 5.1's ConvertTo-Json indents nested objects irregularly, so this
       writes the file by hand. #>
    param(
        [string]$Comment,
        [string]$LinkType,
        [string]$Source,
        # Untyped on purpose: [string[]] turns an empty @() into $null on some
        # call paths, and this value is only ever joined back into JSON.
        $Exclude,
        [System.Collections.IDictionary]$Targets,
        $Autolink,
        [bool]$CheckDb = $false
    )
    $esc = { param($s) ([string]$s).Replace('\', '\\').Replace('"', '\"') }
    $d = Get-AutolinkDefaults $Autolink
    $enabled  = $d.enabled
    $atLogon  = $d.at_logon
    $interval = $d.interval_minutes

    $excludeItems = @(@($Exclude) | Where-Object { $_ } | ForEach-Object { '"' + (& $esc $_) + '"' })
    $excludeJson = '[' + ($excludeItems -join ', ') + ']'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('{')
    [void]$sb.AppendLine('  "$comment": "' + (& $esc $Comment) + '",')
    [void]$sb.AppendLine('  "link_type": "' + (& $esc $LinkType) + '",')
    [void]$sb.AppendLine('  "source": "' + (& $esc $Source) + '",')
    [void]$sb.AppendLine('  "exclude": ' + $excludeJson + ',')
    [void]$sb.AppendLine('  "targets": {')
    $names = @($Targets.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        $comma = if ($i -lt $names.Count - 1) { ',' } else { '' }
        $val = $Targets[$names[$i]]
        if ($val -is [hashtable] -or ($null -ne $val -and $null -ne $val.mode)) {
            $tPath = if ($val.path) { [string]$val.path } else { [string]$val.skills }
            $tMode = [string]$val.mode
            $line = '    "' + (& $esc $names[$i]) + '": { "path": "'
            $line += (& $esc $tPath) + '", "mode": "' + (& $esc $tMode) + '" }' + $comma
        } else {
            $line = '    "' + (& $esc $names[$i]) + '": "'
            $line += (& $esc ([string]$val)) + '"' + $comma
        }
        [void]$sb.AppendLine($line)
    }
    [void]$sb.AppendLine('  },')
    [void]$sb.AppendLine('  "autolink": {')
    [void]$sb.AppendLine("    `"enabled`": $(if ($enabled) { 'true' } else { 'false' }),")
    [void]$sb.AppendLine("    `"at_logon`": $(if ($atLogon) { 'true' } else { 'false' }),")
    [void]$sb.AppendLine("    `"interval_minutes`": $interval")
    [void]$sb.AppendLine('  },')
    [void]$sb.AppendLine("  `"check_db`": $(if ($CheckDb) { 'true' } else { 'false' })")
    [void]$sb.AppendLine('}')
    return $sb.ToString()
}

function Merge-SkillBridgeToolTargets {
    <#
    .SYNOPSIS
      Scans this machine for installed agent tools and adds the ones the config
      is missing to its `targets`, then writes config.json back.
    .DESCRIPTION
      Additive by design, and deliberately unlike detect-tools.ps1 (which
      rewrites the whole file from the catalog and therefore drops targets whose
      marker directory is gone):

        * only names are added - every existing target keeps its path and mode
        * source / link_type / exclude / autolink / check_db / $comment are
          written back exactly as they were read
        * a tool named in `exclude` is never added, because that list is a
          deliberate opt-out and its marker directory outlives the uninstall
        * nothing is written at all when there is nothing to add
        * if the rewritten file does not parse, or loses a target it had, the
          original bytes are restored and the caller gets ok=$false

      This is what the dashboard's scan button calls: it answers "which agent
      software is installed on this machine" and puts the missing ones into the
      sync list without changing anything the user configured.
    #>
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
        [string]$CatalogPath = (Join-Path $PSScriptRoot 'supported-tools.json')
    )
    $result = [pscustomobject]@{
        ok              = $false
        error           = ''
        wrote           = $false
        added           = @()
        already         = 0
        installed       = @()
        not_installed   = @()
        excluded        = @()
        unknown_exclude = @()
        targets_total   = 0
        source          = ''
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $result.error = "config not found: $ConfigPath"
        return $result
    }
    # The restore source. Written only after the rewrite has been re-read and
    # checked, never "the run succeeded" as a trust fallback.
    $beforeText = [IO.File]::ReadAllText($ConfigPath)
    $existing = Read-ConfigFile $ConfigPath
    if ($null -eq $existing) {
        $result.error = "could not parse config: $ConfigPath"
        return $result
    }
    # No source means the config is not usable yet; detect-tools.ps1 fills in a
    # default guess, but a scan that changes where the skills are read from is
    # not what the operator pressed the button for.
    if ([string]::IsNullOrWhiteSpace([string]$existing.source)) {
        $result.error = 'config.json has no "source": set one before scanning'
        return $result
    }

    $excludeList = @()
    if ($existing.exclude) { foreach ($n in @($existing.exclude)) { if ($n) { $excludeList += [string]$n } } }
    $scan = Find-InstalledAgentTools -CatalogPath $CatalogPath -Exclude $excludeList
    if (-not $scan.ok) {
        $result.error = $scan.error
        return $result
    }

    # ConvertFrom-Json can hand back one property whose Name is $null for an
    # empty `targets` block, and an OrderedDictionary refuses a $null key.
    $existingNames = @()
    if ($existing.targets) { $existingNames = @($existing.targets.PSObject.Properties.Name | Where-Object { $_ }) }
    $have = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $existingNames) { [void]$have.Add([string]$n) }

    $result.installed       = @($scan.installed       | ForEach-Object { $_.Name })
    $result.not_installed   = @($scan.not_installed   | ForEach-Object { $_.Name })
    $result.excluded        = @($scan.excluded        | ForEach-Object { $_.Name })
    $result.unknown_exclude = @($scan.unknown_exclude)
    $result.already         = $existingNames.Count
    $result.source          = ([string](Expand-EnvPath ([string]$existing.source))).Trim()

    $newTools = @($scan.installed | Where-Object { -not $have.Contains($_.Name) })
    if ($newTools.Count -eq 0) {
        # Nothing to change, so nothing is written: a scan must not rewrite the
        # operator's hand-edited comment or reorder their targets for nothing.
        $result.ok = $true
        return $result
    }

    # Carry every existing target across unchanged - string and {path,mode}
    # entries alike - then append what the scan found, in catalog order.
    $merged = [ordered]@{}
    if ($existing.targets) {
        foreach ($p in $existing.targets.PSObject.Properties) {
            $val = $p.Value
            if ($null -eq $val) { continue }
            if ($val -is [string]) {
                $merged[$p.Name] = [string]$val
            } elseif ($null -ne $val.mode) {
                $tPath = if ($null -ne $val.path) { [string]$val.path } else { [string]$val.skills }
                $merged[$p.Name] = @{ path = $tPath; mode = [string]$val.mode }
            } else {
                $merged[$p.Name] = [string](if ($null -ne $val.path) { $val.path } elseif ($null -ne $val.skills) { $val.skills } else { $val })
            }
        }
    }
    foreach ($t in $newTools) {
        if ($t.Mode) {
            $merged[$t.Name] = @{ path = $t.Skills; mode = $t.Mode }
        } else {
            $merged[$t.Name] = $t.Skills
        }
    }

    $mComment = if ($existing.'$comment') {
        [string]$existing.'$comment'
    } else {
        'SkillBridge - auto-generated by detect-tools.ps1 for THIS machine.'
    }
    $mLinkType = if ($existing.link_type) { [string]$existing.link_type } else { 'junction' }
    $mCheckDb  = if ($null -ne $existing.check_db) { [bool]$existing.check_db } else { $false }
    $json = ConvertTo-SkillBridgeConfig `
        -Comment  $mComment `
        -LinkType $mLinkType `
        -Source   ([string]$existing.source) `
        -Exclude  $excludeList `
        -Targets  $merged `
        -Autolink $existing.autolink `
        -CheckDb  $mCheckDb
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    # Re-read what was actually written. A half-written config would turn the
    # next sync into a silent no-op against an empty target list, so a rewrite
    # that cannot be proven to have kept everything is rolled back instead.
    $verify = Read-ConfigFile $ConfigPath
    $problem = ''
    if ($null -eq $verify) {
        $problem = 'the rewritten config.json does not parse'
    } else {
        foreach ($n in $existingNames) {
            if (-not $verify.targets -or -not $verify.targets.PSObject.Properties[$n]) {
                $problem = "target '$n' is gone from the rewritten config.json"
                break
            }
        }
    }
    if ($problem) {
        [IO.File]::WriteAllText($ConfigPath, $beforeText, (New-Object System.Text.UTF8Encoding($false)))
        $result.error = "$problem - config.json restored to what it was"
        return $result
    }

    $result.ok            = $true
    $result.wrote         = $true
    $result.added         = @($newTools | ForEach-Object { $_.Name })
    $result.targets_total = $merged.Count
    return $result
}
