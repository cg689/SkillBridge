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
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)
$ErrorActionPreference = 'Continue'

Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force

if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] config not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$src = Expand-EnvPath $config.source
$log = Join-Path $PSScriptRoot 'sync-skills.log'

if (-not (Test-Path $src)) {
    Write-Host "[ERROR] source dir not found: $src" -ForegroundColor Red
    Write-Host "        Is CC Switch installed? Set the correct path in config.json (source)." -ForegroundColor Yellow
    exit 1
}
$skills = Get-ChildItem -Path $src -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') }
if ($skills.Count -eq 0) {
    Write-Host "[ERROR] no skills found in source dir: $src (no subfolder contains SKILL.md)" -ForegroundColor Red
    exit 1
}

# junction on Windows by default; honor config.link_type = 'symlink' if set
$linkType = if ($config.link_type -eq 'symlink') { 'SymbolicLink' } else { 'Junction' }
if ($linkType -eq 'SymbolicLink') {
    Write-Host "NOTE: using symlinks (link_type=symlink) — may require admin / Developer Mode on Windows." -ForegroundColor Yellow
}

$lines   = @()
$created = 0
$skipped = 0

foreach ($entry in $config.targets.PSObject.Properties) {
    $tool = $entry.Name
    $tdir = Expand-EnvPath ([string]$entry.Value)
    if (-not (Assert-ExpandablePath $tdir "target '$tool'")) {
        continue
    }
    if (-not (Test-Path $tdir)) {
        New-Item -ItemType Directory -Path $tdir -Force | Out-Null
    }
    foreach ($s in $skills) {
        $link = Join-Path $tdir $s.Name
        # skip if anything already exists there (including a dangling junction)
        $existing = Get-Item -Path $link -Force -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            $skipped++
            continue
        }
        try {
            # -ErrorAction Stop so real failures reach catch (EAP is 'Continue').
            # A concurrent run may create the link between our check and this
            # call; treat that as "already there" (skip), not as a failure.
            New-Item -ItemType $linkType -Path $link -Target $s.FullName -ErrorAction Stop | Out-Null
            $created++
            $lines += "created  $tool : $($s.Name)"
        } catch {
            if ($_.Exception.Message -match 'exists') {
                $skipped++
            } else {
                $lines += "FAILED   $tool : $($s.Name) -> $($_.Exception.Message)"
            }
        }
    }
}

$summary = @(
    "== done $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    " | skills=$($skills.Count) created=$created skipped=$skipped =="
) -join ''
$lines += $summary
Write-Log -Lines $lines -Path $log
Write-Host $summary
