@echo off
setlocal

set "ROOT=%~dp0"
set "PS1=%ROOT%bin\windows.ps1"

rem Auto-fix CRLF line endings (broken by ZIP extraction / WinRAR)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$c=[System.IO.File]::ReadAllText('%PS1%');$c=$c -replace '(?<!\r)\n',\"`r`n\";[System.IO.File]::WriteAllText('%PS1%',$c)"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
  echo.
  echo Portable Hermes stopped with error code %EXITCODE%.
  pause
)

exit /b %EXITCODE%
