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
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1 -Unregister
param(
    [string]$TaskName   = 'CCSwitch Skills AutoLink',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'sync-skills.ps1'),
    [int]$IntervalMinutes = -1,
    [switch]$Unregister
)
$ErrorActionPreference = 'Stop'

# load the `autolink` block from config.json to fill in defaults
$cfg = $null
$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $cfgPath) {
    try { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json } catch { $cfg = $null }
}
$autolink = if ($cfg -and $cfg.autolink) { $cfg.autolink } else { $null }

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Unregistered task '$TaskName'."
    exit 0
}

if ($null -ne $autolink -and -not $autolink.enabled) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "AutoLink disabled by config (autolink.enabled=false). Not registering."
    exit 0
}

if (-not $PSBoundParameters.ContainsKey('IntervalMinutes')) {
    $IntervalMinutes = if ($autolink -and $autolink.interval_minutes) { [int]$autolink.interval_minutes } else { 0 }
}
if ($IntervalMinutes -lt 0) { $IntervalMinutes = 0 }
$atLogon = if ($null -ne $autolink -and $null -ne $autolink.at_logon) { [bool]$autolink.at_logon } else { $true }

if (-not (Test-Path $ScriptPath)) {
    Write-Host "[ERROR] sync script not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

$argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument

if ($atLogon -and $IntervalMinutes -le 0) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
} elseif ($atLogon) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $rep = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $trigger.Repetition = $rep.Repetition
} elseif ($IntervalMinutes -gt 0) {
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
} else {
    Write-Host "[ERROR] nothing to schedule: at_logon=false and interval_minutes=0." -ForegroundColor Red
    exit 1
}

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

$when = if ($atLogon) { 'at logon' } else { 'at interval only' }
$intervalText = if ($IntervalMinutes -gt 0) { "+ every $IntervalMinutes min" } else { '' }
Write-Host "Registered task '$TaskName' ($when $intervalText)."

Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName, State, @{ n = 'Trigger'; e = { $_.Triggers[0].CimClass.CimClassName } }
