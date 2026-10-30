# Apple II Mockingboard toolchain

A complete pipeline for playing music on an Apple II with a **Mockingboard** sound card (two AY-3-8910 chips, six
tone channels plus noise for drums): turn a MIDI file into a compact Apple II music file, check how it sounds on the
PC, and play it on the Apple II from Applesoft BASIC with one command, `& MPLAY "SONG"`.

## What it is

The Mockingboard has no sampled sound: a song is a stream of register writes to the two AY chips. This project
converts MIDI into exactly that stream, stores it in a small file format (`.MBF`), and provides the tools on both sides:

- **On the PC:** a converter (MIDI → `.MBF`), a player that emulates the two AY chips in stereo (chip 1 left, chip 2
  right) so you can hear the result without an Apple II, a compiler for tunes written as text, and a window
  (Mockingboard Studio) that does the converting and playing with drag and drop.
- **On the Apple II:** a driver for the card (detects it in any slot, plays an `.MBF` stream on a timer) and a resident
  player, `MPLAY`, that adds the Applesoft command `& MPLAY "NAME"`. It streams songs of any size straight from a
  DOS 3.3 disk, so a song can be as big as the disk. It also plays tunes written inside a BASIC program, loops, and
  can make a sound effect on a key press.
- **Made to coexist with the Korean (Hangul) projects:** `MPLAY` keeps to one fixed block of memory (`$7100-$89FF` by default; `& MPLAY n` sets the size of the song ring)
  and chains the `&` vector, so it runs beside the K-HANGEUL driver and KBASIC. It also works on a plain DOS 3.3 disk.

## Quick run

The Windows binaries are already built and sit in `src\dist\`. You can use them right away, with no Python, cc65 or
anything else installed.

| File | What it is | How to use it right away |
| --- | --- | --- |
| `MockingboardStudio.exe` | A Windows program: a window that converts MIDI files for the Mockingboard and plays the result on the PC | Double-click it. On the **Convert** tab drop `.mid` files on the list and press Convert; the `.MBF` files go to `mbf_out` next to the exe by default. On the **Play** tab pick an `.MBF` and press Play |
| `mb.dsk` | A bootable Apple II DOS 3.3 disk with `MPLAY`, five songs, a menu and demo programs | Mount it as drive 1 in AppleWin or MAME (`apple2p`), with a Mockingboard in a slot (`-sl5 phasor` in MAME), and boot. Pick a song number in the menu; any key stops it. On a real Apple II+/IIe (48K), transfer the image to a floppy and boot it |
| `MPLAY.bin` | The raw binary of the resident player (the program that adds the `& MPLAY` command), load address `$7D00` | A part for your own DOS 3.3 disk: `cmd /c "C:\bin\acx.exe -p disk.dsk MPLAY B 0x7D00 < MPLAY.bin"`, then `BRUN MPLAY`, then `& MPLAY "SONGNAME"` in BASIC |
| `MPLAY.lbl` | The linker's label file for `MPLAY.bin` (a list of the address of each symbol) | Not used on its own. Look at it only when you need an address inside the player (see "Rebuild everything" below) |

A good first try: convert one of the sample `.mid` files in `midi\` with the Studio and listen to it, then boot `mb.dsk` and
hear the same song on the Apple II. There is no macOS or Linux Studio among these binaries; build it on that OS or use the
GitHub Actions workflow (see below).

## What you get

| Product | Where | What it is |
| --- | --- | --- |
| **Mockingboard Studio** | `dist\MockingboardStudio.exe` (Windows; macOS/Linux builds are described below) | One window to convert MIDI files and play `.MBF` files, no Python needed |
| **`mb.dsk`** | `dist\mb.dsk` | A bootable DOS 3.3 disk: `MPLAY`, five songs as ordinary DOS files, a menu (`HELLO`) and two demo programs (`DEMO`, `PLAYMBF`) |
| **`MPLAY`** | `dist\MPLAY.bin`, `dist\MPLAY.lbl` | The resident player, ready to put on any other DOS 3.3 disk (the K-HANGEUL / KBASIC disk, for example) |
| MIDI converter | `converter\` | MIDI → `.MBF` (chooses voices for six channels, plays drums on the noise generator, sets the volume per song) |
| PC player | `win_player\` | Plays `.MBF` through an emulation of the AY-3-8910 pair, also usable as a library |
| Text tune compiler | `tune\` | Turns a text tune such as `T120 CDEFG` into `.MBF` (same algorithm as `& MPLAY "!..."` on the Apple II) |
| Apple II driver | `mb_apple2\` | `mb_driver.s` (card driver, for use in your own games) and `mb_stream.s` (reads a song from disk while it plays) |
| Disk builder and tests | `mb_disk\`, `mb_basic\test\` | Builds disks from a blank DOS 3.3 image; the tests run the player in MAME and compare every AY register write with the `.MBF` file |

## How the pieces fit

```
song.mid --converter--> song.MBF --+--> win_player / Studio   (hear it on the PC)
"T120 CDEFG" --tune--> tune.MBF ---+--> mb_disk --> mb.dsk --> Apple II: & MPLAY "SONG"
```

What is and is not checked: the Apple II side is checked by logging the AY register writes in MAME (see the tests
section of `docs\APPLE2_DRIVER_en.md`); it has not been run on real hardware, and the streamed playback pauses briefly
(0.1-0.4 s) each time the next part of a long song is read from the disk. Details are in `docs\APPLE2_DRIVER_en.md`
(the player, the memory map, the limits) and `docs\TUNE_FORMAT_en.md` (the text tune notation and `& MPLAY`).

Korean is the main language of these documents: each `X.md` is Korean and `X_en.md` is the English version.

## Rebuild everything

`build_all.bat` (in this folder) does three steps, in this order:

1. **MIDI to MBF.** Converts every `midi\*.mid` to `.MBF` (and a `.txt` dump) in `..\mbf_out` (the project root, outside
   `src`). These are the songs for the disk. Add a `.mid` to `midi\` and it is picked up on the next run.
2. **`MPLAY` and the disk.** Calls `mb_disk\build_disk.bat mb.dsk ..\mbf_out`, which first runs `mb_basic\build.bat`
   (assembles and links the 6502 code into `mb_basic\build\`, then copies the result to `dist\`) and then writes the disk
   from a copy of `mb_disk\dos33blank.dsk`.
3. **Studio.** Calls `mb_studio\build_exe.bat`, which packs Mockingboard Studio with PyInstaller (takes about a minute).

What ends up in `dist\` and what each file is for:

| File | Made by | What it is for |
| --- | --- | --- |
| `mb.dsk` | step 2 | The Apple II disk. Boot it (AppleWin, MAME or a real Apple II with a Mockingboard) and pick a song from the menu. |
| `MPLAY.bin` | step 2 | The resident player, a raw binary to load at `$7D00`. This is what another project puts on its own DOS 3.3 disk (for example the K-HANGEUL / KBASIC disk) as a **B** file named `MPLAY`: `cmd /c "C:\bin\acx.exe -p disk.dsk MPLAY B 0x7D00 < MPLAY.bin"`. Then `BRUN MPLAY` installs `& MPLAY`. |
| `MPLAY.lbl` | step 2 | The linker's label file for `MPLAY.bin` (see below). Optional; only for people who need addresses inside the player. |
| `MockingboardStudio.exe` | step 3 | Mockingboard Studio for Windows, a single file that needs no Python. |

**What `MPLAY.lbl` is.** The linker (`ld65 -Ln`) writes it beside `MPLAY.bin`. It is plain text, one line per symbol with the
address the symbol got, for example `al 007D00 .install` (the label `install` is at `$7D00`). The player does not need it and it
never goes on a disk. It is for tools that want to know where something is without rebuilding the player:

- `mb_disk\build_disk.py` reads `install` from it to get the address that `BRUN MPLAY` starts at.
- The MAME tests (`mb_basic\test\`) read `mb_paused` from it, the player's flag for "the music is paused while a part of a
  song is read from disk", to tell a disk pause from a note.
- Another project can look up an address in the player, such as the entry point or a variable, from `dist\MPLAY.lbl` instead
  of building `MPLAY`. Rebuild `dist\` whenever `mb_basic`, `mb_apple2` or `mb_layout.inc` change, so the `.bin` and `.lbl` stay a pair.

The `mb_basic\build\` folder also holds the map (`MPLAY.map`, which shows the size of every segment) and the object files;
they are build leftovers and are not tracked in git. On macOS / Linux build the Studio with `sh mb_studio/build_exe.sh`.
It needs Python on PATH, cc65 in `C:\cc65` and AppleCommander at `C:\bin\acx.exe`; close AppleWin first if it has `mb.dsk` open.

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
| Standalone exe (no Python needed) | `mb_studio\build_exe.bat` -> `dist\MockingboardStudio.exe` |
| Standalone app for macOS / Linux | `sh mb_studio/build_exe.sh` on that OS, or the GitHub Actions workflow (see "Standalone Studio" below) |
| Convert MIDI to MBF | `converter\midi2mbf.bat song.mid [target dir] [name]` |
| Play an MBF on the PC | `win_player\play_mbf.bat song.MBF` |
| Text tune to MBF | `tune\tune2mbf.bat "T120 CDEFG"` |

## Standalone Studio on Windows, macOS and Linux

PyInstaller cannot cross-compile: each OS has to build its own. Windows and macOS/Linux use the same options
(one file, windowed, `converter` and `win_player` as libraries, `tkinterdnd2` bundled).

| OS | Build | Result in `dist/` |
| --- | --- | --- |
| Windows | `mb_studio\build_exe.bat` | `MockingboardStudio.exe` |
| macOS | `sh mb_studio/build_exe.sh` | `MockingboardStudio.app` |
| Linux | `sh mb_studio/build_exe.sh` | `MockingboardStudio-linux` |

- **Linux** needs two system packages first: `sudo apt install python3-tk libportaudio2` (tkinter and PortAudio for
  `sounddevice`). Other distributions have the same two under other names.
- **macOS** needs a Python with tkinter (the python.org installer has it; with Homebrew, `brew install python-tk`).
  The app is unsigned, so the first time, right-click it and choose Open to get past Gatekeeper. Zip the `.app` to share it.
  Frozen on macOS the default output folder is `~/Documents/mbf_out` (next to the exe would be inside the bundle);
  on Windows and Linux it is `mbf_out` next to the executable.
- `build_exe.sh` uses the same `.venv` as the other launchers (one level above this folder) and `requirements.txt`.
- **Without a Mac or Linux machine:** the GitHub Actions workflow `.github/workflows/build-studio.yml` builds all
  three on GitHub's runners (Actions tab -> Run workflow, or push a `v*` tag) and offers each result as a downloadable
  artifact. It needs `src` to be the root of the GitHub repository.
- Only the Windows exe is committed to git; the Mac and Linux builds are in `.gitignore`.
- Not tested: the Mac and Linux builds have never been run (this project was built on Windows), and the Linux/macOS
  audio output through PortAudio has not been listened to.

## Build the Apple II disk

```
converter\midi2mbf.bat midi\song.mid ..\mbf_out
mb_basic\build.bat
mb_disk\build_disk.bat mb.dsk ..\mbf_out      -> dist\mb.dsk
mb_disk\build_disk.bat out.dsk ..\mbf_out --base KBASIC.DSK     (songs and MPLAY onto the Hangul disk)
```

The disk starts from `mb_disk\dos33blank.dsk` (copied, never modified). Boot it on an Apple II+/IIe
(48K) with a Mockingboard, or in AppleWin. Songs too big for the disk are skipped.

## Layout

`converter/` MIDI converter, `win_player/` PC player/AY emulator, `tune/` text-tune compiler,
`mb_studio/` GUI, `mb_apple2/` the Mockingboard driver and the disk streamer, `mb_basic/` the resident player (`& MPLAY`),
`mb_disk/` disk builder, `midi/` sample MIDI files, `dist/` the built disk and exe,
`docs/` the Apple II driver and player (`APPLE2_DRIVER.md`) and the text-tune format (`TUNE_FORMAT.md`), each also as `_en.md`.
Tests: `mb_basic\test\run_basic_tests.bat` (needs MAME; it expects
converted songs in `..\mbf_out`).
