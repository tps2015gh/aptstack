@echo off
setlocal enabledelayedexpansion

rem aptstack.cmd - ????? aptstack.ps1 ??? cmd/PowerShell ????????????? ExecutionPolicy ????

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%aptstack.ps1"

if not exist "%PS1%" (
    echo [ERR] not found: %PS1%
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
