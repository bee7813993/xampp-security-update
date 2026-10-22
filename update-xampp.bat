@echo off
rem Updates both PHP and Apache bundled with XAMPP for Windows (see README.md).
rem Usage: update-xampp.bat [-XamppDir D:\xampp] [-Restore]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-xampp-php.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto done
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-xampp-apache.ps1" %*
set "RC=%ERRORLEVEL%"
:done
echo.
pause
exit /b %RC%
