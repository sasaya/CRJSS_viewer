@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
set "setup_exit=%ERRORLEVEL%"
pause
exit /b %setup_exit%
