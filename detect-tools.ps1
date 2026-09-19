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
foreach ($c in $candidates) {
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
$existing = Read-ConfigFile $configPath
$keptExtra = @()
if ($existing -and $existing.targets) {
    $catalogNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $candidates) { [void]$catalogNames.Add($c.Name) }
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
$cfgCheckDb = if ($existing -and $null -ne $existing.check_db) { [bool]$existing.check_db } else { $true }

# Emit with a stable key order and 2-space indentation, matching config.example.json.
# (PS5.1 ConvertTo-Json indents nested objects irregularly, so we serialize this
# fixed-shape config by hand.)
function ConvertTo-SkillBridgeConfig {
    param(
        [string]$Comment,
        [string]$LinkType,
        [string]$Source,
        [System.Collections.IDictionary]$Targets,
        $Autolink,
        [bool]$CheckDb = $true
    )
    $esc = { param($s) ([string]$s).Replace('\', '\\').Replace('"', '\"') }
    $d = Get-AutolinkDefaults $Autolink
    $enabled  = $d.enabled
    $atLogon  = $d.at_logon
    $interval = $d.interval_minutes

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('{')
    [void]$sb.AppendLine('  "$comment": "' + (& $esc $Comment) + '",')
    [void]$sb.AppendLine('  "link_type": "' + (& $esc $LinkType) + '",')
    [void]$sb.AppendLine('  "source": "' + (& $esc $Source) + '",')
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
    Comment  = 'SkillBridge - auto-generated by detect-tools.ps1 for THIS machine.'
    LinkType = $cfgLinkType
    Source   = $cfgSource
    Targets  = $targets
    Autolink = $autolink
    CheckDb  = $cfgCheckDb
}
$json = ConvertTo-SkillBridgeConfig @jsonParams

[System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Detected $($found.Count) / $($candidates.Count) supported tools."
Write-Host "  installed : $($found -join ', ')"
if ($missed.Count -gt 0) { Write-Host "  not found : $($missed -join ', ')" }
if ($keptExtra.Count -gt 0) { Write-Host "  kept extra : $($keptExtra -join ', ')" }
Write-Host "config.json written. Now run .\sync-skills.ps1 or double-click 同步CCSwitch技能.bat."
