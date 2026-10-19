@echo off
title CST Studio & MATLAB Verification Launcher
echo ======================================================================
echo    Connecting MATLAB R2026b and CST Studio Suite for Verification...
echo ======================================================================
cd /d "c:\Users\AARYAN\anteena\matlab"
start "" "C:\Program Files\MATLAB\R2026b\bin\matlab.exe" -nosplash -sd "c:\Users\AARYAN\anteena\matlab" -r "verify"
