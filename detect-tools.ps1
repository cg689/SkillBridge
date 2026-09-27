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
#
# Tools listed in the config's `exclude` array are never written to `targets`,
# even with -All — that is how a deliberately removed target stays removed.
param(
    [switch]$All
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force
$configPath = Join-Path $PSScriptRoot 'config.json'
$catalogPath = Join-Path $PSScriptRoot 'supported-tools.json'

# Single source of truth: supported-tools.json (shared with detect-tools.sh).
$catalog = Read-ConfigFile $catalogPath
if ($null -eq $catalog -or $null -eq $catalog.tools -or $catalog.tools.Count -lt 1) {
    Write-Host "[ERROR] catalog missing or empty: $catalogPath" -ForegroundColor Red
    exit 1
}
$candidates = @(
    foreach ($t in $catalog.tools) {
        @{
            Name   = [string]$t.name
            Marker = [string]$t.marker
            Skills = [string]$t.skills
            Mode   = if ($t.mode) { [string]$t.mode } else { '' }
        }
    }
)

$targets = [ordered]@{}
$found = @()
$missed = @()

# Read the current config FIRST: `exclude` and `$comment` must be known before we
# decide what to add, and before the writer runs.
$existing = Read-ConfigFile $configPath

# `exclude` is the user's explicit opt-out. A tool listed here is never written to
# `targets`, even when its marker directory exists and even with -All. Without it,
# re-running detect-tools silently resurrected a target that was removed on purpose
# (the marker dir of an uninstalled-but-lingering tool stays on disk forever).
$excludedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($existing -and $existing.exclude) {
    foreach ($n in @($existing.exclude)) {
        if ($n) { [void]$excludedSet.Add([string]$n) }
    }
}
$catalogNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($c in $candidates) { [void]$catalogNames.Add($c.Name) }

$excludedUnknown = @()
foreach ($n in $excludedSet) {
    if (-not $catalogNames.Contains($n)) { $excludedUnknown += $n }
}
# Report and rewrite in catalog order so the file stays stable between runs, and
# a typo in `exclude` does not survive forever.
$excludedEffective = @($candidates | Where-Object { $excludedSet.Contains($_.Name) } | ForEach-Object { $_.Name })

foreach ($c in $candidates) {
    if ($excludedSet.Contains($c.Name)) { continue }
    $marker = Expand-EnvPath $c.Marker
    if ($All -or (Test-Path $marker)) {
        if ($c.Mode) {
            $targets[$c.Name] = @{ path = $c.Skills; mode = $c.Mode }
        } else {
            $targets[$c.Name] = $c.Skills
        }
        $found += $c.Name
    } else {
        $missed += $c.Name
    }
}

# Keep extra targets the user added (names that are not in the catalog).
# Re-running detect-tools must not wipe a custom tool.
$keptExtra = @()
if ($existing -and $existing.targets) {
    foreach ($p in $existing.targets.PSObject.Properties) {
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
# (PS5.1 ConvertTo-Json indents nested objects irregularly, so we serialize this
# fixed-shape config by hand.)
function ConvertTo-SkillBridgeConfig {
    param(
        [string]$Comment,
        [string]$LinkType,
        [string]$Source,
        # Untyped on purpose: [string[]] turns an empty @() into $null on some
        # call paths, and this value is only ever joined back into JSON.
        $Exclude,
        [System.Collections.IDictionary]$Targets,
        $Autolink,
        [bool]$CheckDb = $false
    )
    $esc = { param($s) ([string]$s).Replace('\', '\\').Replace('"', '\"') }
    $d = Get-AutolinkDefaults $Autolink
    $enabled  = $d.enabled
    $atLogon  = $d.at_logon
    $interval = $d.interval_minutes

    $excludeItems = @(@($Exclude) | Where-Object { $_ } | ForEach-Object { '"' + (& $esc $_) + '"' })
    $excludeJson = '[' + ($excludeItems -join ', ') + ']'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('{')
    [void]$sb.AppendLine('  "$comment": "' + (& $esc $Comment) + '",')
    [void]$sb.AppendLine('  "link_type": "' + (& $esc $LinkType) + '",')
    [void]$sb.AppendLine('  "source": "' + (& $esc $Source) + '",')
    [void]$sb.AppendLine('  "exclude": ' + $excludeJson + ',')
    [void]$sb.AppendLine('  "targets": {')
    $names = @($Targets.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        $comma = if ($i -lt $names.Count - 1) { ',' } else { '' }
        $val = $Targets[$names[$i]]
        if ($val -is [hashtable] -or ($null -ne $val -and $null -ne $val.mode)) {
            $tPath = if ($val.path) { [string]$val.path } else { [string]$val.skills }
            $tMode = [string]$val.mode
            $line = '    "' + (& $esc $names[$i]) + '": { "path": "'
            $line += (& $esc $tPath) + '", "mode": "' + (& $esc $tMode) + '" }' + $comma
        } else {
            $line = '    "' + (& $esc $names[$i]) + '": "'
            $line += (& $esc ([string]$val)) + '"' + $comma
        }
        [void]$sb.AppendLine($line)
    }
    [void]$sb.AppendLine('  },')
    [void]$sb.AppendLine('  "autolink": {')
    [void]$sb.AppendLine("    `"enabled`": $(if ($enabled) { 'true' } else { 'false' }),")
    [void]$sb.AppendLine("    `"at_logon`": $(if ($atLogon) { 'true' } else { 'false' }),")
    [void]$sb.AppendLine("    `"interval_minutes`": $interval")
    [void]$sb.AppendLine('  },')
    [void]$sb.AppendLine("  `"check_db`": $(if ($CheckDb) { 'true' } else { 'false' })")
    [void]$sb.AppendLine('}')
    return $sb.ToString()
}

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

[System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Detected $($found.Count) / $($candidates.Count) supported tools."
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
