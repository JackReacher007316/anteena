@echo off
title MATLAB CST Antenna Verification Launcher
echo ======================================================================
echo   Launching MATLAB R2026b Antenna Surrogate & CST Verification...
echo ======================================================================
echo Working Directory: %~dp0matlab
echo Running Command  : antenna_gui
echo.

if exist "C:\Program Files\MATLAB\R2026b\bin\matlab.exe" (
    start "" "C:\Program Files\MATLAB\R2026b\bin\matlab.exe" -sd "%~dp0matlab" -r "antenna_gui"
) else (
    echo MATLAB path not found at default location. Launching via system PATH...
    start "" matlab -sd "%~dp0matlab" -r "antenna_gui"
)
