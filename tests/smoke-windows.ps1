# tests/smoke-windows.ps1 — functional smoke test for the Windows (junction) sync path.
#
# Creates a temp source with one fake skill and a temp target, runs sync-skills.ps1
# twice, and asserts: junction created, idempotent on second run. Also runs
# detect-tools.ps1 -All and asserts it produces a valid config.json. Restores the
# repo's sync-skills.log and config.json afterwards so nothing is polluted.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-windows.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$log = Join-Path $root 'sync-skills.log'
$logBackup = if (Test-Path $log) { Get-Content $log -Raw } else { $null }
$repoConfig = Join-Path $root 'config.json'
$cfgBackup = if (Test-Path $repoConfig) { Get-Content $repoConfig -Raw } else { $null }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('sb-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'src\demo-skill') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'tgt') -Force | Out-Null
Set-Content -Path (Join-Path $tmp 'src\demo-skill\SKILL.md') -Value '# demo' -Encoding UTF8

$cfg = @{
    link_type = 'junction'
    source    = (Join-Path $tmp 'src')
    targets   = @{ Smoke = (Join-Path $tmp 'tgt') }
} | ConvertTo-Json -Depth 5
$cfgPath = Join-Path $tmp 'cfg.json'
[System.IO.File]::WriteAllText($cfgPath, $cfg, (New-Object System.Text.UTF8Encoding($false)))

try {
    # run 1: link created
    & (Join-Path $root 'sync-skills.ps1') -ConfigPath $cfgPath | Out-Null
    $link = Get-Item (Join-Path $tmp 'tgt\demo-skill') -Force
    if ($link.LinkType -ne 'Junction') {
        throw "FAIL: junction not created (LinkType=$($link.LinkType))"
    }

    # run 2: idempotent
    $out = & (Join-Path $root 'sync-skills.ps1') -ConfigPath $cfgPath
    if ($out -notmatch 'skipped=1') {
        throw "FAIL: second run not idempotent (expected skipped=1, got: $out)"
    }
    Write-Host 'OK: windows smoke (junction created, idempotent)'

    # detect-tools: produces a valid config.json with at least one target
    & (Join-Path $root 'detect-tools.ps1') -All | Out-Null
    $gen = Get-Content $repoConfig -Raw | ConvertFrom-Json
    if ($null -eq $gen.targets -or $gen.targets.PSObject.Properties.Count -lt 1) {
        throw 'FAIL: detect-tools produced no targets'
    }
    Write-Host 'OK: detect-tools'
} finally {
    # restore repo config.json
    if ($null -ne $cfgBackup) {
        [System.IO.File]::WriteAllText($repoConfig, $cfgBackup, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        Remove-Item $repoConfig -Force -ErrorAction SilentlyContinue
    }
    # restore repo log
    if ($null -ne $logBackup) {
        [System.IO.File]::WriteAllText($log, $logBackup, (New-Object System.Text.UTF8Encoding($true)))
    } else {
        Remove-Item $log -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
