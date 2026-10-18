@echo off
powershell.exe -NoProfile -File "%~dp0server-mode.ps1" off
timeout /t 3 >nul
