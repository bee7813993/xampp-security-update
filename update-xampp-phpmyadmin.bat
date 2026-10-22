@echo off
rem Replaces the phpMyAdmin bundled with XAMPP for Windows by the latest 5.2.x (see README.md).
rem Usage: update-xampp-phpmyadmin.bat [-XamppDir D:\xampp] [-Restore]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-xampp-phpmyadmin.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
