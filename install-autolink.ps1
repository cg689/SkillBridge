# install-autolink.ps1 — Register the "CC Switch Skills AutoLink" scheduled task.
#
# Runs sync-skills.ps1 automatically at logon so newly added CC Switch skills are
# linked into every configured target tool. Optionally also repeats every N minutes.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1 -IntervalMinutes 10
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1 -Unregister
param(
    [string]$TaskName        = 'CCSwitch Skills AutoLink',
    [string]$ScriptPath      = (Join-Path $PSScriptRoot 'sync-skills.ps1'),
    [int]   $IntervalMinutes = 0,
    [switch]$Unregister
)
$ErrorActionPreference = 'Stop'

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Unregistered task '$TaskName'."
    exit 0
}

if (-not (Test-Path $ScriptPath)) {
    Write-Host "[ERROR] sync script not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"')

$trigger = New-ScheduledTaskTrigger -AtLogOn
if ($IntervalMinutes -gt 0) {
    $rep = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $trigger.Repetition = $rep.Repetition
}

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

Write-Host "Registered task '$TaskName' (at logon" $(
    if ($IntervalMinutes -gt 0) { "+ every $IntervalMinutes min" } else { '' }
) ")."
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State, @{n='Trigger';e={$_.Triggers[0].CimClass.CimClassName}}
