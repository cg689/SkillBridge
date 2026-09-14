# tests/smoke-windows.ps1 — functional smoke test for the Windows (junction) sync path.
#
# Creates a temp source with one fake skill and a temp target, runs sync-skills.ps1
# twice, and asserts: junction created, idempotent on second run, underscore
# archives skipped, dead junctions pruned, tool-owned dirs left alone. Also runs
# detect-tools.ps1 -All and asserts it produces a valid config.json that includes
# Cursor. Restores the repo's sync-skills.log and config.json afterwards.
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
New-Item -ItemType Directory -Path (Join-Path $tmp 'src\_archived') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'tgt\own-skill') -Force | Out-Null
Set-Content -Path (Join-Path $tmp 'src\demo-skill\SKILL.md') -Value '# demo' -Encoding UTF8
Set-Content -Path (Join-Path $tmp 'src\_archived\SKILL.md') -Value '# archive' -Encoding UTF8

$deadTarget = Join-Path $tmp 'will-vanish'
New-Item -ItemType Directory -Path $deadTarget -Force | Out-Null
New-Item -ItemType Junction -Path (Join-Path $tmp 'tgt\dead-skill') -Target $deadTarget | Out-Null
Remove-Item -LiteralPath $deadTarget -Recurse -Force

# Hand-written JSON: ConvertTo-Json can mangle nested hashtables and hide mode=copy.
$esc = { param($s) ($s -replace '\\', '\\' -replace '"', '\"') }
$cfgJson = @(
    '{',
    '  "link_type": "junction",',
    '  "source": "' + (& $esc (Join-Path $tmp 'src')) + '",',
    '  "targets": {',
    '    "Smoke": "' + (& $esc (Join-Path $tmp 'tgt')) + '",',
    '    "SmokeCopy": { "path": "' + (& $esc (Join-Path $tmp 'tgt-copy')) + '", "mode": "copy" },',
    '    "BadTool": "%NOPE_UNSET_VAR%\\skills"',
    '  },',
    '  "check_db": false',
    '}'
) -join "`n"
$cfgPath = Join-Path $tmp 'cfg.json'
[System.IO.File]::WriteAllText($cfgPath, $cfgJson, (New-Object System.Text.UTF8Encoding($false)))

try {
    # start from an empty log so this run's lines are easy to grep; finally restores it
    [System.IO.File]::WriteAllText($log, '', (New-Object System.Text.UTF8Encoding($false)))

    # run 1: link created; unresolved-%VAR% target skipped (not counted, no literal dir)
    $out1 = & (Join-Path $root 'sync-skills.ps1') -ConfigPath $cfgPath
    if ($out1 -notmatch 'created=2') {
        throw "FAIL: first run expected created=2 (link+copy), got: $out1"
    }
    if ($out1 -notmatch 'pruned=1') {
        throw "FAIL: first run expected pruned=1, got: $out1"
    }
    if ($out1 -notmatch 'skills=1') {
        throw "FAIL: first run expected skills=1 (archive skipped), got: $out1"
    }
    $link = Get-Item (Join-Path $tmp 'tgt\demo-skill') -Force
    if ($link.LinkType -ne 'Junction') {
        throw "FAIL: junction not created (LinkType=$($link.LinkType))"
    }
    if (Test-Path (Join-Path $tmp 'tgt\_archived')) {
        throw 'FAIL: underscore-prefixed archive was linked'
    }
    if (Test-Path (Join-Path $tmp 'tgt\dead-skill')) {
        throw 'FAIL: dead junction was not pruned'
    }
    if (-not (Test-Path (Join-Path $tmp 'tgt\own-skill'))) {
        throw "FAIL: tool's own real directory was removed"
    }
    $copied = Get-Item (Join-Path $tmp 'tgt-copy\demo-skill') -Force
    if ($copied.LinkType -or ($copied.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "FAIL: copy-mode dest must be a real directory (LinkType=$($copied.LinkType) Attributes=$($copied.Attributes))"
    }
    if (-not (Test-Path (Join-Path $tmp 'tgt-copy\demo-skill\SKILL.md'))) {
        throw 'FAIL: copy-mode dest missing SKILL.md'
    }
    $managed = Get-Content (Join-Path $tmp 'tgt-copy\.skillbridge-managed.json') -Raw
    if ($managed -notmatch 'demo-skill') {
        throw "FAIL: managed list missing demo-skill: $managed"
    }
    $logText = Get-Content $log -Raw
    if ($logText -notmatch 'created  Smoke : demo-skill') {
        throw "FAIL: log did not record tool name 'Smoke': $logText"
    }
    if ($logText -notmatch 'pruned   Smoke : dead-skill') {
        throw "FAIL: log did not record prune of dead-skill: $logText"
    }

    # run 2: idempotent
    $out2 = & (Join-Path $root 'sync-skills.ps1') -ConfigPath $cfgPath
    if ($out2 -notmatch 'skipped=2') {
        throw "FAIL: second run not idempotent (expected skipped=2, got: $out2)"
    }
    if ($out2 -notmatch 'pruned=0') {
        throw "FAIL: second run expected pruned=0, got: $out2"
    }
    Set-Content -Path (Join-Path $tmp 'src\demo-skill\SKILL.md') -Value '# demo-v2' -Encoding UTF8
    $copyBefore = Get-Content (Join-Path $tmp 'tgt-copy\demo-skill\SKILL.md') -Raw
    if ($copyBefore -match 'demo-v2') {
        throw 'FAIL: copy dest changed when source was edited — dest is not an independent copy'
    }
    $out3 = & (Join-Path $root 'sync-skills.ps1') -ConfigPath $cfgPath
    if ($out3 -notmatch 'updated=1') {
        throw "FAIL: copy target should refresh after SKILL.md change, got: $out3"
    }
    $copiedText = Get-Content (Join-Path $tmp 'tgt-copy\demo-skill\SKILL.md') -Raw
    if ($copiedText -notmatch 'demo-v2') {
        throw 'FAIL: copied SKILL.md was not refreshed'
    }

    $copyInto = Join-Path $tmp 'proj\.cursor\skills'
    $out4 = & (Join-Path $root 'sync-skills.ps1') -ConfigPath $cfgPath -CopyInto $copyInto
    if (-not (Test-Path (Join-Path $copyInto 'demo-skill\SKILL.md'))) {
        throw "FAIL: -CopyInto did not materialize a real skill directory (got: $out4)"
    }
    $copyIntoItem = Get-Item (Join-Path $copyInto 'demo-skill') -Force
    if ($copyIntoItem.LinkType) {
        throw 'FAIL: -CopyInto created a link instead of a real directory'
    }

    Write-Host 'OK: windows smoke (junction+copy, idempotent, archive skipped, dead link pruned, -CopyInto)'

    # detect-tools: produces a valid config.json that includes Cursor
    & (Join-Path $root 'detect-tools.ps1') -All | Out-Null
    $gen = Get-Content $repoConfig -Raw | ConvertFrom-Json
    if ($null -eq $gen.targets -or $gen.targets.PSObject.Properties.Count -lt 1) {
        throw 'FAIL: detect-tools produced no targets'
    }
    if (-not $gen.targets.Cursor) {
        throw 'FAIL: detect-tools -All did not include Cursor'
    }
    if ($gen.targets.Cursor.mode -ne 'copy') {
        throw "FAIL: detect-tools Cursor must be copy mode, got: $($gen.targets.Cursor)"
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
