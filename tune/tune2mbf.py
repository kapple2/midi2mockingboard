#!/usr/bin/env python3
"""Compile a text tune into a Mockingboard .MBF file.

This is the reference for the Apple II's `&MPLAY "!tune"`: the 6502 code in src/mb_basic
must produce exactly the same bytes, so everything here is integer arithmetic.

A tune is up to 6 voices separated by "/". Voice 1-3 play on chip 1 channels A-C, voice
4-6 on chip 2 channels A-C. Every voice starts with T120 L4 O4 V12. Spaces are ignored.

  C D E F G A B   a note, then "#" or "+" (sharp) or "-" (flat), then a length, then dots
  R               a rest (length and dots as for a note)
  L<n>            default length: 1 whole, 2 half, 4 quarter, 8 eighth ... up to 64
  O<n>            octave 0-7; C in octave 4 is middle C (261.6 Hz)
  < >             one octave down / up
  T<n>            tempo in quarter notes per minute, 32-255 (applies to this voice)
  V<n>            volume 0-15

Example: "T100 O4 L8 CDEFG4 / O3 C2 G2"
"""
import argparse
import os
import struct
import sys

AY_CLOCK = 1_022_727
RATE = 50                       # ticks per second
WHOLE_TICKS = 60 * RATE * 4     # ticks in a whole note at 1 quarter note per minute
# Tone period of C0..B0; the other octaves halve it (rounding half up)
BASE_PERIODS = [round(AY_CLOCK / (16.0 * 16.3516 * 2 ** (n / 12.0))) for n in range(12)]
NOTE_SEMITONES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
MAX_VOICES = 6
DEFAULT_SLOTS = 4               # the Apple II compiles into its ring: 4 slots of 512 bytes after BRUN MPLAY
SLOT_BYTES = 512
MAX_BYTES = (DEFAULT_SLOTS * SLOT_BYTES // 256 - 1) * 256   # it stops starting frames on the ring's last page: 1,792
MIXER_TONES = 0x38


def period_of(octave, semitone):
    """AY tone period of a note; semitone may be -1 (flat C) or 12 (sharp B)."""
    n = max(octave * 12 + semitone, 0)
    octave, semitone = divmod(n, 12)
    base = BASE_PERIODS[semitone]
    if octave == 0:
        return base
    return (base >> octave) + ((base >> (octave - 1)) & 1)


class Voice:
    def __init__(self, text, index):
        self.text = text
        self.pos = 0
        self.chip, self.channel = divmod(index, 3)
        self.tempo_whole = WHOLE_TICKS // 120
        self.length = 4
        self.octave = 4
        self.volume = 12
        self.left = 0           # ticks left in the current note
        self.gap = False        # the note's last tick is silent
        self.done = False

    def number(self):
        """Read a decimal number at the current position, or None if there is none."""
        value, found = 0, False
        while self.pos < len(self.text) and self.text[self.pos].isdigit():
            value = (value * 10 + int(self.text[self.pos])) & 0xFF
            self.pos += 1
            found = True
        return value if found else None

    def ticks(self):
        length = self.number()
        if length is None:
            length = self.length
        length = min(max(length, 1), 64)
        ticks = max(self.tempo_whole // length, 1)
        extra = ticks
        while self.pos < len(self.text) and self.text[self.pos] == ".":
            self.pos += 1
            extra //= 2
            ticks += extra
        return ticks

    def next_event(self):
        """Parse up to the next note or rest. Returns ('note', period, ticks), ('rest', ticks) or None."""
        while self.pos < len(self.text):
            c = self.text[self.pos]
            self.pos += 1
            if c in NOTE_SEMITONES:
                semitone = NOTE_SEMITONES[c]
                if self.pos < len(self.text) and self.text[self.pos] in "#+":
                    semitone += 1
                    self.pos += 1
                elif self.pos < len(self.text) and self.text[self.pos] == "-":
                    semitone -= 1
                    self.pos += 1
                ticks = self.ticks()
                return ("note", period_of(self.octave, semitone), ticks)
            if c == "R":
                return ("rest", self.ticks())
            if c == "L":
                value = self.number()
                if value is not None:
                    self.length = min(max(value, 1), 64)
            elif c == "O":
                value = self.number()
                if value is not None:
                    self.octave = min(value, 7)
            elif c == "T":
                value = self.number()
                if value is not None:
                    self.tempo_whole = WHOLE_TICKS // min(max(value, 32), 255)
            elif c == "V":
                value = self.number()
                if value is not None:
                    self.volume = min(value, 15)
            elif c == "<":
                self.octave = max(self.octave - 1, 0)
            elif c == ">":
                self.octave = min(self.octave + 1, 7)
        return None

    def tick(self):
        """Register writes (chip, reg, value) for this tick."""
        base = 2 * self.channel
        volume_reg = 8 + self.channel
        writes = []
        if self.left == 0:
            event = self.next_event()
            if event is None:
                self.done = True
                return [(self.chip, volume_reg, 0)]
            if event[0] == "note":
                _, period, ticks = event
                writes = [(self.chip, base, period & 0xFF), (self.chip, base + 1, period >> 8),
                          (self.chip, volume_reg, self.volume)]
                self.gap = ticks >= 3
            else:
                ticks = event[1]
                writes = [(self.chip, volume_reg, 0)]
                self.gap = False
            self.left = ticks
        elif self.left == 1 and self.gap:
            writes = [(self.chip, volume_reg, 0)]
        self.left -= 1
        return writes


def keyframe():
    writes = []
    for chip in range(2):
        for reg in range(11):
            writes.append((chip, reg, MIXER_TONES if reg == 7 else 0))
    return writes


def compile_tune(text, max_bytes=MAX_BYTES):
    """Return the .MBF bytes for a tune text. max_bytes is the size the Apple II has room for: with a ring of
    n slots (& MPLAY n) that is (2 * n - 1) * 256."""
    parts = [p for p in text.upper().split("/")][:MAX_VOICES]
    voices = [Voice(p, i) for i, p in enumerate(parts)]
    out = bytearray(struct.pack("<4sHBB", b"MBF1", RATE, 0, 0))
    first = True
    while True:
        if len(out) >= max_bytes:       # too long for the Apple II buffer: silence everything and stop
            out.append(6)
            for chip in range(2):
                for reg in (8, 9, 10):
                    out += bytes([(chip << 4) | reg, 0])
            break
        writes = keyframe() if first else []
        first = False
        for voice in voices:
            if not voice.done:
                writes += voice.tick()
        out.append(len(writes))
        for chip, reg, value in writes:
            out += bytes([(chip << 4) | reg, value])
        if all(v.done for v in voices):
            break
    out.append(0xFF)
    return bytes(out)


def main():
    parser = argparse.ArgumentParser(description="Compile a text tune into a Mockingboard .MBF file")
    parser.add_argument("tune", nargs="+", help="the tune text, or a text file holding it with -f")
    parser.add_argument("-f", "--file", action="store_true", help="the argument is a text file with the tune")
    parser.add_argument("-o", "--out", default="tune.MBF", help="output .MBF file (default tune.MBF)")
    parser.add_argument("--ring-slots", type=int, default=DEFAULT_SLOTS,
                        help="the Apple II ring size (& MPLAY n) the tune must fit in, in slots of 512 bytes "
                             "(default 4: a tune up to 1,792 bytes; longer ones are cut off and silenced like on the Apple II)")
    args = parser.parse_args()

    text = " ".join(args.tune)
    if args.file:
        with open(text, encoding="utf-8") as f:
            text = " ".join(f.read().split())
    data = compile_tune(text, (args.ring_slots * SLOT_BYTES // 256 - 1) * 256)
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"{args.out}: {len(data)} bytes")


if __name__ == "__main__":
    sys.exit(main())
