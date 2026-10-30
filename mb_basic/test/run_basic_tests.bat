@echo off
rem Run the & MPLAY tests in MAME (about a minute).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_basic_tests.ps1" %*
