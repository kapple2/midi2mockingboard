#!/usr/bin/env python3
"""Build a bootable DOS 3.3 disk that plays .MBF songs on an Apple II Mockingboard.

The disk starts as a copy of dos33blank.dsk (the original is never changed) and gets:
  MBPLAY    the 6502 player, loaded at $8E00 (build it with src/mb_apple2/build.bat)
  MPLAY     the & MPLAY command (build it with src/mb_basic/build.bat)
  HELLO     an Applesoft menu that starts MBPLAY on the chosen song
  DEMO, PLAYMBF   example programs that use & MPLAY
  songs     ordinary DOS files named <TITLE>.MBF, so CATALOG lists them

Each song is written straight into the disk image as a DOS 3.3 file (a catalog entry, track/
sector lists and data sectors), because the sectors are placed on purpose: on every track in
the order 0,14,13,...,8,7,6,...,1,15, which makes the drive deliver them with the least
waiting when MBPLAY reads a file front to back (see mb_stream.s).
A song of up to 8,448 bytes is a binary (B) file, so & MPLAY "NAME" can load it too. A bigger
one is a text (T) file: DOS refuses to BLOAD it, and only MBPLAY plays it (load if it fits in
28 KB, otherwise stream).
"""
import argparse
import os
import re
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BLANK_DISK = os.path.join(HERE, "dos33blank.dsk")   # blank DOS 3.3 disk, never modified
PLAYER_BIN = os.path.join(ROOT, "src", "mb_apple2", "build", "MBPLAY.bin")
MPLAY_BIN = os.path.join(ROOT, "src", "mb_basic", "build", "MPLAY.bin")
DISK_DIR = os.path.join(ROOT, "src", "disk")     # all disk images made by this project go here
ACX = os.environ.get("ACX", r"C:\bin\acx.exe")

PLAYER_ADDR = 0x8E00
MPLAY_ADDR = 0x8C00         # the Applesoft & MPLAY command
MPLAY_SONG_ADDR = 0x6000    # where & MPLAY "FILE" loads an .MBF file; it holds 8,448 bytes
MPLAY_FILE_MAX = 0x8100 - MPLAY_SONG_ADDR   # the byte after it is the player's variables
LOAD_MAX_SECTORS = 7 * 16   # MBPLAY can load at most 7 slots of 16 sectors into RAM
NAME_BYTES = 30
TRACKS = 35
VTOC_TRACK = 17
FIRST_DATA_TRACK = 3        # tracks 0-2 are DOS
VTOC_OFFSET = (VTOC_TRACK * 16) * 256
VTOC_BITMAP = 0x38          # four bytes per track; byte 0 holds sectors 15-8, byte 1 sectors 7-0
LIST_PAIRS = 122
TYPE_BINARY, TYPE_TEXT = 0x04, 0x00
# The logical sectors in the order that visits the physical sectors 0,2,4,...,14,1,3,...,15
SECTOR_ORDER = [0, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 15]


def acx(*args, stdin_path=None, stdin_text=None):
    """Run AppleCommander; stdin comes from a file or a string."""
    stdin = open(stdin_path, "rb") if stdin_path else None
    try:
        result = subprocess.run([ACX, *args], stdin=stdin, input=None if stdin else stdin_text,
                                capture_output=True, text=stdin is None)
    finally:
        if stdin:
            stdin.close()
    if result.returncode != 0:
        raise RuntimeError(f"acx {' '.join(args)} failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def dos_name(path, used):
    """A DOS 3.3 file name (at most 30 characters) for a song: its title in capitals plus .MBF."""
    stem = os.path.splitext(os.path.basename(path))[0].upper()
    stem = re.sub(r"[^A-Z0-9 .-]", "", stem)
    stem = re.sub(r" +", " ", stem).strip()[:NAME_BYTES - 4].strip() or "SONG"
    name, n = stem + ".MBF", 2
    while name in used:
        name = stem[:NAME_BYTES - 6] + f" {n}.MBF"
        n += 1
    used.add(name)
    return name


def collect(inputs):
    files = []
    for item in inputs:
        if os.path.isdir(item):
            files += sorted((os.path.join(item, n) for n in os.listdir(item) if n.upper().endswith(".MBF")),
                            key=lambda p: os.path.basename(p).lower())
        else:
            files.append(item)
    return files


class Image:
    """A DOS-order 140 KB disk image: sector (t, s) is at (t * 16 + s) * 256."""

    def __init__(self, data):
        self.d = bytearray(data)

    def sector(self, t, s):
        o = (t * 16 + s) * 256
        return self.d[o:o + 256]

    def put(self, t, s, data):
        o = (t * 16 + s) * 256
        self.d[o:o + 256] = data.ljust(256, b"\0")

    def _bit(self, t, s):
        entry = VTOC_OFFSET + VTOC_BITMAP + 4 * t
        return (entry, 1 << (s - 8)) if s >= 8 else (entry + 1, 1 << s)

    def is_free(self, t, s):
        byte, mask = self._bit(t, s)
        return bool(self.d[byte] & mask)

    def use(self, t, s):
        byte, mask = self._bit(t, s)
        self.d[byte] &= ~mask & 0xFF

    def free_in_stream_order(self):
        """Free sectors, track by track (skipping the VTOC track), each track in SECTOR_ORDER."""
        return [(t, s) for t in range(FIRST_DATA_TRACK, TRACKS) if t != VTOC_TRACK
                for s in SECTOR_ORDER if self.is_free(t, s)]

    def free_catalog_entry(self):
        t, s = self.sector(VTOC_TRACK, 0)[1], self.sector(VTOC_TRACK, 0)[2]
        while t:
            sec = self.sector(t, s)
            for i in range(7):
                if sec[11 + 35 * i] in (0, 0xFF):
                    return t, s, 11 + 35 * i
            t, s = sec[1], sec[2]
        sys.exit("the catalog is full")

    def add_file(self, name, ftype, payload):
        """Write a file with its sectors in streaming order and add it to the catalog."""
        nsec = -(-len(payload) // 256)
        nlists = -(-nsec // LIST_PAIRS)
        pool = self.free_in_stream_order()
        if len(pool) < nsec + nlists:
            return None
        # each track/sector list sits just before the 122 data sectors it names, so that reading
        # the file front to back finds the next list in its turn instead of seeking back to it
        lists, data, i = [], [], 0
        while len(data) < nsec:
            lists.append(pool[i])
            take = min(LIST_PAIRS, nsec - len(data))
            data += pool[i + 1:i + 1 + take]
            i += 1 + take
        for t, s in lists + data:
            self.use(t, s)
        for k, (t, s) in enumerate(lists):
            chunk = data[k * LIST_PAIRS:(k + 1) * LIST_PAIRS]
            ts = bytearray(256)
            if k + 1 < nlists:
                ts[1], ts[2] = lists[k + 1]
            ts[5:7] = struct.pack("<H", k * LIST_PAIRS)
            for j, (dt, dsec) in enumerate(chunk):
                ts[12 + 2 * j], ts[13 + 2 * j] = dt, dsec
            self.put(t, s, bytes(ts))
        for i, (t, s) in enumerate(data):
            self.put(t, s, payload[i * 256:(i + 1) * 256])
        ct, cs, off = self.free_catalog_entry()
        sec = self.sector(ct, cs)
        entry = bytearray(35)
        entry[0], entry[1] = lists[0]
        entry[2] = ftype
        entry[3:33] = bytes((ord(c) | 0x80) for c in name.ljust(NAME_BYTES))
        entry[33:35] = struct.pack("<H", nsec + nlists)
        sec[off:off + 35] = entry
        self.put(ct, cs, bytes(sec))
        return nsec


def menu_program(songs):
    """HELLO. songs: list of (file name, sectors). The player is told the file name at $0300."""
    lines = [
        f"10 HIMEM: {PLAYER_ADDR}",
        "20 D$ = CHR$ (4)",
        '30 HOME : PRINT "MOCKINGBOARD MUSIC": PRINT',
        "40 RESTORE : READ N",
        '50 FOR I = 1 TO N: READ F$,S: PRINT I;". ";F$: NEXT I',
        '60 PRINT : INPUT "SONG (0 = QUIT) ";K',
        "70 IF K < 1 OR K > N THEN END",
        "80 RESTORE : READ N: FOR I = 1 TO K: READ F$,S: NEXT I",
        "90 M = 1",
        f'100 IF S <= {LOAD_MAX_SECTORS} THEN PRINT "L)OAD OR S)TREAM? ";: GET A$: PRINT A$: M = (A$ = "S")',
        '110 PRINT D$;"BLOAD MBPLAY"',
        "115 FOR I = 1 TO LEN (F$): POKE 767 + I, ASC ( MID$ (F$,I,1)): NEXT I",
        f"120 POKE 6,M: POKE 7, LEN (F$): POKE 9,0: CALL {PLAYER_ADDR}",
        '130 PRINT : PRINT "PRESS A KEY": GET A$: GOTO 30',
        "1000 DATA " + str(len(songs)),
    ]
    for i, (name, sectors) in enumerate(songs):
        lines.append(f'{1010 + i * 10} DATA "{name}",{sectors}')
    return "\r".join(lines) + "\r"


def demo_program():
    """DEMO: plays a tune written as text with & MPLAY."""
    lines = [
        "10 HIMEM: 24576",
        '20 PRINT CHR$ (4);"BLOAD MPLAY"',
        f"30 CALL {MPLAY_ADDR}",
        '40 PRINT "PLAYING A TUNE (ANY KEY STOPS IT)"',
        '50 A$ = "!T120 O4 L4 CCGGAAG2 FFEEDDC2 GGFFEED2 GGFFEED2 CCGGAAG2 FFEEDDC2"',
        '60 A$ = A$ + " / O3 L2 CGFC GCFC GCFC GCFC"',
        "70 & MPLAY A$",
    ]
    return "\r".join(lines) + "\r"


def playmbf_program():
    """PLAYMBF: asks for the name of a small .MBF file on the disk and plays it with & MPLAY."""
    lines = [
        "10 HIMEM: 24576",
        '20 PRINT CHR$ (4);"BLOAD MPLAY"',
        f"30 CALL {MPLAY_ADDR}",
        '40 PRINT "TYPE A NAME FROM CATALOG (A B FILE UP TO 8 KB)"',
        '50 INPUT "MBF FILE NAME? ";F$',
        '60 PRINT "PLAYING ";F$;" (ANY KEY STOPS IT)"',
        "70 & MPLAY F$",
        '80 PRINT "DONE"',
    ]
    return "\r".join(lines) + "\r"


def main():
    parser = argparse.ArgumentParser(description="Build a Mockingboard player disk")
    parser.add_argument("dsk", help="output .dsk file; a bare name is created in src/disk")
    parser.add_argument("songs", nargs="+", help=".MBF files, or folders containing them")
    args = parser.parse_args()

    if not os.path.dirname(args.dsk):
        args.dsk = os.path.join(DISK_DIR, args.dsk)
    for path, build in ((BLANK_DISK, None), (ACX, None), (PLAYER_BIN, "src\\mb_apple2\\build.bat"),
                        (MPLAY_BIN, "src\\mb_basic\\build.bat")):
        if not os.path.exists(path):
            sys.exit(f"missing: {path}" + (f"  (run {build} first)" if build else ""))

    # What goes on the disk: name, type and bytes of every song that is not too long for a file
    used, songs = set(), []
    for path in collect(args.songs):
        data = open(path, "rb").read()
        name = dos_name(path, used)
        if len(data) <= MPLAY_FILE_MAX:
            payload = struct.pack("<HH", MPLAY_SONG_ADDR, len(data)) + data      # binary file header
            songs.append((name, TYPE_BINARY, payload, path))
        elif len(data) <= 0xFFFF:
            songs.append((name, TYPE_TEXT, data, path))
        else:
            print(f"left out {os.path.basename(path)}: {len(data)} bytes, more than a DOS file can hold")
    if not songs:
        sys.exit("no songs")

    os.makedirs(os.path.dirname(os.path.abspath(args.dsk)), exist_ok=True)
    shutil.copyfile(BLANK_DISK, args.dsk)
    menu = menu_program([(name, -(-len(payload) // 256)) for name, _, payload, _ in songs])
    acx("-p", args.dsk, "MBPLAY", "B", hex(PLAYER_ADDR), stdin_path=PLAYER_BIN)
    acx("-p", args.dsk, "MPLAY", "B", hex(MPLAY_ADDR), stdin_path=MPLAY_BIN)
    acx("-bas", args.dsk, "HELLO", stdin_text=menu)
    acx("-bas", args.dsk, "DEMO", stdin_text=demo_program())
    acx("-bas", args.dsk, "PLAYMBF", stdin_text=playmbf_program())

    image = Image(open(args.dsk, "rb").read())
    for name, ftype, payload, path in songs:
        if image.add_file(name, ftype, payload) is None:
            print(f"left out {os.path.basename(path)}: {len(payload)} bytes do not fit in the free sectors left")
    with open(args.dsk, "wb") as f:
        f.write(image.d)

    print(acx("-ll", args.dsk))
    for number, (name, ftype, payload, path) in enumerate(songs, 1):
        sectors = -(-len(payload) // 256)
        mode = "load or stream" if sectors <= LOAD_MAX_SECTORS else "stream only"
        kind = "also & MPLAY" if ftype == TYPE_BINARY else "MBPLAY only"
        print(f"  {number:2d}. {name}  ({len(payload)} bytes, {sectors} sectors, {mode}, {kind})")


if __name__ == "__main__":
    main()
