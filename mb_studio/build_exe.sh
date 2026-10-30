#!/bin/sh
# Build a standalone Mockingboard Studio for the OS this runs on (macOS or Linux):
#   macOS -> src/dist/MockingboardStudio.app   (zip it to share)
#   Linux -> src/dist/MockingboardStudio-linux
# PyInstaller cannot cross-compile: run this on each OS (the GitHub Actions workflow
# .github/workflows/build-studio.yml does that for Windows, macOS and Linux).
# Linux needs the system packages python3-tk and libportaudio2 (apt install python3-tk libportaudio2).
# Uses the project .venv (created on first run).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VENV_PY="$ROOT/.venv/bin/python"

if [ ! -x "$VENV_PY" ]; then
    echo "First run: creating virtual environment in $ROOT/.venv ..."
    python3 -m venv "$ROOT/.venv"
fi
"$VENV_PY" -m pip install -r "$HERE/../requirements.txt"

case "$(uname -s)" in
    Darwin) NAME=MockingboardStudio ;;
    *)      NAME=MockingboardStudio-linux ;;
esac

"$VENV_PY" -m PyInstaller --noconfirm --clean --onefile --windowed --name "$NAME" \
    --paths "$HERE/../converter" --paths "$HERE/../win_player" \
    --collect-all tkinterdnd2 \
    --distpath "$HERE/../dist" --workpath "$HERE/build" --specpath "$HERE/build" \
    "$HERE/mb_studio.py"

# macOS --onefile --windowed also leaves a bare binary next to the .app; keep only the .app
[ "$(uname -s)" = Darwin ] && rm -f "$HERE/../dist/$NAME"
echo
echo "Built in $HERE/../dist"
