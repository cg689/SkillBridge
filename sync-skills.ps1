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

if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] config not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$config = Read-ConfigFile $ConfigPath
if ($null -eq $config) {
    Write-Host "[ERROR] could not parse config: $ConfigPath" -ForegroundColor Red
    exit 1
}

$src = (Expand-EnvPath ([string]$config.source)).Trim()
$log = Join-Path $PSScriptRoot 'sync-skills.log'

if (-not (Test-Path $src)) {
    Write-Host "[ERROR] source dir not found: $src" -ForegroundColor Red
    Write-Host "        Is CC Switch installed? Set the correct path in config.json (source)." -ForegroundColor Yellow
    exit 1
}
# Underscore-prefixed directories are archives (`_archived/...`), never skills.
# Same rule as check-db-sync.py so the two views of the source cannot drift.
$skills = Get-ChildItem -Path $src -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        -not $_.Name.StartsWith('_') -and
        (Test-Path (Join-Path $_.FullName 'SKILL.md'))
    }
if ($skills.Count -eq 0) {
    Write-Host "[ERROR] no skills found in source dir: $src (no subfolder contains SKILL.md)" -ForegroundColor Red
    exit 1
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
        # Only links are ours to remove; a real folder belongs to the tool.
        # pwsh sometimes leaves LinkType empty on junctions — Attributes is reliable.
        if (-not (Test-ReparsePoint $item)) { continue }
        # Test-Path on the link itself does NOT resolve its target for junctions,
        # so check the recorded target path instead. An unreadable target is left
        # alone: keeping a dead link beats deleting a live one.
        $target = [string]$item.Target
        if (-not $target -or (Test-Path -LiteralPath $target)) { continue }
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

# Keep cc-switch.db in step with the skills folder (see check-db-sync.py).
# Optional: silently skipped when Python, the script, or the database is absent.
$checkDb = if ($null -ne $config.check_db) { [bool]$config.check_db } else { $true }
if ($checkDb) {
    $pyExe    = Resolve-PythonExe
    $pyScript = Join-Path $PSScriptRoot 'check-db-sync.py'
    $ccDb     = Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db'
    if ($pyExe -and (Test-Path $pyScript) -and (Test-Path $ccDb)) {
        # check-db-sync.py appends its own UTF-8 output to the log. Piping it
        # through PowerShell would re-encode it and garble non-ASCII text.
        & $pyExe $pyScript --fix --source $src --log $log
        if ($LASTEXITCODE -gt 1) {
            Write-Warning "check-db-sync.py exited with $LASTEXITCODE"
        }
    }
}

if ($failed -gt 0) { exit 1 }
