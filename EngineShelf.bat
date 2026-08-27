@echo off
REM Double-clickable launcher for Windows. Opens the engineshelf manager.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui.ps1" %*
if errorlevel 1 pause
