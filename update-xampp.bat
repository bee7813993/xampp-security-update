@echo off
rem Updates PHP, Apache, MariaDB and phpMyAdmin bundled with XAMPP for Windows, in this order (see README.md).
rem Components that are not installed are skipped. -Restore goes in the reverse order (see update-xampp.ps1).
rem Usage: update-xampp.bat [-XamppDir D:\xampp] [-Restore]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-xampp.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
