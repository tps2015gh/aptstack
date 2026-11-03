@echo off
setlocal enabledelayedexpansion

rem aptstack.cmd - launcher for aptstack.ps1 (cmd/PowerShell wrapper; ExecutionPolicy bypass)
rem Usage:
rem   aptstack.cmd
rem   aptstack.cmd status
rem   aptstack.cmd add app              -> numbered menu: pick zip/folder by number
rem   aptstack.cmd add app <folder|zip> -> add that path directly
rem   aptstack.cmd add php 8.3.36
rem Full help: aptstack.cmd help

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%aptstack.ps1"

if not exist "%PS1%" (
    echo [ERR] not found: %PS1%
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
