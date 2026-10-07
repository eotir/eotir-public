@echo off
rem EOTIR Music Project - one-time helper updater. Put this file and UpdateHelper.ps1 in your helper folder, then double-click this.
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UpdateHelper.ps1"
echo.
pause
