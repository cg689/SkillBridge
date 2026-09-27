@echo off
rem ============================================================
rem  启动WebUI.bat - start the SkillBridge dashboard in your browser
rem  (localhost only; nothing is published to the network)
rem
rem  usage:  启动WebUI.bat [port]     e.g.  启动WebUI.bat 9001
rem ============================================================
title SkillBridge Web UI
setlocal
cd /d "%~dp0"

if "%~1"=="" (
  set PORT=8765
) else (
  set PORT=%~1
)

echo.
echo  [SkillBridge] starting the web UI on port %PORT% ...
echo  (Ctrl+C, or the stop button in the page, shuts it down)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0web-ui.ps1" -Port %PORT%
echo.
pause
