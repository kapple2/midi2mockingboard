@echo off
rem Build a standalone Mockingboard Studio (no Python needed to run it): src\dist\MockingboardStudio.exe
rem Uses the project .venv (created on first run).
setlocal
set "HERE=%~dp0"
for %%I in ("%~dp0..\..") do set "ROOT=%%~fI\"
set "VENV_PY=%ROOT%.venv\Scripts\python.exe"

if not exist "%VENV_PY%" (
    echo First run: creating virtual environment in "%ROOT%.venv" ...
    python -m venv "%ROOT%.venv" || (
        echo Could not create the virtual environment. Is Python 3 installed and on PATH?
        exit /b 1
    )
)
"%VENV_PY%" -m pip install -r "%HERE%..\requirements.txt" || (
    echo Could not install requirements.txt.
    exit /b 1
)

"%VENV_PY%" -m PyInstaller --noconfirm --clean --onefile --windowed --name MockingboardStudio ^
    --paths "%HERE%..\converter" --paths "%HERE%..\win_player" ^
    --collect-all tkinterdnd2 ^
    --distpath "%HERE%..\dist" --workpath "%HERE%build" --specpath "%HERE%build" ^
    "%HERE%mb_studio.py" || exit /b 1
echo.
echo Built "%HERE%..\dist\MockingboardStudio.exe"
