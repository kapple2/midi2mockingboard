@echo off
rem Build a bootable Apple II disk with the Mockingboard player and songs.
rem Usage: build_disk.bat <output.dsk> <file.MBF | folder> [more files or folders]
rem A bare output name such as mb.dsk is created in src\disk, where all disk images go.
rem Starts from dos33blank.dsk in this folder (never modified) and builds the
rem 6502 player first if needed.  Needs cc65 (C:\cc65) and AppleCommander (C:\bin\acx.exe).
setlocal
set "HERE=%~dp0"
for %%I in ("%~dp0..\..") do set "ROOT=%%~fI\"
set "VENV_PY=%ROOT%.venv\Scripts\python.exe"

if "%~2"=="" (
    echo Usage: build_disk.bat ^<output.dsk^> ^<file.MBF ^| folder^> [more files or folders]
    exit /b 1
)

if not exist "%VENV_PY%" (
    echo First run: creating virtual environment in "%ROOT%.venv" ...
    python -m venv "%ROOT%.venv" || (
        echo Could not create the virtual environment. Is Python 3 installed and on PATH?
        exit /b 1
    )
    "%VENV_PY%" -m pip install -r "%ROOT%src\requirements.txt" || (
        echo Could not install requirements.txt. Delete .venv and try again.
        exit /b 1
    )
)

call "%ROOT%src\mb_apple2\build.bat" || exit /b 1
"%VENV_PY%" "%HERE%build_disk.py" %*
