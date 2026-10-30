# Text tunes and `& MPLAY`

A tune is a short piece of music written as text. The same text plays on the Apple II
(`& MPLAY "!..."` in Applesoft BASIC) and compiles to an `.MBF` file on Windows
(`src\tune\tune2mbf.bat`), which the Windows player and the Apple II driver can play.

```
src\tune\tune2mbf.bat -o twinkle.MBF "T120 O4 L4 CCGGAAG2 FFEEDDC2 / O3 L2 CGFC GCFC"
src\win_player\play_mbf.bat twinkle.MBF
```

## The notation

A tune has up to 6 voices separated by `/`. Voice 1-3 play on chip 1 channels A-C (left),
voice 4-6 on chip 2 channels A-C (right). More voices are ignored. Every voice starts with
`T120 L4 O4 V12`, so a command in one voice does not change the others. Spaces and unknown
characters are ignored; upper or lower case.

| Command | Meaning |
| --- | --- |
| `C D E F G A B` | a note; then `#` or `+` for a sharp, `-` for a flat; then a length; then dots |
| `R` | a rest, with a length and dots like a note |
| `L<n>` | default length: 1 whole note, 2 half, 4 quarter, 8 eighth ... up to 64 |
| `O<n>` | octave 0-7; `O4 C` is middle C (261.6 Hz) |
| `<` `>` | one octave down / up |
| `T<n>` | tempo in quarter notes per minute, 32-255 |
| `V<n>` | volume 0-15 |

A length after a note (`C8`, `G2`) overrides the default for that note. Each dot adds half of
the previous value (`C4.` is a quarter plus an eighth). A note of 3 ticks (60 ms) or more
has its last tick silent, so repeated notes are heard separately.

Timing is in 50 Hz ticks, in whole numbers: a whole note lasts `12000 / T` ticks, and a note
`1/n` of it lasts the whole note's ticks divided by `n` (rounded down, at least 1 tick).

## `& MPLAY` on the Apple II

`src\mb_basic\` builds `MPLAY`, a 3.2 KB program for DOS 3.3 (load address `$7D00`). It is on
`src\dist\mb.dsk` together with the menu `HELLO` and the programs `DEMO` and `PLAYMBF`. In a program
(or typed):

```
10 PRINT CHR$ (4);"BRUN MPLAY"
15 & MPLAY 8
20 & MPLAY "!T120 O4 L8 CDEFGAB>C4"
30 & MPLAY "SONG"
40 & MPLAY "SONG",1
```

- `BRUN MPLAY` installs the command (it sets the `&` vector at `$03F5`, and lowers `HIMEM` to
  `$7100`). Do it once, early: before the program has made any string, and after `BRUN TYPE`.
- `& MPLAY n` (a number, an expression is fine) sets the song ring to n slots of 512 bytes, 2 to 28; 4 (2 KB) after `BRUN`.
  It moves `HIMEM`, so it works only while no string exists yet: put it right after the `BRUN`. A bigger ring means fewer
  pauses while a long song is read from the disk (a song that fits the ring is read once, then never again) and longer tunes
  from text; a smaller one leaves BASIC more memory (13,567 bytes of program and variables at 2 slots, 12,543 at 4,
  10,495 at 8 on the Hangul disk with KBASIC). The errors are `ILLEGAL QUANTITY` (n below 2 or above 28)
  and `OUT OF MEMORY` (a string exists, the program is too big for the ring, or the program set `HIMEM:` itself).
- `& MPLAY "!tune"` compiles the tune and plays it. `& MPLAY "NAME"` plays the `.MBF` file NAME
  from the disk catalog. The file is read straight through DOS's RWTS while it plays (a ring of 2 KB
  or the size you set, refilled from the disk), so it works typed at the prompt too, a song can be as big as the
  disk, and a type B or T file both work. The argument can be any string expression, such as
  `A$`. A tune can be up to 255 characters (an Applesoft string), and the compiled song at most
  one page less than the ring (1,792 bytes after `BRUN`, 3,840 after `& MPLAY 8`); a longer one is cut off and silenced.
  `tune2mbf.py --ring-slots n` cuts at the same place.
- `& MPLAY "NAME",1` starts the song again when it ends (a key stops it). `,2` makes a key other
  than ESC or Q play a short blip over the music instead of stopping it (the tests use it).
- Playing blocks the program until the song ends or a key is pressed (the key is consumed).
- Errors are DOS's own, so `ONERR GOTO` works: `I/O ERROR` (a disk error, or no Mockingboard),
  `FILE NOT FOUND`, `FILE TYPE MISMATCH` (the file is not an MBF1 song). Any other
  `&` word is passed on to the routine that was on the vector before.
- Memory: `$7100-$89FF` (more with a bigger ring; see `ADDON_MEMORY.md`), so it runs on a plain DOS 3.3 disk and on the
  K-HANGEUL / KBASIC disk. Zero page `$06-$09`, `$EB-$EF` and `$FA-$FE`.

The 6502 compiler (`mb_tune.s`) and the Python one (`tune2mbf.py`) are the same algorithm in
integer arithmetic; `src\mb_basic\test\run_basic_tests.bat` checks in MAME that the Apple II
builds exactly the bytes Python builds, and that its AY register writes match.
