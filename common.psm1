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
