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
# Byte-level backups: Get-Content decodes as ANSI under 5.1, and writing the
# decoded text back would bake mojibake into files that hold UTF-8 (the log
# gets Chinese lines from check-db-sync.py).
$logBackup = if (Test-Path $log) { [IO.File]::ReadAllBytes($log) } else { $null }
$repoConfig = Join-Path $root 'config.json'
$cfgBackup = if (Test-Path $repoConfig) { [IO.File]::ReadAllBytes($repoConfig) } else { $null }

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

# A live symlink with a RELATIVE target must survive pruning: it resolves
# against the link's own directory, not the process CWD. mklink stores the
# target exactly as given; skipped when the host lacks symlink privilege.
$relDir = Join-Path $tmp 'rel-target'
New-Item -ItemType Directory -Path $relDir -Force | Out-Null
$relLink = Join-Path $tmp 'tgt\rel-link'
cmd /c mklink /D "$relLink" "..\rel-target" | Out-Null
$relMade = ($LASTEXITCODE -eq 0)

$cfg = @{
    link_type = 'junction'
    source    = (Join-Path $tmp 'src')
    targets   = @{
        Smoke     = (Join-Path $tmp 'tgt')
        SmokeCopy = @{
            path = (Join-Path $tmp 'tgt-copy')
            mode = 'copy'
        }
        SelfCopy  = @{
            path = (Join-Path $tmp 'src')
            mode = 'copy'
        }
        BadTool   = '%NOPE_UNSET_VAR%\skills'
    }
    # The DB check compares `source` against the real cc-switch.db. Off here, or
    # a throwaway source would look like mass drift and get "repaired" into it.
    check_db  = $false
} | ConvertTo-Json -Depth 8
$cfgPath = Join-Path $tmp 'cfg.json'
[System.IO.File]::WriteAllText($cfgPath, $cfg, (New-Object System.Text.UTF8Encoding($false)))

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
    if ($relMade) {
        $rel = Get-Item (Join-Path $tmp 'tgt\rel-link') -Force
        if (-not ($rel.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'FAIL: live relative-target symlink was pruned'
        }
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
    if (-not (Test-Path (Join-Path $tmp 'tgt-copy\demo-skill\.skillbridge-copy'))) {
        throw 'FAIL: copy-mode dest is missing .skillbridge-copy marker'
    }
    if (Test-Path (Join-Path $tmp 'src\demo-skill\.skillbridge-copy')) {
        throw 'FAIL: copy dest==source wrote a marker into the source skill'
    }
    if (-not (Test-Path (Join-Path $tmp 'src\demo-skill\SKILL.md'))) {
        throw 'FAIL: copy dest==source removed the source skill'
    }
    New-Item -ItemType Directory -Path (Join-Path $tmp 'tgt-copy\own-skill') -Force | Out-Null
    Set-Content -Path (Join-Path $tmp 'tgt-copy\own-skill\SKILL.md') -Value '# mine' -Encoding UTF8
    $pollutedJson = '{ "skills": ["demo-skill", "own-skill"] }'
    [System.IO.File]::WriteAllText(
        (Join-Path $tmp 'tgt-copy\.skillbridge-managed.json'),
        $pollutedJson,
        (New-Object System.Text.UTF8Encoding($false)))
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
    if (-not (Test-Path (Join-Path $tmp 'tgt-copy\own-skill\SKILL.md'))) {
        throw 'FAIL: polluted managed list deleted a tool-owned own-skill'
    }
    if (Test-Path (Join-Path $tmp 'tgt-copy\own-skill\.skillbridge-copy')) {
        throw 'FAIL: polluted managed list treated own-skill as ours'
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

    New-Item -ItemType Directory -Path (Join-Path $tmp 'src\demo-skill\scripts') -Force | Out-Null
    Set-Content -Path (Join-Path $tmp 'src\demo-skill\scripts\run.sh') -Value 'echo hi' -Encoding UTF8
    Set-Content -Path (Join-Path $tmp 'src\demo-skill\.hidden-note') -Value 'hidden' -Encoding UTF8
    $outScripts = & (Join-Path $root 'sync-skills.ps1') -ConfigPath $cfgPath
    if ($outScripts -notmatch 'updated=1') {
        throw "FAIL: copy target should refresh after scripts/ change, got: $outScripts"
    }
    if (-not (Test-Path (Join-Path $tmp 'tgt-copy\demo-skill\scripts\run.sh'))) {
        throw 'FAIL: scripts/ was not copied'
    }
    if (-not (Test-Path (Join-Path $tmp 'tgt-copy\demo-skill\.hidden-note'))) {
        throw 'FAIL: hidden file inside skill was not copied'
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
    if (-not (Test-Path (Join-Path $copyInto 'demo-skill\.skillbridge-copy'))) {
        throw 'FAIL: -CopyInto dest is missing .skillbridge-copy marker'
    }

    $legacy = Join-Path $tmp 'legacy-cursor'
    New-Item -ItemType Directory -Path $legacy -Force | Out-Null
    $legacyCfg = @{
        link_type = 'junction'
        source    = (Join-Path $tmp 'src')
        targets   = @{
            Cursor = $legacy
        }
        check_db  = $false
    } | ConvertTo-Json -Depth 8
    $legacyCfgPath = Join-Path $tmp 'cfg-legacy.json'
    [System.IO.File]::WriteAllText($legacyCfgPath, $legacyCfg, (New-Object System.Text.UTF8Encoding($false)))
    $legacyOut = & (Join-Path $root 'sync-skills.ps1') -ConfigPath $legacyCfgPath
    $legacyItem = Get-Item (Join-Path $legacy 'demo-skill') -Force
    if ($legacyItem.LinkType -or ($legacyItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "FAIL: legacy Cursor string target must copy, not link (got: $legacyOut)"
    }
    if (-not (Test-Path (Join-Path $legacy 'demo-skill\.skillbridge-copy'))) {
        throw 'FAIL: legacy Cursor copy is missing .skillbridge-copy marker'
    }

    # Ownership needs the path SEPARATOR: a junction into a sibling of the
    # source (src-backup) shares the source's string prefix but is not ours.
    $backupSkill = Join-Path $tmp 'src-backup\demo-skill'
    New-Item -ItemType Directory -Path $backupSkill -Force | Out-Null
    Set-Content -Path (Join-Path $backupSkill 'SKILL.md') -Value '# backup' -Encoding UTF8
    $ownTgt = Join-Path $tmp 'own-tgt'
    New-Item -ItemType Directory -Path $ownTgt -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $ownTgt 'demo-skill') -Target $backupSkill | Out-Null
    $ownCfg = @{
        link_type = 'junction'
        source    = (Join-Path $tmp 'src')
        targets   = @{ Own = $ownTgt }
        check_db  = $false
    } | ConvertTo-Json -Depth 8
    $ownCfgPath = Join-Path $tmp 'cfg-own.json'
    [System.IO.File]::WriteAllText($ownCfgPath, $ownCfg, (New-Object System.Text.UTF8Encoding($false)))
    & (Join-Path $root 'sync-skills.ps1') -ConfigPath $ownCfgPath | Out-Null
    if (-not (Get-Item (Join-Path $ownTgt 'demo-skill') -Force).LinkType) {
        throw 'FAIL: junction into a source-sibling folder was treated as ours and overwritten'
    }
    if ((Get-Content (Join-Path $ownTgt 'demo-skill\SKILL.md') -Raw) -notmatch 'backup') {
        throw 'FAIL: junction into a source-sibling no longer points at the backup copy'
    }

    Write-Host 'OK: windows smoke (junction+copy, marker ownership, relative-target symlink kept, sibling-prefix not ours, scripts refresh, dest!=src, Cursor upgrade, -CopyInto)'

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
    $genText = Get-Content $repoConfig -Raw
    $injected = $false
    $rewritten = foreach ($line in ($genText -split "`n")) {
        if (-not $injected -and $line -match '"targets"\s*:') {
            $line
            '    "MyCustom": "/tmp/skillbridge-custom-skills",'
            $injected = $true
        } else {
            $line
        }
    }
    [System.IO.File]::WriteAllText($repoConfig, ($rewritten -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    & (Join-Path $root 'detect-tools.ps1') -All | Out-Null
    $gen2 = Get-Content $repoConfig -Raw | ConvertFrom-Json
    if ($gen2.targets.MyCustom -ne '/tmp/skillbridge-custom-skills') {
        throw "FAIL: detect-tools dropped extra target MyCustom, got: $($gen2.targets | ConvertTo-Json -Compress)"
    }
    Write-Host 'OK: detect-tools'
} finally {
    # restore repo config.json / log, byte-identical
    if ($null -ne $cfgBackup) {
        [System.IO.File]::WriteAllBytes($repoConfig, $cfgBackup)
    } else {
        Remove-Item $repoConfig -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $logBackup) {
        [System.IO.File]::WriteAllBytes($log, $logBackup)
    } else {
        Remove-Item $log -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
