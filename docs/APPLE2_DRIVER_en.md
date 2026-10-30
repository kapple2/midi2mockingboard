# Apple II Mockingboard driver and player

Source is in `src/mb_apple2/` (the driver and the file streamer) and `src/mb_basic/` (the resident player `MPLAY`,
the `& MPLAY` command); the disk builder is in `src/mb_disk/`; the finished disk is `src/dist/mb.dsk`.

## Quick start

```
src\converter\midi2mbf.bat song.mid                 ->  song.MBF, song.txt
src\tune\tune2mbf.bat "T120 CDEFG"                  ->  tune.MBF (a text tune, see TUNE_FORMAT_en.md)
src\mb_disk\build_disk.bat out.dsk folder_or_files  ->  bootable DOS 3.3 disk in src\dist\out.dsk
```

`build_disk.bat` (cc65 in `C:\cc65`; build `src\mb_basic\build.bat` first) copies `src\mb_disk\dos33blank.dsk`
(never modified) and adds `MPLAY` (the player), each song as an ordinary DOS file `<TITLE>.MBF` that `CATALOG`
lists, an Applesoft `HELLO` menu, a `DEMO` program that plays a tune written as text and a `PLAYMBF` program that
asks for a file name. Boot the disk on an Apple II+ / IIe with 48K, DOS 3.3 and a Mockingboard and pick a song
number. With `--base other.dsk` the songs, `MPLAY` and `PLAYMBF` go onto an existing disk instead (the
K-HANGEUL / KBASIC disk, for example).

There is one player: `MPLAY`. `BRUN MPLAY` installs the Applesoft command `& MPLAY "NAME"` (the menu does it
first thing), and everything else is a BASIC program that calls it:

```
10 PRINT CHR$ (4);"BRUN MPLAY"
20 & MPLAY "HOTELCALIFORNIA.MBF"
```

While a song plays, any key stops it. `& MPLAY "NAME",1` starts it again when it ends, `,2` turns the keys into
a sound effect (ESC or Q stop). `& MPLAY 8` (a number) sets the size of the ring that the song streams through, in
slots of 512 bytes: 4 after `BRUN MPLAY`, 2 to 28 allowed; a bigger ring pauses the music less often, a smaller one
leaves BASIC more memory. The commands are described in `TUNE_FORMAT_en.md`; the memory they take, and what a
further `&` command has to avoid on the Hangul disk, in `ADDON_MEMORY.md`.

## Using `MPLAY` from another project's disk

`src\mb_basic\build.bat` copies the finished player to `src\dist\MPLAY.bin` (and its label file `MPLAY.lbl`), so another
project can take it from there without building anything:

- `MPLAY.bin` is a raw binary, 3,328 bytes, to be loaded at **`$7D00`**. Put it on the DOS 3.3 disk as a **B** file
  named `MPLAY` with that address, e.g. `cmd /c "C:\bin\acx.exe -p disk.dsk MPLAY B 0x7D00 < MPLAY.bin"`.
- `BRUN MPLAY` runs from `$7D00` (the installer is the first byte, `install` in `MPLAY.lbl` is `$7D00`). It lowers `HIMEM`
  to `$7100` (a ring of 2 KB) and installs `& MPLAY`; everything it uses is in `$7100-$89FF`, and `& MPLAY n` moves the ring's
  start further down (see `ADDON_MEMORY.md` for what that means beside K-HANGEUL, KBASIC and the other `&` commands, and for
  the install order).
- Songs go on the same disk as DOS **T** files whose sectors are in streaming order; `src\mb_disk\build_disk.py --base other.dsk`
  does this, and its code is the reference.
- Rebuild `MPLAY.bin` (and so `dist\`) whenever `mb_basic`, `mb_apple2` or `mb_layout.inc` change.

## How songs are stored

Each song is an ordinary DOS 3.3 text (T) file (`CATALOG` lists it, and `BLOAD` refuses it). `build_disk.py`
writes it straight into the disk image, because it places the sectors on purpose: on each track in the order
0,14,13,...,8,7,6,...,1,15, which the drive delivers (physical sectors 0,2,...,14,1,3,...,15) with the least
waiting. `MPLAY` finds the file by name in the catalog, then reads the file's track/sector list and its sectors
through DOS's own `RWTS` routine, front to back, a slot of 2 sectors at a time, so a song can be as big as the
disk. DOS itself reads files at only about 1.3 KB/s, and `BLOAD` has no offset or length, which is why `MPLAY` does
not use DOS to read. A binary (B) file works as well: its 4-byte header is skipped.

The ring is made of slots of 512 bytes (2 sectors): 4 of them after `BRUN MPLAY`, and `& MPLAY n` sets the number
(2 to 28). All the slots are read before the music starts, so a song that fits the ring (2 KB by default) is
read once and the disk is not touched again. A bigger one is streamed: when the music has moved on from a slot,
the drive is switched on, the music plays 64 more ticks (1.3 s) while it spins up, then the next 2 sectors are read
(the music stops for that, 0.06-0.35 s) and the music goes on. The five test songs (the files in `mbf_out\`) take 129,792
of the disk's 143,360 bytes.

## The `.MBF` file format

An 8-byte header (`MBF1`, tick rate as u16 little-endian, loop flag, reserved), then one frame
per tick:

- a count byte N (0-22), then N pairs `[chip<<4 | register, value]`; the registers are 0-10
  (tones, noise period, mixer, volumes). Count 0 is a tick with no change.
- a count byte `$80 + n` (n = 1-126) stands for n such empty ticks in a row. Most of a song is
  empty ticks, so this halves the files.
- `$FF` ends the stream. The first frame is a full keyframe.

The converter writes this, `win_player.py` and the driver read it. Percussion is played on the
AY noise generator: a drum hit takes a voice for a few ticks (the converter turns that channel's
tone off and its noise on in the mixer, sets the chip's noise period and fades the volume).

## Using the driver in a game (`mb_driver.s`)

Link `mb_driver.o` and call:

| Routine | In | Out |
| --- | --- | --- |
| `MB_INIT` | A = slot 1-7, or 0 to scan slots 4,5,6,7,2,1,3 | C clear, A = slot; C set = no card |
| `MB_PLAY` | A/X = address of an `.MBF` file in memory | C set = not a valid MBF1 file |
| `MB_POLL` | none; call it often | C clear = playing, C set = stopped |
| `MB_UPDATE` | none; call once per tick yourself | C clear = playing, C set = stopped |
| `MB_STOP` | none | silences both chips |
| `MB_SFX` | A/X = address of an effect stream | effect plays inside `MB_UPDATE` |

For a song read from a ring buffer that something else refills (`mb_stream.s` does this):
`MB_RING` (wrap the read pointer at a high byte), `MB_POS` (high byte of the read pointer),
`MB_TICK` (ticks played, modulo 256), `MB_PAUSE` and `MB_RESUME` (silence the chips around a
disk read, then restore the volumes and restart the tick timer).

- `MB_POLL` watches 6522 timer 1 (set from the file's tick rate) and runs `MB_UPDATE` when
  it fires. If your loop is slower than one tick, ticks are lost and the music slows down.
  Use `MB_UPDATE` from your own timer instead if you need exact timing.
- Zero page: 5 bytes at `$FA-$FE`. Variables: 54 bytes (segment `BSS`). Code and tables:
  972 bytes.
- An effect is a stream in the same format as the song frames (count byte, then
  `[chip<<4 | register, value]` pairs, `$FF` to end). It borrows chip 1 channels B and C
  (registers 2-5, 9, 10); music writes there are held back and the channels are handed back
  when the effect ends. Writes to any other register are ignored. Tone only, no noise.
- Tick rate must be 16-255 Hz (`converter.py --rate`). 50 Hz is the default.

`mb_stream.s` (needs DOS 3.3 in memory; the ring's place and size are in `mb_layout.inc`): `FILE_OPEN` (A/X = file name,
Y = its length; returns the bytes of header to skip, 0 or 4), `STREAM_OPEN` and `STREAM_SERVICE` (fill the ring,
then call from the main loop), `STREAM_STOP` (drive motor off), `STREAM_RESTART` (below). It finds DOS's
parameter list with `LOCRPL` (`$03E3`) and reads through `RWTS` (`$03D9`).

**Looping a streamed song.** The driver's own loop flag only works while the whole song is in
RAM. When `MB_POLL` reports that a streamed song has ended, call `STREAM_RESTART`: it refills
the ring from the start of the file and starts the song again (C set = disk error). The music is silent
while it reads all the slots (about 0.12 s per slot), plus the drive's spin-up. `& MPLAY "NAME",1` does this.

## Memory map of `MPLAY`

`BRUN MPLAY` loads the file at `$7D00` and lowers `HIMEM` to `$7100`. Everything it uses is in `$7100-$89FF`. The ring
is the only part whose size changes: it ends at `$78FF` and `& MPLAY n` moves its start (and `HIMEM`) down for a bigger
one, or up for a smaller one, so nothing else ever moves.

| Range | Use |
| --- | --- |
| `$7100-$78FF` | the song ring: 4 slots of 512 bytes (2 KB) after `BRUN`; `& MPLAY n` makes it n slots, `$7900 - n * $200`. A text tune is compiled into it too (the ring less one page: 1,792 bytes after `BRUN`). It is not part of the file |
| `$7900-$793F` | copy of the ring's first 64 bytes, so a frame can run past the ring end |
| `$7A00-$7AFF` | sector buffer for the catalog and track/sector lists |
| `$7B00-$7CFF` | driver, streamer and tune compiler variables |
| `$7D00-$89FF` | code and tables (the file, 3,328 bytes: this part is full to the last byte) |
| `$06-$09`, `$EB-$EF`, `$FA-$FE` | zero page, while a call runs |
| `$03F5` | the `&` vector |

It ends under `$8A00`, so it runs unchanged beside KBASIC (`$8A00-$93FF`), `TYPE` (`$8E00`) and the Hangul driver
(everything below `$4000` and above `$9400`). `ADDON_MEMORY.md` has the whole map and the rules. On a plain DOS 3.3
disk it works the same: `HIMEM` is `$9600` there, and `BRUN MPLAY` still lowers it to `$7100`.

## Tests

`src\mb_basic\test\run_basic_tests.bat` rebuilds `MPLAY`, builds `src\dist\mb.dsk`, and runs the checks in MAME
(headless, Phasor card in Mockingboard mode, about 20 minutes). A Lua script logs every AY register write seen on
the 6522 bus, and `check_log.py` compares them with the `.MBF` file:

- the ring holds, at the first note, exactly the first bytes of the file that fit it (the disk reads are right)
- every song plays through with all register writes matching, in order (Arty, Chopin, Mozart, Bliss with its drums,
  Hotel California); the refill pauses are measured, the silence and volume-restore writes around each match
  the music's state, and the music is on time once the pauses are taken out
- a streamed song that starts again by itself (`,1`): both passes match the file
- sound effect on idle channels, over busy channels, and while streaming (`,2`)
- card in slot 4, 7 and 1; no card at all (`I/O ERROR`); a file that is not an MBF and one with a tick rate
  below 16 Hz (`FILE TYPE MISMATCH`)
- the `HELLO` menu, `RUN DEMO`, `RUN PLAYMBF`
- text tunes: the RAM and the AY writes equal what `tune2mbf.py` builds for five tunes (one with every command,
  six voices and a seventh ignored; an empty one; one that overflows the buffer; one in a string variable)
- on the K-HANGEUL / KBASIC disk (`KBASIC.DSK` of `proj-apple2-korean-basic`, if present): Chopin streams and a tune
  plays with the Hangul driver and KBASIC loaded, and the Hangul font, KBASIC and the `CHRGET` patch are byte for
  byte the same afterwards

## Limits and what is not done

- **Stereo: chip 1 is the left channel, chip 2 the right.** If half the notes are missing, check
  that both sides of your speakers or headphones and the Windows sound balance are working.
  In AppleWin the notes from chip 2 were silent until the Windows sound settings were fixed. A test
  disk with one note per channel (chip 1 A, B, C, then chip 2 A, B, C) finds this quickly.
- **Heard in AppleWin 1.32 only for a tone, a six-channel scale and a loaded song** (Mockingboard C
  in slot 4), with the earlier player. The streaming `MPLAY` has not been listened to. Nothing has been run on a real
  Mockingboard or a real Disk II. The sector order and the read times come from MAME's disk emulation, and
  the 1.3 s spin-up allowance is a guess for a real drive.
- **Streaming pauses the music** for the time the sectors take, because a stock DOS 3.3
  disk read stops the CPU. With the ring `BRUN MPLAY` makes (4 slots of 512 bytes, MAME) a pause is 0.06-0.37 s: Chopin
  pauses 12 times (1.9 s in all over 2 minutes), Mozart 39 times (5.8 s), Bliss 61 times (9.4 s), Hotel California (43 KB) 82
  times (13.7 s in 6.5 minutes); a denser song pauses more often. A ring of 8 slots halves Chopin to 8 pauses
  (1.3 s). Smooth streaming would need a custom disk reader with an interrupt-driven tick, which is not built.
- **The ring is small** (2 KB after `BRUN`) to leave BASIC its memory on the Hangul disk: 12,543 bytes remain there with KBASIC
  and `MPLAY` loaded. The earlier 4 KB ring gave 10,495 bytes and about half as many pauses (Hotel California 39, 10.6 s in
  all). `& MPLAY n` lets the program choose per run: more slots, fewer pauses; fewer slots, more BASIC memory (2 slots:
  13,567 bytes, 14 pauses for Chopin). The slot size and the default are in `mb_layout.inc`.
- **`MPLAY` fills its part of the block to the byte** (3,328 bytes under `$8A00`); a bigger program needs the ring moved
  down another page or code trimmed.
- Needs standard DOS 3.3 in memory (`RWTS` at `$03D9`, its parameter list from `$03E3`).
- **Timing.** The driver assumes the 1,022,727 Hz clock (same as the PRD and MAME).
  MAME shows a steady 22.5 ppm slow tick (4.6 ms over 206 s). A real NTSC Apple II averages
  about 1,020,484 Hz, which would make tempo and pitch about 0.2% low; this is not measured.
- **Polled, not interrupt-driven.** The PRD allows an IRQ timer; only polling is built.
- Both 6522s (`$Cn00` and `$Cn80`) must answer; a card with one AY is not detected.
- **Drums are approximate.** (`--no-drums` leaves them out.) They use the noise generator with one shared noise period per chip
  and no envelope; a hit takes a voice from the melody for a few ticks when all six are busy
  (Hotel California loses 8 of 1,258 hits and 870 of its melody notes to the six-voice limit).
- `& MPLAY` blocks the program while it plays (see `TUNE_FORMAT_en.md`).
