@echo off
rem Build the resident player: build\MPLAY.bin (loads at $7D00; BRUN MPLAY installs & MPLAY), plus map and labels.
rem Needs cc65 in C:\cc65 (override with CC65_HOME). Uses the driver and streamer sources in ..\mb_apple2.
setlocal
set "HERE=%~dp0"
if not defined CC65_HOME set "CC65_HOME=C:\cc65"
set "CA65=%CC65_HOME%\bin\ca65.exe"
set "LD65=%CC65_HOME%\bin\ld65.exe"
set "OUT=%HERE%build"
set "INC=%HERE%..\mb_apple2"

if not exist "%OUT%" mkdir "%OUT%"

rem mb_basic must be linked first so the installer is the first byte of the file ($7D00).
"%CA65%" -t none -g -I "%INC%" -o "%OUT%\mb_basic.o" "%HERE%mb_basic.s" || exit /b 1
"%CA65%" -t none -g -I "%INC%" -o "%OUT%\mb_tune.o" "%HERE%mb_tune.s" || exit /b 1
"%CA65%" -t none -g -I "%INC%" -o "%OUT%\mb_driver.o" "%INC%\mb_driver.s" || exit /b 1
"%CA65%" -t none -g -I "%INC%" -o "%OUT%\mb_stream.o" "%INC%\mb_stream.s" || exit /b 1
"%LD65%" -C "%HERE%mb_basic.cfg" -m "%OUT%\MPLAY.map" -Ln "%OUT%\MPLAY.lbl" -o "%OUT%\MPLAY.bin" "%OUT%\mb_basic.o" "%OUT%\mb_tune.o" "%OUT%\mb_driver.o" "%OUT%\mb_stream.o" || exit /b 1
for %%F in ("%OUT%\MPLAY.bin") do echo Built %%~fF (%%~zF bytes, load address $7D00)

rem Publish for other projects (put MPLAY.bin on their DSK as a B file at $7D00, see APPLE2_DRIVER.md).
if not exist "%HERE%..\dist" mkdir "%HERE%..\dist"
copy /y "%OUT%\MPLAY.bin" "%HERE%..\dist\MPLAY.bin" >nul || exit /b 1
copy /y "%OUT%\MPLAY.lbl" "%HERE%..\dist\MPLAY.lbl" >nul || exit /b 1
echo Copied MPLAY.bin and MPLAY.lbl to "%HERE%..\dist"
