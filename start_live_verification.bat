@echo off
rem ======================================================================
rem  start_live_verification.bat
rem  Web dashboard -> MATLAB live verification in one double-click:
rem    1. starts the bridge server (serves the dashboard + MATLAB link API)
rem    2. opens the dashboard in your browser
rem    3. starts MATLAB with the live verification window (live_verify)
rem  Every input you change in the dashboard then appears in MATLAB and is
rem  verified there. Set MATLAB_EXE to pick a specific MATLAB installation.
rem ======================================================================
setlocal
set "ROOT=%~dp0"
set "PORT=8000"

rem --- Python 3 (the py launcher is preferred) ----------------------------
set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY (where python >nul 2>nul && set "PY=python")
if not defined PY (
  echo [ERROR] Python 3 was not found. Install it from https://www.python.org/ and run this again.
  pause
  exit /b 1
)

rem --- 1. bridge server in its own window ----------------------------------
start "Antenna dashboard bridge - keep this window open" cmd /k %PY% "%ROOT%dashboard\bridge_server.py" --port %PORT%

rem --- 2. dashboard ----------------------------------------------------------
timeout /t 2 /nobreak >nul
start "" "http://localhost:%PORT%/"

rem --- 3. MATLAB with the live link -----------------------------------------
if not defined MATLAB_EXE (
  for /d %%D in ("C:\Program Files\MATLAB\R*") do (
    if exist "%%D\bin\matlab.exe" set "MATLAB_EXE=%%D\bin\matlab.exe"
  )
)
if not defined MATLAB_EXE (
  for /f "delims=" %%M in ('where matlab 2^>nul') do if not defined MATLAB_EXE set "MATLAB_EXE=%%M"
)
if defined MATLAB_EXE (
  echo Starting MATLAB: "%MATLAB_EXE%"
  start "" "%MATLAB_EXE%" -sd "%ROOT%matlab" -r "live_verify"
) else (
  echo [WARN] MATLAB was not found. Open MATLAB yourself and run:
  echo        cd('%ROOT%matlab'^); live_verify
)
echo.
echo Dashboard : http://localhost:%PORT%/
echo MATLAB    : window "Web Dashboard -> MATLAB Live Verification"
endlocal
