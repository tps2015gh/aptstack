@echo off
rem as - ทางลัดของ aptstack (คำสั่งเดียวกันทั้งหมด)
setlocal enabledelayedexpansion
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%aptstack.ps1" %*
exit /b %ERRORLEVEL%
