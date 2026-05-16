@echo off
setlocal

set "ROOT=%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%bin\windows.ps1"
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
  echo.
  echo Portable Hermes stopped with error code %EXITCODE%.
  pause
)

exit /b %EXITCODE%
