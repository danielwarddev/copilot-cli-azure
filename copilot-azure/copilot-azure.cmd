@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0copilot-azure.ps1" %*
exit /b %errorlevel%