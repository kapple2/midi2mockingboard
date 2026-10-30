@echo off
rem Mockingboard Studio: one window to convert MIDI files to .MBF and to play .MBF files.
rem Usage: mb_studio.bat [files.mid / files.MBF ...]
rem On first run this creates .venv in the project root and installs requirements.txt.
setlocal
set "HERE=%~dp0"
for %%I in ("%~dp0..\..") do set "ROOT=%%~fI\"
set "VENV_PY=%ROOT%.venv\Scripts\python.exe"
set "VENV_PYW=%ROOT%.venv\Scripts\pythonw.exe"

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

start "" "%VENV_PYW%" "%HERE%mb_studio.py" %*
