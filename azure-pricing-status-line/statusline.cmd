:: Hide commands from printing
@echo off

:: Switch the console to UTF-8 and suppress the confirmation message
chcp 65001 > nul

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0statusline.ps1"