#!/usr/bin/env python3
"""Convert a Type 0/1 MIDI file into a Mockingboard register stream.

Writes two files that hold the same data:
  <out>.MBF  binary stream for the Apple II and Windows players
  <out>.txt  text dump of the same stream, for inspection and diffs

MBF layout (little-endian):
  Header (8 bytes): 'MBF1', tick rate (u16), loop flag (u8), reserved (u8)
  Frames: one per tick. Each frame is a count byte N, then N pairs of
          [chip << 4 | register, value]. Chip 0 is the first AY-3-8910,
          chip 1 is the second. Count 0 means no change this tick.
          A count byte of 0x80 + n (n = 1-126) stands for n such empty ticks in a row.
  End:    count byte 0xFF. With the loop flag set the player restarts at
          the first frame, which is a full keyframe.
"""
import argparse
import os
import struct
from dataclasses import dataclass

import mido

AY_CLOCK = 1_022_727   # Apple II Mockingboard AY clock (Hz)
VOICES = 6             # 2 chips x 3 square-wave tone channels
CHIPS = 2
DRUM_CHANNEL = 9       # MIDI channel 10 (0-based 9) is percussion
NOISE_REG = 6          # noise period, shared by the three channels of a chip
MIXER_REG = 7          # bits 0-2 switch tones off, bits 3-5 switch noise off, per channel
MIXER_TONES = 0x38     # tone on, noise off for all three channels
STREAM_REGS = 11       # registers 0-10 carry tone, noise, mixer and volume
END_OF_STREAM = 0xFF
EMPTY_RUN_BASE = 0x80  # count byte 0x80 + n (1-126): n ticks with no register changes
MAX_EMPTY_RUN = 0x7E
MAGIC = b"MBF1"

# Output level of the AY-3-8910 for volume register 0-15 (same table as the Windows player).
AY_LEVELS = [0.0, 0.0100, 0.0145, 0.0211, 0.0307, 0.0455, 0.0645, 0.1073,
             0.1266, 0.2050, 0.2922, 0.3728, 0.4925, 0.6353, 0.8055, 1.0]

# General MIDI percussion on the AY noise generator:
# note -> (noise period 1-31, length in ticks at 50 Hz, priority against melody notes)
DRUMS = {
    35: (31, 6, 70), 36: (31, 6, 70),                                    # bass drum
    37: (10, 3, 60), 39: (10, 3, 60),                                    # side stick, clap
    38: (12, 7, 70), 40: (12, 7, 70),                                    # snare
    41: (26, 7, 60), 43: (24, 7, 60), 45: (21, 7, 60),                   # toms
    47: (18, 7, 60), 48: (16, 7, 60), 50: (14, 7, 60),
    42: (4, 2, 50), 44: (4, 2, 50), 46: (5, 9, 50),                      # hi-hats
    49: (7, 16, 55), 52: (7, 16, 55), 55: (7, 16, 55), 57: (7, 16, 55),  # cymbals
    51: (6, 7, 55), 53: (6, 7, 55), 59: (6, 7, 55),                      # ride
}
DRUM_OTHER = (16, 3, 50)


def level_to_register(level):
    """The AY volume register (1-15) whose output level is closest to `level` (0 = silent)."""
    if level <= 0:
        return 0
    return min(range(1, 16), key=lambda reg: abs(AY_LEVELS[reg] - level))


@dataclass
class Voice:
    channel: int = -1
    note: int = -1
    velocity: int = 0
    started: int = 0
    ends: int = 0           # tick where the note is released (known from a look-ahead)
    active: bool = False
    drum: bool = False      # playing a percussion hit on the noise generator
    noise: int = 0
    length: int = 1         # drum length in ticks
    left: int = 0           # drum ticks still to play
    priority: int = 0       # drum priority (stands in for the pitch)


class ChannelState:
    def __init__(self):
        self.bend = 0          # pitch wheel, -8192..8191
        self.volume = 127      # CC7
        self.expression = 127  # CC11


class Converter:
    def __init__(self, rate, bend_range, loop, steal="priority", gain=1.0, drums=True, drum_cut=None):
        self.rate = rate
        self.drum_cut = drum_cut   # ticks of a melody note a drum hit may cut short
        self.note_ends = {}
        self.bend_range = bend_range
        self.loop = loop
        self.steal = steal
        self.gain = gain       # scales every note's level (see peak)
        self.drums = drums
        self.peak = 0.0        # loudest level any voice asked for, before the gain
        self.steals = 0    # note-ons that found every voice busy
        self.dropped = 0   # of those, new notes discarded instead of stealing
        self.hits = 0      # drum hits seen
        self.hits_dropped = 0
        self.voices = [Voice() for _ in range(VOICES)]
        self.channels = [ChannelState() for _ in range(16)]
        self.shadow = [[0] * STREAM_REGS for _ in range(CHIPS)]
        self.frames = []

    def convert(self, mid):
        # mido yields each message with its delta time in seconds, merged
        # across all tracks, so accumulate to absolute time first.
        timed = []
        now = 0.0
        for msg in mid:
            now += msg.time
            timed.append((now, msg))

        # Quantize each event to the tick it falls on.
        by_tick = {}
        for when, msg in timed:
            tick = round(when * self.rate)
            by_tick.setdefault(tick, []).append(msg)

        last_tick = max(by_tick) if by_tick else 0
        self._find_note_ends(by_tick, last_tick)
        for tick in range(last_tick + 1):
            for msg in by_tick.get(tick, []):
                self._handle(tick, msg)
            self.frames.append(self._render(keyframe=(tick == 0)))

        # Silence every voice on the last tick so the song ends quietly.
        for voice in self.voices:
            voice.active = False
        self.frames.append(self._render(keyframe=False))

    def _find_note_ends(self, by_tick, last_tick):
        """Look ahead: the tick where each note (channel, note, start tick) is released."""
        pending = {}                    # (channel, note) -> start ticks of the notes still held
        for tick in range(last_tick + 1):
            for msg in by_tick.get(tick, []):
                if msg.type not in ("note_on", "note_off", "control_change") or \
                        (msg.type != "control_change" and msg.channel == DRUM_CHANNEL):
                    continue
                if msg.type == "note_on" and msg.velocity > 0:
                    pending.setdefault((msg.channel, msg.note), []).append(tick)
                elif msg.type == "control_change":
                    if msg.control in (120, 123):
                        for (channel, note), starts in pending.items():
                            if channel == msg.channel:
                                for start in starts:
                                    self.note_ends[(channel, note, start)] = tick
                                starts.clear()
                else:
                    starts = pending.get((msg.channel, msg.note))
                    if starts:
                        self.note_ends[(msg.channel, msg.note, starts.pop(0))] = tick
        for (channel, note), starts in pending.items():
            for start in starts:
                self.note_ends[(channel, note, start)] = last_tick

    def _remaining(self, voice, tick):
        """Ticks the voice has left to play."""
        return voice.left if voice.drum else voice.ends - tick

    def _handle(self, tick, msg):
        if msg.type == "note_on" and msg.velocity > 0 and msg.channel == DRUM_CHANNEL:
            if self.drums:
                self._drum_on(tick, msg.note, msg.velocity)
        elif msg.type == "note_on" and msg.velocity > 0:
            self._note_on(tick, msg.channel, msg.note, msg.velocity)
        elif msg.type in ("note_off", "note_on") and msg.channel != DRUM_CHANNEL:
            self._note_off(msg.channel, msg.note)
        elif msg.type == "pitchwheel":
            self.channels[msg.channel].bend = msg.pitch
        elif msg.type == "control_change":
            state = self.channels[msg.channel]
            if msg.control == 7:
                state.volume = msg.value
            elif msg.control == 11:
                state.expression = msg.value
            elif msg.control in (120, 123):  # all sound off / all notes off
                self._release_channel(msg.channel)

    def _note_on(self, tick, channel, note, velocity):
        # Retrigger a voice already playing this note.
        for voice in self.voices:
            if voice.active and voice.channel == channel and voice.note == note:
                voice.velocity = velocity
                voice.started = tick
                voice.ends = self.note_ends.get((channel, note, tick), tick)
                return

        free = next((v for v in self.voices if not v.active), None)
        if free is None:
            self.steals += 1
            if self.steal == "oldest":
                free = min(self.voices, key=lambda v: v.started)
            else:
                victim = min(self.voices, key=lambda v: self._voice_priority(v, tick))
                if self._priority(note, velocity, tick, tick) < self._voice_priority(victim, tick):
                    self.dropped += 1
                    return
                free = victim
        free.drum = False
        free.channel = channel
        free.note = note
        free.velocity = velocity
        free.started = tick
        free.ends = self.note_ends.get((channel, note, tick), tick)
        free.active = True

    def _drum_on(self, tick, note, velocity):
        """Give a percussion hit a voice for a few ticks; melody notes can lose their voice to it."""
        self.hits += 1
        noise, length, priority = DRUMS.get(note, DRUM_OTHER)
        free = next((v for v in self.voices if not v.active), None)
        if free is None:
            if self.drum_cut is None:
                # take the voice that matters least (the same score melody notes steal by)
                free = min(self.voices, key=lambda v: self._voice_priority(v, tick))
            else:
                # --drum-cut: borrow the voice whose note ends soonest; a hit that would cut a
                # longer note short is dropped (cutting melody costs more than a missing drum).
                victim = min(self.voices, key=lambda v: self._remaining(v, tick))
                if self._remaining(victim, tick) > length + self.drum_cut:
                    self.hits_dropped += 1
                    return
                free = victim
        free.channel = DRUM_CHANNEL
        free.note = note
        free.velocity = velocity
        free.started = tick
        free.active = True
        free.drum = True
        free.noise = noise
        free.length = free.left = length
        free.priority = priority

    def _voice_priority(self, voice, tick):
        return self._priority(voice.priority if voice.drum else voice.note, voice.velocity, voice.started, tick)

    def _priority(self, note, velocity, started, tick):
        """Higher pitch and velocity win; held notes lose weight over time."""
        age_seconds = (tick - started) / self.rate
        return note + 0.25 * velocity - 2.5 * age_seconds

    def _note_off(self, channel, note):
        for voice in self.voices:
            if voice.active and voice.channel == channel and voice.note == note:
                voice.active = False

    def _release_channel(self, channel):
        for voice in self.voices:
            if voice.active and voice.channel == channel:
                voice.active = False

    def _render(self, keyframe):
        """Compute the registers for one tick and return only the changes."""
        writes = []
        mixer = [MIXER_TONES] * CHIPS
        for index, voice in enumerate(self.voices):
            chip, ch = divmod(index, 3)
            period = None
            volume = 0
            if voice.active:
                state = self.channels[voice.channel]
                level = (voice.velocity / 127.0) * (state.volume / 127.0) * (state.expression / 127.0)
                if voice.drum:
                    level *= voice.left / voice.length      # the hit dies away linearly
                    mixer[chip] = (mixer[chip] | (1 << ch)) & ~(8 << ch)    # noise instead of tone
                    self._set(writes, chip, NOISE_REG, voice.noise, keyframe)
                    voice.left -= 1
                    if voice.left == 0:
                        voice.active = False
                else:
                    semitones = (state.bend / 8192.0) * self.bend_range
                    freq = 440.0 * 2 ** ((voice.note - 69 + semitones) / 12.0)
                    period = max(1, min(0xFFF, round(AY_CLOCK / (16.0 * freq))))
                self.peak = max(self.peak, level)
                volume = level_to_register(level * self.gain)
                if level > 0 and volume == 0:
                    volume = 1

            if period is not None:
                self._set(writes, chip, 2 * ch, period & 0xFF, keyframe)
                self._set(writes, chip, 2 * ch + 1, (period >> 8) & 0x0F, keyframe)
            self._set(writes, chip, 8 + ch, volume, keyframe)

        for chip in range(CHIPS):
            self._set(writes, chip, MIXER_REG, mixer[chip], keyframe)
        return writes

    def _set(self, writes, chip, reg, value, keyframe):
        if keyframe or self.shadow[chip][reg] != value:
            self.shadow[chip][reg] = value
            writes.append((chip, reg, value))

    def to_mbf(self):
        out = bytearray(struct.pack("<4sHBB", MAGIC, self.rate, 1 if self.loop else 0, 0))
        empty = 0
        for writes in self.frames + [None]:
            if writes is not None and not writes:
                empty += 1
                continue
            while empty:                    # a run of empty ticks is one byte: 0x80 + length
                run = min(empty, MAX_EMPTY_RUN)
                out.append(EMPTY_RUN_BASE + run)
                empty -= run
            if writes is None:
                break
            out.append(len(writes))
            for chip, reg, value in writes:
                out += bytes([(chip << 4) | reg, value])
        out.append(END_OF_STREAM)
        return bytes(out)

    def to_text(self, source):
        lines = [
            "# Mockingboard register stream (text dump of .MBF)",
            f"# source={source} rate={self.rate}Hz loop={int(self.loop)} "
            f"frames={len(self.frames)} bend_range={self.bend_range}",
            "# format: <tick> <chip>.<reg>=<hex value> ...  (empty ticks omitted)",
        ]
        for tick, writes in enumerate(self.frames):
            if writes:
                pairs = " ".join(f"{chip}.{reg}={value:02X}" for chip, reg, value in writes)
                lines.append(f"{tick} {pairs}")
        return "\n".join(lines) + "\n"


def convert_file(midi_path, base, rate=50, bend_range=2, loop=False, steal="priority",
                 normalize=True, drums=True, drum_cut=None, write_text=True):
    """Convert a MIDI file to base + ".MBF" (and base + ".txt"). Returns (converter, volume gain)."""
    mid = mido.MidiFile(midi_path)
    gain = 1.0
    if normalize:
        probe = Converter(rate, bend_range, loop, steal, drums=drums, drum_cut=drum_cut)
        probe.convert(mid)              # first pass: find the loudest level
        if probe.peak > 0:
            gain = 1.0 / probe.peak
    conv = Converter(rate, bend_range, loop, steal, gain, drums=drums, drum_cut=drum_cut)
    conv.convert(mid)
    with open(base + ".MBF", "wb") as f:
        f.write(conv.to_mbf())
    if write_text:
        with open(base + ".txt", "w", encoding="utf-8") as f:
            f.write(conv.to_text(os.path.basename(midi_path)))
    return conv, gain


def main():
    parser = argparse.ArgumentParser(description="Convert MIDI to Mockingboard .MBF and .txt")
    parser.add_argument("midi", help="input .mid file (Type 0 or 1)")
    parser.add_argument("-o", "--out", help="output base name without extension (default: input name)")
    parser.add_argument("--rate", type=int, default=50, help="tick rate in Hz (default 50)")
    parser.add_argument("--bend-range", type=int, default=2, help="pitch bend range in semitones (default 2)")
    parser.add_argument("--loop", action="store_true", help="set the loop flag in the header")
    parser.add_argument("--steal", choices=("priority", "oldest"), default="priority",
                        help="voice stealing when all 6 are busy (default priority)")
    parser.add_argument("--no-normalize", action="store_true",
                        help="keep the MIDI levels as they are (default: scale the song so its loudest note is volume 15)")
    parser.add_argument("--no-drums", action="store_true", help="leave out the percussion channel")
    parser.add_argument("--drum-cut", type=int, default=None, metavar="TICKS",
                        help="when all 6 voices are busy a drum hit may cut a melody note short by at most this "
                             "many ticks, otherwise the hit is dropped (default: no limit, the hit takes the "
                             "least important voice)")
    args = parser.parse_args()

    if not 16 <= args.rate <= 255:
        parser.error("--rate must be 16-255 (the Apple II driver's 16-bit timer cannot go slower)")

    base = args.out or os.path.splitext(args.midi)[0]
    conv, gain = convert_file(args.midi, base, args.rate, args.bend_range, args.loop, args.steal,
                              normalize=not args.no_normalize, drums=not args.no_drums, drum_cut=args.drum_cut)

    print(f"{base}.MBF  {len(conv.frames)} frames at {args.rate} Hz")
    print(f"{base}.txt")
    print(f"volume gain x{gain:.2f}; {conv.hits} drum hits ({conv.hits_dropped} dropped)")
    if conv.steals:
        print(f"voice pressure: {conv.steals} note-ons with all voices busy, {conv.dropped} dropped")


if __name__ == "__main__":
    main()
