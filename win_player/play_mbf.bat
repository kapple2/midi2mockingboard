@echo off
rem Play a Mockingboard .MBF file.  Usage: play_mbf.bat <file.MBF> [--loop] [--wav out.wav]
rem On first run this creates .venv in the project root and installs requirements.txt.
setlocal
set "HERE=%~dp0"
for %%I in ("%~dp0..\..") do set "ROOT=%%~fI\"
set "VENV_PY=%ROOT%.venv\Scripts\python.exe"

if "%~1"=="" (
    echo Usage: play_mbf.bat ^<file.MBF^> [--loop] [--wav out.wav]
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

"%VENV_PY%" "%HERE%win_player.py" %*
