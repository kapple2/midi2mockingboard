@echo off
rem Rebuild everything in dist\: MPLAY.bin / MPLAY.lbl, mb.dsk and MockingboardStudio.exe.
rem   1. converts every midi\*.mid to ..\mbf_out\*.MBF
rem   2. builds the 6502 player (MPLAY) and the disk dist\mb.dsk from those songs
rem   3. builds the standalone Mockingboard Studio dist\MockingboardStudio.exe (takes a few minutes)
rem Needs Python 3 on PATH (the project .venv is created on first run), cc65 in C:\cc65 and AppleCommander at C:\bin\acx.exe.
rem On macOS / Linux use mb_studio/build_exe.sh for the Studio app.
setlocal
set "HERE=%~dp0"
set "MBF_OUT=%HERE%..\mbf_out"

echo === 1/3 MIDI to MBF ===
if not exist "%MBF_OUT%" mkdir "%MBF_OUT%"
for %%F in ("%HERE%midi\*.mid") do (
    call "%HERE%converter\midi2mbf.bat" "%%~F" "%MBF_OUT%" || exit /b 1
)

echo.
echo === 2/3 MPLAY and mb.dsk ===
call "%HERE%mb_disk\build_disk.bat" mb.dsk "%MBF_OUT%" || exit /b 1

echo.
echo === 3/3 Mockingboard Studio ===
call "%HERE%mb_studio\build_exe.bat" || exit /b 1

echo.
echo All built in "%HERE%dist":
dir /b "%HERE%dist"
