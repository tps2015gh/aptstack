@echo off
setlocal enabledelayedexpansion

rem aptstack.cmd - เรียก aptstack.ps1 จาก cmd/PowerShell โดยไม่ต้องแก้ ExecutionPolicy ถาวร

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%aptstack.ps1"

if not exist "%PS1%" (
    echo [ERR] not found: %PS1%
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
