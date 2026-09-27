# sync-skills.ps1 — Mirror CC Switch skills into agent tools via directory junctions.
#
# For every skill in the CC Switch skills dir that is missing in a target tool's
# skills dir, create a directory junction (a "live link") pointing at the source.
# Idempotent: existing entries are never overwritten, so a tool's own skills
# are never clobbered.
#
# NOTE: keep the sync loop's behavior in sync with sync-skills.sh (Unix variant):
# skip/count/log semantics must stay identical across both scripts.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1 -ConfigPath .\my-config.json
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1 -CopyInto .\.cursor\skills
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$CopyInto = ''
)
$ErrorActionPreference = 'Continue'

Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force

# Where the outcome of a hidden run is recorded (the scheduled task runs with
# -WindowStyle Hidden, so a crash would otherwise leave no visible trace).
$statusPath = Get-RunStatusPath (Join-Path $PSScriptRoot 'sync-skills.log')

function Fail-Sync {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    Write-RunStatus -Path $statusPath -Status fail -Message $Message
    Show-StatusToast -Title 'SkillBridge sync FAILED' -Message $Message -Status fail
    exit 1
}

trap [System.Exception] {
    # A terminating error nobody handled: record it and toast instead of
    # letting a hidden window die silently.
    $msg = "sync crashed: $($_.Exception.Message)"
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    Write-RunStatus -Path $statusPath -Status fail -Message $msg
    Show-StatusToast -Title 'SkillBridge sync FAILED' -Message "$msg (see sync-skills.log)" -Status fail
    exit 1
}

if (-not (Test-Path $ConfigPath)) { Fail-Sync "config not found: $ConfigPath" }
$config = Read-ConfigFile $ConfigPath
if ($null -eq $config) { Fail-Sync "could not parse config: $ConfigPath" }

$src = (Expand-EnvPath ([string]$config.source)).Trim()
$log = Join-Path $PSScriptRoot 'sync-skills.log'

if (-not (Test-Path $src)) {
    Fail-Sync "source dir not found: $src`n        Is CC Switch installed? Set the correct path in config.json (source)."
}
# Underscore-prefixed directories are archives (`_archived/...`), never skills.
# Same rule as check-db-sync.py so the two views of the source cannot drift.
$skills = Get-ChildItem -Path $src -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        -not $_.Name.StartsWith('_') -and
        (Test-Path (Join-Path $_.FullName 'SKILL.md'))
    }
if ($skills.Count -eq 0) {
    Fail-Sync "no skills found in source dir: $src (no subfolder contains SKILL.md)"
}

# junction on Windows by default; honor config.link_type = 'symlink' if set
$linkType = if ($config.link_type -eq 'symlink') { 'SymbolicLink' } else { 'Junction' }
if ($linkType -eq 'SymbolicLink') {
    Write-Host ("NOTE: using symlinks (link_type=symlink) — may require " +
        "admin / Developer Mode on Windows.") -ForegroundColor Yellow
}

$targetList = @()
if ($config.targets) {
    foreach ($entry in $config.targets.PSObject.Properties) {
        $spec = Get-TargetSpec $entry.Value -Name $entry.Name
        if ($spec.Promoted) {
            Write-Host ("NOTE: target '$($entry.Name)' is Cursor / .cursor/skills — " +
                "using copy mode (a string path would be a dead junction for Cloud Agents).") -ForegroundColor Yellow
        }
        $targetList += [pscustomobject]@{ Name = $entry.Name; Path = $spec.Path; Mode = $spec.Mode }
    }
}
if (-not [string]::IsNullOrWhiteSpace($CopyInto)) {
    $targetList += [pscustomobject]@{ Name = 'CopyInto'; Path = $CopyInto; Mode = 'copy' }
}

$skillNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($s in $skills) { [void]$skillNames.Add($s.Name) }

$lines   = @()
$created = 0
$updated = 0
$pruned  = 0
$skipped = 0
$failed  = 0

foreach ($t in $targetList) {
    $tool = $t.Name
    $tdir = Resolve-TargetPath $t.Path
    if (-not (Assert-ExpandablePath $tdir "target '$tool'")) {
        continue
    }
    if ($t.Mode -eq 'copy' -and (Test-SameResolvedPath $tdir $src)) {
        Write-Warning "SKIP target '$tool' : copy dest equals source ($tdir)"
        $lines += "SKIP     $tool : copy dest equals source"
        continue
    }
    if (-not (Test-Path $tdir)) {
        New-Item -ItemType Directory -Path $tdir -Force | Out-Null
    }
    $managed = Read-ManagedSkills $tdir
    $markerName = Get-CopyMarkerName

    if ($t.Mode -eq 'copy') {
        # Drop copies / leftover junctions we own whose source skill is gone.
        foreach ($item in @(Get-ChildItem -Path $tdir -Force -ErrorAction SilentlyContinue)) {
            if ($item.Name -eq '.skillbridge-managed.json' -or $item.Name -eq $markerName) { continue }
            if (-not (Test-OurSkillEntry $item $src)) { continue }
            if ($skillNames.Contains($item.Name)) { continue }
            Remove-SkillEntry $item.FullName
            [void]$managed.Remove($item.Name)
            if (-not (Test-Path -LiteralPath $item.FullName)) {
                $pruned++
                $lines += "pruned   $tool : $($item.Name)"
            }
        }
    }

    foreach ($s in $skills) {
        $dest = Join-Path $tdir $s.Name
        $existing = Get-Item -Path $dest -Force -ErrorAction SilentlyContinue
        if ($t.Mode -eq 'copy') {
            $ours = Test-OurSkillEntry $existing $src
            if ($null -ne $existing -and -not $ours) {
                $skipped++
                continue
            }
            if ($null -ne $existing -and $ours -and -not (Test-ReparsePoint $existing)) {
                if ((Get-SkillFingerprint $s.FullName) -eq (Get-SkillFingerprint $existing.FullName)) {
                    $skipped++
                    [void]$managed.Add($s.Name)
                    continue
                }
            }
            try {
                Copy-SkillDirectory -Source $s.FullName -Destination $dest -WriteMarker
                if ($null -ne $existing) {
                    $updated++
                    $lines += "updated  $tool : $($s.Name)"
                } else {
                    $created++
                    $lines += "created  $tool : $($s.Name)"
                }
                [void]$managed.Add($s.Name)
            } catch {
                $failed++
                $lines += "FAILED   $tool : $($s.Name) -> $($_.Exception.Message)"
            }
            continue
        }

        # link mode — skip if anything already exists (including a dangling junction)
        if ($null -ne $existing) {
            $skipped++
            continue
        }
        try {
            # -ErrorAction Stop so real failures reach catch (EAP is 'Continue').
            # A concurrent run may create the link between our check and this
            # call; treat that as "already there" (skip), not as a failure.
            New-Item -ItemType $linkType -Path $dest -Target $s.FullName -ErrorAction Stop | Out-Null
            $created++
            $lines += "created  $tool : $($s.Name)"
        } catch {
            if ($_.Exception.Message -match 'exists') {
                $skipped++
            } else {
                $failed++
                $lines += "FAILED   $tool : $($s.Name) -> $($_.Exception.Message)"
            }
        }
    }

    if ($t.Mode -eq 'copy') {
        Write-ManagedSkills -TargetDir $tdir -Names $managed
    }
}

# Prune dead links — entries left behind when a skill is deleted from the source.
# The loop above only walks skills that still exist, so it can never see them;
# without this pass, deleted skills linger in every target as broken links.
# Copy-mode targets are pruned above (managed copies, not just links).
foreach ($t in $targetList) {
    if ($t.Mode -eq 'copy') { continue }
    $tool = $t.Name
    $tdir = Resolve-TargetPath $t.Path
    if (-not (Test-Path $tdir)) { continue }
    foreach ($item in @(Get-ChildItem -Path $tdir -Force -ErrorAction SilentlyContinue)) {
        # Only links are candidates; a real folder always belongs to the tool.
        # pwsh sometimes leaves LinkType empty on junctions — Attributes is reliable.
        if (-not (Test-ReparsePoint $item)) { continue }
        # A link is not ours just because it is dead. Only a link INTO THE
        # SOURCE is (the same ownership rule every other deletion here uses);
        # a dangling link pointing elsewhere belongs to the user — an
        # unmounted drive, a shortcut into another tool — and must survive.
        if (-not (Test-OurSkillEntry $item $src)) { continue }
        # Test-Path on the link itself does NOT resolve its target for junctions,
        # so check the recorded target path instead. An unreadable target is left
        # alone: keeping a dead link beats deleting a live one.
        $target = [string]$item.Target
        if (-not $target) { continue }
        # A relative target resolves against the link's own directory, not the
        # process CWD — same rule as sync-skills.sh. Testing the raw string
        # would declare a live relative symlink dead whenever CWD differs.
        if (-not [IO.Path]::IsPathRooted($target)) {
            $target = [IO.Path]::GetFullPath(
                (Join-Path (Split-Path -Parent $item.FullName) $target))
        }
        if (Test-Path -LiteralPath $target) { continue }
        # Remove-Item goes through the shell's safe-delete wrapper, which fails
        # closed on a link whose target is already gone (it cannot resolve the
        # path in order to trash it). The raw API unlinks the entry without
        # ever touching the target, which is what we want here.
        Remove-SkillEntry $item.FullName
        if (-not (Test-Path -LiteralPath $item.FullName)) {
            $pruned++
            $lines += "pruned   $tool : $($item.Name)"
        }
    }
}

$summary = @(
    "== done $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    " | skills=$($skills.Count) created=$created updated=$updated pruned=$pruned skipped=$skipped failed=$failed =="
) -join ''
$lines += $summary
Write-Log -Lines $lines -Path $log
Write-Output $summary

# Compare the skills folder with CC Switch's own database (see check-db-sync.py).
# Optional: silently skipped when Python, the script, or the database is absent.
#
# REPORT ONLY. Repairing that drift means deleting rows from CC Switch's
# database, and a row is the only record of a skill's origin (repo, branch,
# readme URL) — a reconstruction cannot bring those fields back. Deciding a row
# should die is the user's call, so this only reports. Repair by hand with
#     python check-db-sync.py --fix        (backs the database up first)
$dbDrift  = ''
$checkDb  = if ($null -ne $config.check_db) { [bool]$config.check_db } else { $false }
if ($checkDb) {
    $pyExe    = Resolve-PythonExe
    $pyScript = Join-Path $PSScriptRoot 'check-db-sync.py'
    $ccDb     = Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db'
    if ($pyExe -and (Test-Path $pyScript) -and (Test-Path $ccDb)) {
        # check-db-sync.py appends its own UTF-8 output to the log. Piping it
        # through PowerShell would re-encode it and garble non-ASCII text.
        & $pyExe $pyScript --source $src --log $log
        if ($LASTEXITCODE -eq 1) {
            $dbDrift = 'cc-switch.db is out of step with the skills folder (details in sync-skills.log; repair by hand with `python check-db-sync.py --fix`)'
            Write-Warning $dbDrift
        } elseif ($LASTEXITCODE -gt 1) {
            $dbDrift = "check-db-sync.py exited $LASTEXITCODE (details in sync-skills.log)"
            Write-Warning $dbDrift
        }
    }
}

# Record the outcome and surface it: the scheduled run is hidden, so the log
# alone leaves a crash (or a failed link) completely invisible. `fail` and
# `warn` both notify; `ok` just refreshes the record.
$runStatus = 'ok'
$runNote   = ''
if ($failed -gt 0) {
    $runStatus = 'fail'
    $runNote   = "$failed skill(s) could not be linked - see sync-skills.log"
} elseif ($dbDrift) {
    $runStatus = 'warn'
    $runNote   = $dbDrift
}
Write-RunStatus -Path $statusPath -Status $runStatus -Message $runNote
if ($runStatus -ne 'ok') {
    $toastTitle = if ($runStatus -eq 'fail') {
        'SkillBridge sync FAILED'
    } else {
        'SkillBridge sync: database out of step'
    }
    Show-StatusToast -Title $toastTitle -Message $runNote -Status $runStatus
}

if ($failed -gt 0) { exit 1 }
