@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ollama-impl.ps1" %*
exit /b %ERRORLEVEL%
