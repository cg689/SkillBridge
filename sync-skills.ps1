# sync-skills.ps1 — Mirror CC Switch skills into agent tools via directory junctions.
#
# For every skill in the CC Switch skills dir that is missing in a target tool's
# skills dir, create a directory junction (a "live link") pointing at the source.
# Idempotent: existing entries are never overwritten, so a tool's own skills
# are never clobbered.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1 -ConfigPath .\my-config.json
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)
$ErrorActionPreference = 'Continue'

if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] config not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

function Expand-UserPath {
    param([string]$Path)
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    return $Path.Replace('%USERPROFILE%', $homeDir).Replace('$HOME', $homeDir)
}

$src  = Expand-UserPath $config.source
$log  = Join-Path $PSScriptRoot 'sync-skills.log'

$skills = Get-ChildItem -Path $src -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') }

$lines   = @()
$created = 0
$skipped = 0

foreach ($entry in $config.targets.PSObject.Properties) {
    $tool = $entry.Name
    $tdir = Expand-UserPath ([string]$entry.Value)
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
            New-Item -ItemType Junction -Path $link -Target $s.FullName | Out-Null
            $created++
            $lines += "created  $tool : $($s.Name)"
        } catch {
            $lines += "FAILED   $tool : $($s.Name) -> $($_.Exception.Message)"
        }
    }
}

$summary = "== done $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | skills=$($skills.Count) created=$created skipped=$skipped =="
$lines += $summary
Add-Content -Path $log -Value $lines -Encoding UTF8
Write-Host $summary
