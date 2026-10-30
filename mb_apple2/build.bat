@echo off
rem Build the Apple II player: build\MBPLAY.bin (load address $8E00), plus map and labels.
rem Needs cc65 in C:\cc65 (override with CC65_HOME).
setlocal
set "HERE=%~dp0"
if not defined CC65_HOME set "CC65_HOME=C:\cc65"
set "CA65=%CC65_HOME%\bin\ca65.exe"
set "LD65=%CC65_HOME%\bin\ld65.exe"
set "OUT=%HERE%build"

if not exist "%OUT%" mkdir "%OUT%"

rem mb_player must be linked first so its entry point is at $8E00.
"%CA65%" -t none -g -o "%OUT%\mb_player.o" "%HERE%mb_player.s" || exit /b 1
"%CA65%" -t none -g -o "%OUT%\mb_driver.o" "%HERE%mb_driver.s" || exit /b 1
"%CA65%" -t none -g -o "%OUT%\mb_stream.o" "%HERE%mb_stream.s" || exit /b 1
"%LD65%" -C "%HERE%mb_player.cfg" -m "%OUT%\MBPLAY.map" -Ln "%OUT%\MBPLAY.lbl" -o "%OUT%\MBPLAY.bin" "%OUT%\mb_player.o" "%OUT%\mb_driver.o" "%OUT%\mb_stream.o" || exit /b 1
for %%F in ("%OUT%\MBPLAY.bin") do echo Built %%~fF (%%~zF bytes, load address $8E00)
