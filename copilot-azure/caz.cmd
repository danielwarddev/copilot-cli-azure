@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0caz.ps1" %*
exit /b %errorlevel%