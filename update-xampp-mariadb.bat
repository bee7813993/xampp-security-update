@echo off
rem Replaces the MariaDB bundled with XAMPP for Windows by MariaDB 11.4 LTS and upgrades the data (see README.md).
rem Usage: update-xampp-mariadb.bat [-XamppDir D:\xampp] [-Restore]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-xampp-mariadb.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
