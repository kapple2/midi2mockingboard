#!/usr/bin/env python3
"""Build a bootable DOS 3.3 disk that plays .MBF songs on an Apple II Mockingboard.

The disk starts as a copy of dos33blank.dsk (the original is never changed) and gets:
  MPLAY     the resident player: BRUN MPLAY installs the & MPLAY command (build it with
            src/mb_basic/build.bat)
  HELLO     an Applesoft menu that plays the chosen song with & MPLAY
  DEMO, PLAYMBF   example programs that use & MPLAY
  songs     ordinary DOS files named <TITLE>.MBF, so CATALOG lists them

With --base the songs and MPLAY go onto an existing disk instead (for example the KBASIC disk)
and the example programs are left out except PLAYMBF, which that disk does not have.

Each song is written straight into the disk image as a DOS 3.3 text (T) file, because the
sectors are placed on purpose: on every track in the order 0,14,13,...,8,7,6,...,1,15, which
makes the drive deliver them with the least waiting when MPLAY reads a file front to back
(see mb_stream.s). A text file cannot be BLOADed by mistake, and a song can be as big as the disk.
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
MPLAY_BIN = os.path.join(HERE, "..", "mb_basic", "build", "MPLAY.bin")
MPLAY_LBL = os.path.join(HERE, "..", "mb_basic", "build", "MPLAY.lbl")
DISK_DIR = os.path.join(HERE, "..", "dist")      # all disk images made by this project go here
ACX = os.environ.get("ACX", r"C:\bin\acx.exe")

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


def mplay_address():
    """Load address of MPLAY: the label `install` in the link map (the first byte of the file)."""
    for line in open(MPLAY_LBL):
        m = re.match(r"al ([0-9A-Fa-f]+) \.install$", line.strip())
        if m:
            return int(m.group(1), 16)
    sys.exit(f"no label `install` in {MPLAY_LBL}")


def menu_program(songs):
    """HELLO. songs: list of file names. BRUN MPLAY comes first: it needs the string space empty."""
    lines = [
        '10 PRINT CHR$ (4);"BRUN MPLAY"',
        '30 HOME : PRINT "MOCKINGBOARD MUSIC": PRINT',
        "40 RESTORE : READ N",
        '50 FOR I = 1 TO N: READ F$: PRINT I;". ";F$: NEXT I',
        '60 PRINT : INPUT "SONG (0 = QUIT) ";K',
        "70 IF K < 1 OR K > N THEN END",
        "80 RESTORE : READ N: FOR I = 1 TO K: READ F$: NEXT I",
        '90 PRINT "PLAYING ";F$;" (ANY KEY STOPS IT)"',
        "100 & MPLAY F$",
        '110 PRINT : PRINT "PRESS A KEY": GET A$: GOTO 30',
        "1000 DATA " + str(len(songs)),
    ]
    for i, name in enumerate(songs):
        lines.append(f'{1010 + i * 10} DATA "{name}"')
    return "\r".join(lines) + "\r"


def demo_program():
    """DEMO: plays a tune written as text with & MPLAY."""
    lines = [
        '10 PRINT CHR$ (4);"BRUN MPLAY"',
        '40 PRINT "PLAYING A TUNE (ANY KEY STOPS IT)"',
        '50 A$ = "!T120 O4 L4 CCGGAAG2 FFEEDDC2 GGFFEED2 GGFFEED2 CCGGAAG2 FFEEDDC2"',
        '60 A$ = A$ + " / O3 L2 CGFC GCFC GCFC GCFC"',
        "70 & MPLAY A$",
    ]
    return "\r".join(lines) + "\r"


def playmbf_program():
    """PLAYMBF: asks for the name of an .MBF file on the disk and plays it with & MPLAY."""
    lines = [
        '10 PRINT CHR$ (4);"BRUN MPLAY"',
        '40 PRINT "TYPE A NAME FROM CATALOG"',
        '50 INPUT "MBF FILE NAME? ";F$',
        '60 PRINT "PLAYING ";F$;" (ANY KEY STOPS IT)"',
        "70 & MPLAY F$",
        '80 PRINT "DONE"',
    ]
    return "\r".join(lines) + "\r"


def catalog_names(dsk):
    """The file names in the catalog of a DOS 3.3 image, in catalog order (a name may appear twice)."""
    names = []
    for line in acx("-ll", dsk).splitlines():
        m = re.match(r"^\s*[A-Z]\s+(.+?)\s+[\d,]+\s+\d{3}\s+T\d+ S\d+", line)
        if m:
            names.append(m.group(1))
    return names


def remove_existing(dsk, names):
    """Delete every catalog entry called one of `names`: a disk that already holds an older MPLAY (or the
    same songs) would otherwise end up with two files of one name, and DOS runs the first one."""
    wanted = set(names)
    for _ in range(100):
        old = [n for n in catalog_names(dsk) if n in wanted]
        if not old:
            return
        acx("-d", dsk, old[0])
    sys.exit("could not clear the old files from " + dsk)


def main():
    parser = argparse.ArgumentParser(description="Build a Mockingboard player disk")
    parser.add_argument("dsk", help="output .dsk file; a bare name is created in src/dist")
    parser.add_argument("songs", nargs="+", help=".MBF files, or folders containing them")
    parser.add_argument("--base", help="start from this disk instead of a blank DOS 3.3 disk "
                                       "(only MPLAY, PLAYMBF and the songs are added)")
    args = parser.parse_args()

    if not os.path.dirname(args.dsk):
        args.dsk = os.path.join(DISK_DIR, args.dsk)
    base = args.base or BLANK_DISK
    for path, build in ((base, None), (ACX, None), (MPLAY_BIN, "src\\mb_basic\\build.bat")):
        if not os.path.exists(path):
            sys.exit(f"missing: {path}" + (f"  (run {build} first)" if build else ""))

    # What goes on the disk: name and bytes of every song that a DOS file can hold
    used, songs = set(), []
    for path in collect(args.songs):
        data = open(path, "rb").read()
        name = dos_name(path, used)
        if len(data) <= 0xFFFF:
            songs.append((name, data, path))
        else:
            print(f"left out {os.path.basename(path)}: {len(data)} bytes, more than a DOS file can hold")
    if not songs:
        sys.exit("no songs")

    os.makedirs(os.path.dirname(os.path.abspath(args.dsk)), exist_ok=True)
    shutil.copyfile(base, args.dsk)
    if args.base:       # replace older copies of our files that the base disk may already hold
        remove_existing(args.dsk, ["MPLAY", "PLAYMBF"] + [name for name, _, _ in songs])
    acx("-p", args.dsk, "MPLAY", "B", hex(mplay_address()), stdin_path=MPLAY_BIN)
    acx("-bas", args.dsk, "PLAYMBF", stdin_text=playmbf_program())
    if not args.base:
        acx("-bas", args.dsk, "HELLO", stdin_text=menu_program([name for name, _, _ in songs]))
        acx("-bas", args.dsk, "DEMO", stdin_text=demo_program())

    image = Image(open(args.dsk, "rb").read())
    placed = []
    for name, data, path in songs:
        if image.add_file(name, TYPE_TEXT, data) is None:
            print(f"left out {os.path.basename(path)}: {len(data)} bytes do not fit in the free sectors left")
        else:
            placed.append((name, data))
    with open(args.dsk, "wb") as f:
        f.write(image.d)

    print(acx("-ll", args.dsk))
    for number, (name, data) in enumerate(placed, 1):
        print(f"  {number:2d}. {name}  ({len(data)} bytes, {-(-len(data) // 256)} sectors)")


if __name__ == "__main__":
    main()
