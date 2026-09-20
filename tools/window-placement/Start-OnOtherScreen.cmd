@echo off
rem Shim so the window-placement launcher can be called from cmd.exe or any shell.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-OnOtherScreen.ps1" %*
exit /b %ERRORLEVEL%
