@echo off
rem Convert a MIDI file to Mockingboard .MBF (plus a .txt dump).
rem Usage: midi2mbf.bat <midifile> [target directory] [output file name]
rem   target directory   default: the folder of the MIDI file
rem   output file name   default: the MIDI file name; any extension is ignored
rem On first run this creates .venv in the project root and installs requirements.txt.
setlocal
set "HERE=%~dp0"
for %%I in ("%~dp0..\..") do set "ROOT=%%~fI\"
set "VENV_PY=%ROOT%.venv\Scripts\python.exe"

if "%~1"=="" (
    echo Usage: midi2mbf.bat ^<midifile^> [target directory] [output file name]
    exit /b 1
)
if not exist "%~1" (
    echo MIDI file not found: "%~1"
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

set "OUTDIR=%~dp1"
if not "%~2"=="" set "OUTDIR=%~f2\"
set "OUTNAME=%~n1"
if not "%~3"=="" set "OUTNAME=%~n3"

if not exist "%OUTDIR%" mkdir "%OUTDIR%" || exit /b 1

"%VENV_PY%" "%HERE%converter.py" "%~1" -o "%OUTDIR%%OUTNAME%"
