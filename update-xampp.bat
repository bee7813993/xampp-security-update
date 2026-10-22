@echo off
rem Updates PHP, Apache, MariaDB and phpMyAdmin bundled with XAMPP for Windows, in this order (see README.md).
rem Components that are not installed are skipped.
rem Usage: update-xampp.bat [-XamppDir D:\xampp] [-Restore]
setlocal
set "RC=0"
for %%S in (php apache mariadb phpmyadmin) do (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-xampp-%%S.ps1" %*
    if errorlevel 1 goto failed
)
goto done
:failed
set "RC=%ERRORLEVEL%"
:done
echo.
pause
exit /b %RC%
