@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-impl.ps1" %*
exit /b %ERRORLEVEL%
