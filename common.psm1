# common.psm1 — shared helpers for the SkillBridge PowerShell scripts.
#
# Imported (dot-sourced) from sync-skills.ps1, detect-tools.ps1 and
# install-autolink.ps1 so that env-var path expansion, config loading and log
# writes live in ONE place across all scripts.

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
    if (-not (Test-Path $Path)) { return $null }
    try {
        return Get-Content $Path -Raw | ConvertFrom-Json
    } catch {
        return $null
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
        if ($normT.StartsWith($normSrc, [StringComparison]::OrdinalIgnoreCase)) {
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
    }
    [void][IO.Directory]::CreateDirectory($Destination)
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
    if ($WriteMarker) {
        Write-CopyMarker $Destination
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
