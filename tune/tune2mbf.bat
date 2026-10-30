@echo off
rem Compile a text tune to a .MBF file.  Usage: tune2mbf.bat [-o out.MBF] "T120 O4 CDEFG / O3 C2 G2"
rem                                         or: tune2mbf.bat [-o out.MBF] -f tune.txt
rem On first run this creates .venv in the project root and installs requirements.txt.
setlocal
set "HERE=%~dp0"
for %%I in ("%~dp0..\..") do set "ROOT=%%~fI\"
set "VENV_PY=%ROOT%.venv\Scripts\python.exe"

if "%~1"=="" (
    echo Usage: tune2mbf.bat [-o out.MBF] "T120 O4 CDEFG / O3 C2 G2"
    echo        tune2mbf.bat [-o out.MBF] -f tune.txt
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

"%VENV_PY%" "%HERE%tune2mbf.py" %*
