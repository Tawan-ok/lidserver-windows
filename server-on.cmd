@echo off
powershell.exe -NoProfile -File "%~dp0server-mode.ps1" on
timeout /t 3 >nul
