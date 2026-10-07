@echo off
rem EOTIR Music Project - one-time render helper updater. Double-click it; it finds your helper folder, checks Ryan's signature, updates, keeps your key.
set "PSModulePath="
set "U=https://raw.githubusercontent.com/eotir/eotir-public/main/render/helper/UpdateHelper.ps1"
set "P=%TEMP%\eotir_update_helper.ps1"
echo.
echo   EOTIR MUSIC PROJECT - helper updater
echo   Getting the latest updater...
curl.exe -fsSL --max-time 60 --retry 2 -o "%P%" "%U%"
if errorlevel 1 (
  echo.
  echo   Could not download the updater. Check your internet, then try again.
  echo   If it keeps failing, send Ryan a screenshot of this window.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%P%"
del "%P%" >nul 2>&1
echo.
pause
