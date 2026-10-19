@echo off
rem ======================================================================
rem  uninstall_live_link.bat  -  undo install_live_link.bat
rem    stops the background bridge, removes its Windows log-in entry and
rem    removes the live-link block from MATLAB's startup.m
rem ======================================================================
setlocal
set "ROOT=%~dp0"
set "PY="
py -3 -c "import sys" >nul 2>nul && set "PY=py -3"
if not defined PY python -c "import sys" >nul 2>nul && set "PY=python"
if not defined PY echo [ERROR] Python 3 was not found. Install it from https://www.python.org/downloads/ - tick "Add python.exe to PATH" - then run this file again.
if not defined PY pause
if not defined PY exit /b 1
%PY% "%ROOT%dashboard\live_link_setup.py" uninstall
echo.
pause
endlocal
