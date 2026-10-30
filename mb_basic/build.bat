@echo off
rem Build the Applesoft & MPLAY command: build\MPLAY.bin (load address $8C00), plus map and labels.
rem Needs cc65 in C:\cc65 (override with CC65_HOME). Uses the driver source in ..\mb_apple2.
setlocal
set "HERE=%~dp0"
if not defined CC65_HOME set "CC65_HOME=C:\cc65"
set "CA65=%CC65_HOME%\bin\ca65.exe"
set "LD65=%CC65_HOME%\bin\ld65.exe"
set "OUT=%HERE%build"

if not exist "%OUT%" mkdir "%OUT%"

rem mb_basic must be linked first so the installer is at $8C00.
"%CA65%" -t none -g -o "%OUT%\mb_basic.o" "%HERE%mb_basic.s" || exit /b 1
"%CA65%" -t none -g -o "%OUT%\mb_tune.o" "%HERE%mb_tune.s" || exit /b 1
"%CA65%" -t none -g -o "%OUT%\mb_driver.o" "%HERE%..\mb_apple2\mb_driver.s" || exit /b 1
"%LD65%" -C "%HERE%mb_basic.cfg" -m "%OUT%\MPLAY.map" -Ln "%OUT%\MPLAY.lbl" -o "%OUT%\MPLAY.bin" "%OUT%\mb_basic.o" "%OUT%\mb_tune.o" "%OUT%\mb_driver.o" || exit /b 1
for %%F in ("%OUT%\MPLAY.bin") do echo Built %%~fF (%%~zF bytes, load address $8C00)
