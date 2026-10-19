@echo off
rem ======================================================================
rem  start_live_verification.bat
rem  Web dashboard -> MATLAB live verification in one double-click:
rem    1. makes sure the bridge runs (in the background; a second copy is
rem       never started - install_live_link.bat starts it at every log-in)
rem    2. opens the website (it connects to the bridge on this PC)
rem    3. asks the bridge to start MATLAB with the live window (live_verify),
rem       or to bring the window back if MATLAB is already linked
rem  Every input you change in the dashboard then appears in MATLAB and is
rem  verified there. Set MATLAB_EXE to pick a specific MATLAB installation.
rem  Local dashboard instead of the website:  start_live_verification.bat --local
rem ======================================================================
setlocal
set "ROOT=%~dp0"
set "PY="
py -3 -c "import sys" >nul 2>nul && set "PY=py -3"
if not defined PY python -c "import sys" >nul 2>nul && set "PY=python"
if not defined PY echo [ERROR] Python 3 was not found. Install it from https://www.python.org/downloads/ - tick "Add python.exe to PATH" - then run this file again.
if not defined PY pause
if not defined PY exit /b 1
%PY% "%ROOT%dashboard\live_link_setup.py" start --open --matlab %*
if errorlevel 1 pause
endlocal
