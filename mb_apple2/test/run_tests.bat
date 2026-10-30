@echo off
rem Regression tests for the Apple II driver, run in MAME. See run_tests.ps1.
rem Usage: run_tests.bat [folder with the converted .MBF files]   (default: mbf_out in the project root)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_tests.ps1" %*
