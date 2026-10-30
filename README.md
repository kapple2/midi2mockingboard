# Apple II Mockingboard toolchain

MIDI -> `.MBF` converter, Windows player, and a 6502 player/driver on a DOS 3.3 disk for a
Mockingboard (dual AY-3-8910). This folder is self-contained; `src\disk\mb.dsk` is a prebuilt disk.

## Requirements (Windows)

| Needed for | Tool |
| --- | --- |
| everything Python | Python 3.10+ on PATH (the launchers create `.venv` and install `requirements.txt` on first run) |
| building the 6502 code | cc65 in `C:\cc65` (or set `CC65_HOME`) |
| building the disk | AppleCommander `acx.exe` at `C:\bin\acx.exe` (or set `ACX`) |
| running the tests | MAME 0.289 with the `apple2p` ROMs |

`.venv` is created one level above this folder (the project root).

## Use

| Program | Launcher |
| --- | --- |
| Convert + play with one window (drag and drop) | `mb_studio\mb_studio.bat` |
| Standalone exe (no Python needed) | `mb_studio\build_exe.bat` -> `mb_studio\dist\MockingboardStudio.exe` |
| Convert MIDI to MBF | `converter\midi2mbf.bat song.mid [target dir] [name]` |
| Play an MBF on the PC | `win_player\play_mbf.bat song.MBF` |
| Text tune to MBF | `tune\tune2mbf.bat "T120 CDEFG"` |

## Build the Apple II disk

```
converter\midi2mbf.bat midi\song.mid ..\mbf_out
mb_apple2\build.bat
mb_basic\build.bat
mb_disk\build_disk.bat mb.dsk ..\mbf_out      -> disk\mb.dsk
```

The disk starts from `mb_disk\dos33blank.dsk` (copied, never modified). Boot it on an Apple II+/IIe
(48K) with a Mockingboard, or in AppleWin. Songs too big for the disk are skipped.

## Layout

`converter/` MIDI converter, `win_player/` PC player/AY emulator, `tune/` text-tune compiler,
`mb_studio/` GUI, `mb_apple2/` driver and `MBPLAY`, `mb_basic/` the `& MPLAY` command,
`mb_disk/` disk builder, `midi/` sample MIDI files, `disk/` the built disk.
Tests: `mb_apple2\test\run_tests.bat`, `mb_basic\test\run_basic_tests.bat` (need MAME; they expect
converted songs in `..\mbf_out`).
