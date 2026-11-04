@echo off
title Dubbing Prompter - video server
where py >nul 2>&1
if not errorlevel 1 goto run_py
where python >nul 2>&1
if not errorlevel 1 goto run_python

echo Python 3 was not found.
echo Install it from https://www.python.org/downloads/  (tick "Add python.exe to PATH"),
echo then start this file again.
pause
exit /b 1

:run_py
py -3 "%~dp0server.py" %*
goto done

:run_python
python "%~dp0server.py" %*

:done
echo.
echo Server stopped. Exit code: %errorlevel%
pause
