# detect-tools.ps1 — auto-generate config.json for the CURRENT machine.
#
# Detects which supported tools are installed (by checking each tool's config
# directory) and writes a config.json that only includes the ones present.
# This is how you adapt SkillBridge to another computer:
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

# name -> @{ Marker = config dir that proves the tool is installed; Skills = skills dir template }
$candidates = @(
    @{
        Name   = 'ZCode'
        Marker = '%USERPROFILE%\.zcode'
        Skills = '%USERPROFILE%\.zcode\skills'
    }
    @{
        Name   = 'WorkBuddy'
        Marker = '%USERPROFILE%\.workbuddy'
        Skills = '%USERPROFILE%\.workbuddy\skills'
    }
    @{
        Name   = 'WorkBuddy AI'
        Marker = '%USERPROFILE%\.workbuddy-ai'
        Skills = '%USERPROFILE%\.workbuddy-ai\skills'
    }
    @{
        Name   = 'Comate'
        Marker = '%USERPROFILE%\.comate'
        Skills = '%USERPROFILE%\.comate\skills'
    }
    @{
        Name   = 'Hermes Agent'
        Marker = '%HERMES_HOME%'
        Skills = '%HERMES_HOME%\skills'
    }
    @{
        Name   = 'TRAE Work CN'
        Marker = '%USERPROFILE%\.trae-cn'
        Skills = '%USERPROFILE%\.trae-cn\skills'
    }
    @{
        Name   = 'Cherry Studio'
        Marker = '%APPDATA%\CherryStudio'
        Skills = '%APPDATA%\CherryStudio\Data\Skills'
    }
    @{
        Name   = 'CodeBuddy CN'
        Marker = '%USERPROFILE%\.codebuddy'
        Skills = '%USERPROFILE%\.codebuddy\skills'
    }
    @{
        Name   = 'DeepSeek Harness'
        Marker = '%USERPROFILE%\.agents'
        Skills = '%USERPROFILE%\.agents\skills'
    }
    @{
        Name   = 'AutoClaw'
        Marker = '%USERPROFILE%\.openclaw-autoclaw'
        Skills = '%USERPROFILE%\.openclaw-autoclaw\skills'
    }
    @{
        Name   = 'Verdent'
        Marker = '%USERPROFILE%\.verdent'
        Skills = '%USERPROFILE%\.verdent\skills'
    }
    @{
        Name   = 'Qoder CN'
        Marker = '%USERPROFILE%\.qoder-cn'
        Skills = '%USERPROFILE%\.qoder-cn\skills'
    }
    @{
        Name   = 'Doubao'
        Marker = '%USERPROFILE%\DoubaoWork'
        Skills = '%USERPROFILE%\DoubaoWork\skills'
    }
    @{
        Name   = 'MiniMax Code'
        Marker = '%USERPROFILE%\.minimax'
        Skills = '%USERPROFILE%\.minimax\skills'
    }
    @{
        Name   = 'Qwen Office'
        Marker = '%USERPROFILE%\.qwenworkcn'
        Skills = '%USERPROFILE%\.qwenworkcn\skills'
    }
    @{
        Name   = 'Grok Bot'
        Marker = '%USERPROFILE%\.grok'
        Skills = '%USERPROFILE%\.grok\skills'
    }
)

$targets = [ordered]@{}
$found = @()
$missed = @()
foreach ($c in $candidates) {
    $marker = Expand-EnvPath $c.Marker
    if ($All -or (Test-Path $marker)) {
        $targets[$c.Name] = $c.Skills
        $found += $c.Name
    } else {
        $missed += $c.Name
    }
}

# preserve source / autolink from an existing config if present
$existing = $null
if (Test-Path $configPath) {
    try { $existing = Get-Content $configPath -Raw | ConvertFrom-Json } catch { $existing = $null }
}
$autolink = if ($existing -and $existing.autolink) {
    $existing.autolink
} else {
    [ordered]@{ enabled = $true; at_logon = $true; interval_minutes = 0 }
}
$cfgLinkType = if ($existing -and $existing.link_type) { $existing.link_type } else { 'junction' }
$cfgSource   = if ($existing -and $existing.source)     { $existing.source }     else { '%USERPROFILE%\.cc-switch\skills' }

# Emit with a stable key order and 2-space indentation, matching config.example.json.
# (PS5.1 ConvertTo-Json indents nested objects irregularly, so we serialize this
# fixed-shape config by hand.)
function ConvertTo-SkillBridgeConfig {
    param(
        [string]$Comment,
        [string]$LinkType,
        [string]$Source,
        [System.Collections.IDictionary]$Targets,
        $Autolink
    )
    $esc = { param($s) ($s -replace '\\', '\\' -replace '"', '\"') }
    $enabled  = if ($Autolink -and $null -ne $Autolink.enabled)  { [bool]$Autolink.enabled }  else { $true }
    $atLogon  = if ($Autolink -and $null -ne $Autolink.at_logon) { [bool]$Autolink.at_logon } else { $true }
    $interval = if ($Autolink -and $null -ne $Autolink.interval_minutes) { [int]$Autolink.interval_minutes } else { 0 }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('{')
    [void]$sb.AppendLine('  "$comment": "' + (& $esc $Comment) + '",')
    [void]$sb.AppendLine('  "link_type": "' + (& $esc $LinkType) + '",')
    [void]$sb.AppendLine('  "source": "' + (& $esc $Source) + '",')
    [void]$sb.AppendLine('  "targets": {')
    $names = @($Targets.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        $comma = if ($i -lt $names.Count - 1) { ',' } else { '' }
        $line = '    "' + (& $esc $names[$i]) + '": "'
        $line += (& $esc ([string]$Targets[$names[$i]])) + '"' + $comma
        [void]$sb.AppendLine($line)
    }
    [void]$sb.AppendLine('  },')
    [void]$sb.AppendLine('  "autolink": {')
    [void]$sb.AppendLine("    `"enabled`": $(if ($enabled) { 'true' } else { 'false' }),")
    [void]$sb.AppendLine("    `"at_logon`": $(if ($atLogon) { 'true' } else { 'false' }),")
    [void]$sb.AppendLine("    `"interval_minutes`": $interval")
    [void]$sb.AppendLine('  }')
    [void]$sb.AppendLine('}')
    return $sb.ToString()
}

$jsonParams = @{
    Comment  = 'SkillBridge - auto-generated by detect-tools.ps1 for THIS machine.'
    LinkType = $cfgLinkType
    Source   = $cfgSource
    Targets  = $targets
    Autolink = $autolink
}
$json = ConvertTo-SkillBridgeConfig @jsonParams

[System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Detected $($found.Count) / $($candidates.Count) supported tools."
Write-Host "  installed : $($found -join ', ')"
if ($missed.Count -gt 0) { Write-Host "  not found : $($missed -join ', ')" }
Write-Host "config.json written. Now run .\sync-skills.ps1 or double-click 同步CCSwitch技能.bat."
