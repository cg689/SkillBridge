# install-autolink.ps1 — Register the "CC Switch Skills AutoLink" scheduled task.
#
# Runs sync-skills.ps1 automatically at logon so newly added CC Switch skills are
# linked into every configured target tool. Optionally also repeats every N minutes.
# Defaults (enabled / at_logon / interval_minutes) come from the `autolink` block
# in config.json; command-line arguments override them.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1 -IntervalMinutes 10
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1 -DryRun   # preview only, no registration
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1 -Unregister
param(
    [string]$TaskName   = 'CCSwitch Skills AutoLink',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'sync-skills.ps1'),
    [int]$IntervalMinutes = -1,
    [switch]$Unregister,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force

# load the `autolink` block from config.json to fill in defaults
$cfgPath = Join-Path $PSScriptRoot 'config.json'
$cfg = Read-ConfigFile $cfgPath
$autolink = if ($cfg -and $cfg.autolink) { $cfg.autolink } else { $null }
$al = Get-AutolinkDefaults $autolink

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Unregistered task '$TaskName'."
    exit 0
}

if (-not $al.enabled) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "AutoLink disabled by config (autolink.enabled=false). Not registering."
    exit 0
}

if (-not $PSBoundParameters.ContainsKey('IntervalMinutes')) {
    $IntervalMinutes = $al.interval_minutes
}
if ($IntervalMinutes -lt 0) { $IntervalMinutes = 0 }
$atLogon = $al.at_logon

if (-not (Test-Path $ScriptPath)) {
    Write-Host "[ERROR] sync script not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

$argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument

if ($atLogon) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    if ($IntervalMinutes -gt 0) {
        $span = New-TimeSpan -Minutes $IntervalMinutes
        $rep = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $span
        $trigger.Repetition = $rep.Repetition
    }
} elseif ($IntervalMinutes -gt 0) {
    $span = New-TimeSpan -Minutes $IntervalMinutes
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $span
} else {
    Write-Host "[ERROR] nothing to schedule: at_logon=false and interval_minutes=0." -ForegroundColor Red
    exit 1
}

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

if ($DryRun) {
    Write-Host "[DRY-RUN] would register scheduled task '$TaskName':"
    Write-Host "  action    : powershell.exe $argument"
    $triggerDesc = if ($atLogon) { 'at logon' } else { 'interval only' }
    if ($IntervalMinutes -gt 0) { $triggerDesc += " + every $IntervalMinutes min" }
    Write-Host "  trigger   : $triggerDesc"
    Write-Host "  principal : $env:USERDOMAIN\$env:USERNAME (Interactive, Limited)"
    exit 0
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

$when = if ($atLogon) { 'at logon' } else { 'at interval only' }
$intervalText = if ($IntervalMinutes -gt 0) { "+ every $IntervalMinutes min" } else { '' }
Write-Host "Registered task '$TaskName' ($when $intervalText)."

Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName, State, @{ n = 'Trigger'; e = { $_.Triggers[0].CimClass.CimClassName } }
