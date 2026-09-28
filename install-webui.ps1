# install-webui.ps1 - Register the "SkillBridge Web UI" scheduled task.
#
# Starts web-ui.ps1 (the loopback dashboard) at logon, in a hidden window and
# without opening a browser, so http://localhost:<port>/ is simply there after
# every sign-in.
#
# This is NOT the sync autolink. Nothing here ever runs sync-skills.ps1 on a
# schedule: the "CCSwitch Skills AutoLink" task stays unregistered and
# autolink.enabled stays false - syncing remains manual only. This task only
# keeps the dashboard (the page you drive a manual sync from) up.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-webui.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-webui.ps1 -Port 9001
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-webui.ps1 -DryRun   # preview only, changes NOTHING
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-webui.ps1 -Unregister
#
# -DryRun never registers, never unregisters, never deletes and never starts
# anything - not even when combined with -Unregister.
param(
    [string]$TaskName   = 'SkillBridge Web UI',
    [int]$Port          = 8765,
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'web-ui.ps1'),
    [switch]$Unregister,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "[ERROR] dashboard script not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

if ($Unregister) {
    # -DryRun wins over -Unregister, same promise as install-autolink.ps1: the
    # flag means "change nothing", and an explicit -Unregister beside it reads
    # as "show me what that would do".
    if ($DryRun) {
        Write-Host "[DRY-RUN] would unregister task '$TaskName' (nothing changed)."
        exit 0
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Unregistered task '$TaskName'."
    exit 0
}

$argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Port ' + $Port + ' -NoBrowser'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
# At logon for THIS user, not at boot: the dashboard reads a per-machine
# config.json and writes logs next to it, and a pre-logon SYSTEM instance
# would create those files owned by SYSTEM.
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
# No execution time limit: the dashboard is meant to stay up for the whole
# session. The default 72h cut-off would silently kill it mid-week.
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

if ($DryRun) {
    Write-Host "[DRY-RUN] would register scheduled task '$TaskName':"
    Write-Host "  action    : powershell.exe $argument"
    Write-Host "  trigger   : at logon ($env:USERDOMAIN\$env:USERNAME)"
    Write-Host "  principal : $env:USERDOMAIN\$env:USERNAME (Interactive, Limited)"
    exit 0
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered task '$TaskName' (at logon, hidden, no browser)."

Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName, State, @{ n = 'Trigger'; e = { $_.Triggers[0].CimClass.CimClassName } }
