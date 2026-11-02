@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
    py -3 control_console.py
) else (
    python control_console.py
)
pause
