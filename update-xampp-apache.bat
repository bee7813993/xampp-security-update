@echo off
rem Replaces the Apache bundled with XAMPP for Windows by the Apache Lounge build (see README.md).
rem Usage: update-xampp-apache.bat [-XamppDir D:\xampp] [-KeepCertificate] [-Restore]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-xampp-apache.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
