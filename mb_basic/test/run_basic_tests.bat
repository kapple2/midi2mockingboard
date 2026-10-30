@echo off
rem Run the MPLAY tests in MAME: songs, effects, errors, tunes and the KBASIC disk (about 20 minutes).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_basic_tests.ps1" %*
