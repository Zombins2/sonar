@echo off
rem Double-click to set up Sonar's server. Runs install.ps1 without changing
rem PowerShell's script policy for anything else.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
