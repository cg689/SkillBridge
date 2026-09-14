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

function Get-TargetSpec {
    param($Value)
    # A target is either a path string (link mode) or { path, mode } where
    # mode is "link" (junction/symlink) or "copy" (real files, for Cloud Agents).
    if ($null -eq $Value) {
        return [pscustomobject]@{ Path = ''; Mode = 'link' }
    }
    if ($Value -is [string]) {
        return [pscustomobject]@{ Path = [string]$Value; Mode = 'link' }
    }
    $path = ''
    if ($null -ne $Value.path) { $path = [string]$Value.path }
    elseif ($null -ne $Value.skills) { $path = [string]$Value.skills }
    $mode = 'link'
    if ($null -ne $Value.mode) { $mode = ([string]$Value.mode).ToLowerInvariant() }
    if ($mode -in @('junction', 'symlink')) { $mode = 'link' }
    if ($mode -ne 'copy') { $mode = 'link' }
    return [pscustomobject]@{ Path = $path; Mode = $mode }
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
    # Cheap "did this skill change?" check: SKILL.md bytes + file count.
    # Read bytes directly so we do not depend on Get-FileHash (EAP Continue
    # can swallow a failure and yield two empty hashes that compare equal).
    $md = Join-Path $Dir 'SKILL.md'
    $hash = 'missing'
    if (Test-Path -LiteralPath $md) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [IO.File]::ReadAllBytes($md)
            $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
        } finally {
            $sha.Dispose()
        }
    }
    $count = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.skillbridge-copy' }).Count
    return "${hash}:${count}"
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
        [string]$SourceRoot,
        $ManagedSet
    )
    # A dest entry is "ours" if we recorded it, or if it is a link pointing
    # into the CC Switch source (left over from an older junction/symlink run).
    if ($null -eq $Item) { return $false }
    if ($ManagedSet -and $ManagedSet.Contains([string]$Item.Name)) { return $true }
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
        [string]$Destination
    )
    # Copy file-by-file. Copy-Item -Recurse of a directory can produce a
    # reparse point on some Windows hosts; Cloud Agents cannot follow those.
    if (Test-Path -LiteralPath $Destination) {
        Remove-SkillEntry $Destination
    }
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            if (Test-ReparsePoint $item) { continue }
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
