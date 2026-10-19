@echo off
rem ======================================================================
rem  install_live_link.bat  -  ONE-TIME setup, then MATLAB stays connected
rem    1. starts the bridge now and every time you log in to Windows
rem       (in the background, no window, no admin rights needed)
rem    2. checks MATLAB once and makes every MATLAB session open the live
rem       link (a small block in MATLAB's startup.m)
rem    3. opens the website, which then starts MATLAB with the live window
rem  Undo everything: uninstall_live_link.bat
rem ======================================================================
setlocal
set "ROOT=%~dp0"
set "PY="
py -3 -c "import sys" >nul 2>nul && set "PY=py -3"
if not defined PY python -c "import sys" >nul 2>nul && set "PY=python"
if not defined PY echo [ERROR] Python 3 was not found. Install it from https://www.python.org/downloads/ - tick "Add python.exe to PATH" - then run this file again.
if not defined PY pause
if not defined PY exit /b 1
%PY% "%ROOT%dashboard\live_link_setup.py" install %*
echo.
pause
endlocal
