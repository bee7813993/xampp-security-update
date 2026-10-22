@echo off
rem Replaces the PHP bundled with XAMPP for Windows by the fixed official build (see README.md).
rem Usage: update-xampp-php.bat [-XamppDir D:\xampp] [-NoHarden] [-Restore]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-xampp-php.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
