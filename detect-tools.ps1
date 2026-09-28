# detect-tools.ps1 — auto-generate config.json for the CURRENT machine.
#
# Detects which supported tools are installed (by checking each tool's marker
# directory from supported-tools.json) and writes a config.json that only
# includes the ones present. This is how you adapt SkillBridge to another
# computer:
#   clone -> set HERMES_HOME if you use Hermes Agent -> run this -> double-click 同步CCSwitch技能.bat
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\detect-tools.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\detect-tools.ps1 -All   # include all tools regardless
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\detect-tools.ps1 -ConfigPath D:\somewhere\config.json
#
# This REWRITES config.json from the catalog: a target whose marker directory is
# gone is dropped. When the config must only gain tools, use
# Merge-SkillBridgeToolTargets (that is what the dashboard's scan button calls).
#
# Tools listed in the config's `exclude` array are never written to `targets`,
# even with -All — that is how a deliberately removed target stays removed.
param(
    [switch]$All,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force
$catalogPath = Join-Path $PSScriptRoot 'supported-tools.json'

# Read the current config FIRST: `exclude` and `$comment` must be known before we
# decide what to add, and before the writer runs.
$existing = Read-ConfigFile $ConfigPath

# `exclude` is the user's explicit opt-out. A tool listed here is never written to
# `targets`, even when its marker directory exists and even with -All. Without it,
# re-running detect-tools silently resurrected a target that was removed on purpose
# (the marker dir of an uninstalled-but-lingering tool stays on disk forever).
$excludeList = @()
if ($existing -and $existing.exclude) {
    foreach ($n in @($existing.exclude)) { if ($n) { $excludeList += [string]$n } }
}

$scan = Find-InstalledAgentTools -CatalogPath $catalogPath -Exclude $excludeList -All:$All
if (-not $scan.ok) {
    Write-Host "[ERROR] $($scan.error)" -ForegroundColor Red
    exit 1
}
$found = @($scan.installed | ForEach-Object { $_.Name })
$missed = @($scan.not_installed | ForEach-Object { $_.Name })
# Report and rewrite in catalog order so the file stays stable between runs, and
# a typo in `exclude` does not survive forever.
$excludedEffective = @($scan.excluded | ForEach-Object { $_.Name })
$excludedUnknown = @($scan.unknown_exclude)

$targets = [ordered]@{}
foreach ($t in $scan.installed) {
    if ($t.Mode) {
        $targets[$t.Name] = @{ path = $t.Skills; mode = $t.Mode }
    } else {
        $targets[$t.Name] = $t.Skills
    }
}

$catalogNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($t in $scan.tools) { [void]$catalogNames.Add($t.Name) }

# Keep extra targets the user added (names that are not in the catalog).
# Re-running detect-tools must not wipe a custom tool.
$keptExtra = @()
if ($existing -and $existing.targets) {
    foreach ($p in $existing.targets.PSObject.Properties) {
        # An empty `targets` block can read back as one property with no name;
        # an OrderedDictionary would refuse that key.
        if ([string]::IsNullOrEmpty([string]$p.Name)) { continue }
        if ($catalogNames.Contains($p.Name)) { continue }
        $val = $p.Value
        if ($null -eq $val) { continue }
        if ($val -is [string]) {
            $targets[$p.Name] = [string]$val
        } elseif ($null -ne $val.mode) {
            $tPath = if ($null -ne $val.path) { [string]$val.path } else { [string]$val.skills }
            $targets[$p.Name] = @{ path = $tPath; mode = [string]$val.mode }
        } else {
            $tPath = if ($null -ne $val.path) { [string]$val.path } else { [string]$val }
            $targets[$p.Name] = [string]$tPath
        }
        $keptExtra += $p.Name
    }
}

# preserve source / autolink from an existing config if present
$autolink = Get-AutolinkDefaults $existing.autolink
$cfgLinkType = if ($existing -and $existing.link_type) { $existing.link_type } else { 'junction' }
$cfgSource = if ($existing -and $existing.source) {
    $existing.source
} else {
    '%USERPROFILE%\.cc-switch\skills'
}
# Default OFF: the check only reports, but it is an extra python invocation and
# its finding ("database has rows the folder doesn't") is only meaningful to
# someone who is going to act on it. Existing value is preserved.
$cfgCheckDb = if ($existing -and $null -ne $existing.check_db) { [bool]$existing.check_db } else { $false }
# Keep a hand-edited $comment: it is where machine-specific migration notes live
# ("source moved to the physical skills dir", "these targets were removed on
# purpose"). Regenerating the config must not erase that.
$cfgComment = if ($existing -and $existing.'$comment') {
    [string]$existing.'$comment'
} else {
    'SkillBridge - auto-generated by detect-tools.ps1 for THIS machine.'
}

# Emit with a stable key order and 2-space indentation, matching config.example.json.
# The serializer lives in common.psm1 so this script and the additive path the
# dashboard uses (Merge-SkillBridgeToolTargets) cannot drift into two formats.
$jsonParams = @{
    Comment  = $cfgComment
    LinkType = $cfgLinkType
    Source   = $cfgSource
    Exclude  = $excludedEffective
    Targets  = $targets
    Autolink = $autolink
    CheckDb  = $cfgCheckDb
}
$json = ConvertTo-SkillBridgeConfig @jsonParams

[System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Detected $($found.Count) / $($scan.tools.Count) supported tools."
Write-Host "  installed : $($found -join ', ')"
if ($missed.Count -gt 0) { Write-Host "  not found : $($missed -join ', ')" }
if ($excludedEffective.Count -gt 0) {
    Write-Host "  excluded  : $($excludedEffective -join ', ')  (kept out by config `exclude`)"
}
if ($excludedUnknown.Count -gt 0) {
    Write-Warning ("config `exclude` names not in supported-tools.json (dropped): " +
        ($excludedUnknown -join ', '))
}
if ($keptExtra.Count -gt 0) { Write-Host "  kept extra : $($keptExtra -join ', ')" }

# The scheduled sync runs hidden, so its failures are invisible. Read the record
# it leaves behind; a `fail` here usually means the autolink task is broken.
$lastRun = Read-RunStatus (Get-RunStatusPath (Join-Path $PSScriptRoot 'sync-skills.log'))
if ($lastRun) {
    $lastNote = if ($lastRun.message) { " - $($lastRun.message)" } else { '' }
    switch ($lastRun.status) {
        'fail' { Write-Warning "last sync run FAILED at $($lastRun.at)$lastNote" }
        'warn' { Write-Warning "last sync run finished with a warning at $($lastRun.at)$lastNote" }
        default { Write-Host "  last sync : ok at $($lastRun.at)" }
    }
}

Write-Host "config.json written. Now run .\sync-skills.ps1 or double-click 同步CCSwitch技能.bat."
