@echo off
powershell.exe -NoProfile -File "%~dp0server-mode.ps1" status
echo.
powershell.exe -NoProfile -File "%~dp0server-mode.ps1" report
pause
