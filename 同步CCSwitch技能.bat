@echo off
rem ============================================================
rem  SkillBridge.bat - double-click to sync CC Switch skills
rem  into every configured tool (ZCode, TRAE, Cherry Studio, ...)
rem ============================================================
title SkillBridge - CC Switch Skill Sync
setlocal
cd /d "%~dp0"

echo.
echo  [SkillBridge] Syncing CC Switch skills into all tools...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-skills.ps1"
echo.
echo  Done. Restart each tool's session to pick up new skills.
echo.
pause
