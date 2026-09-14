@echo off
rem ============================================================
rem  同步到仓库给云端用.bat
rem  Materialize CC Switch skills into a repo's .cursor\skills so
rem  Cloud Agents (cursor.com / Grok Bot) can read them from git.
rem
rem  Usage:
rem    1. Double-click, then paste the target repo path; or
rem    2. Drag a repo folder onto this bat; or
rem    3. 同步到仓库给云端用.bat D:\path\to\your-repo
rem ============================================================
title SkillBridge - Copy skills into repo for Cloud Agents
setlocal EnableExtensions
cd /d "%~dp0"

set "REPO=%~1"
if "%REPO%"=="" (
  echo.
  echo  Sync Skills for Cloud Agents often does NOT reach agents
  echo  started from cursor.com / Grok Bot. The reliable path is
  echo  to copy skills into the project and commit them.
  echo.
  echo  Enter the repo root that Cloud Agents will check out:
  echo  ^(or drag the folder onto this window and press Enter^)
  echo.
  set /p "REPO=Repo path: "
)

if "%REPO%"=="" (
  echo  [SkillBridge] No path given. Aborted.
  pause
  exit /b 1
)

rem Strip surrounding quotes if the user pasted a quoted path.
set "REPO=%REPO:"=%"

if not exist "%REPO%\" (
  echo  [SkillBridge] Not a directory: %REPO%
  pause
  exit /b 1
)

set "DEST=%REPO%\.cursor\skills"
echo.
echo  [SkillBridge] Copying CC Switch skills into:
echo    %DEST%
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-skills.ps1" -CopyInto "%DEST%"
set "ERR=%ERRORLEVEL%"
echo.
if not "%ERR%"=="0" (
  echo  [SkillBridge] Copy failed - see sync-skills.log
  pause
  exit /b %ERR%
)

echo  Done. Next steps:
echo    1. cd /d "%REPO%"
echo    2. git add .cursor\skills
echo    3. git commit -m "chore: materialize Cursor skills for Cloud Agents"
echo    4. git push
echo    5. Start a NEW Cloud Agent on that commit
echo.
echo  Do NOT commit personal skills into the SkillBridge tool repo
echo  unless you are only testing. Put them in the project you work on.
echo.
pause
