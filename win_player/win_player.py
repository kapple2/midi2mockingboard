#!/usr/bin/env python3
"""Play Mockingboard .MBF files on Windows with an AY-3-8910 square-wave emulation.

The whole song is rendered up front into a 16-bit buffer, so pause, seek and the
progress bar are cheap. Two chips with three tone channels each are emulated, chip 1 in
the left channel and chip 2 in the right, as on the Mockingboard (--mono mixes them).
Tone, noise (period and mixer) and volume registers are honoured; the hardware
envelope is not, because converter.py never uses it.

Keys while playing:
  space  pause / resume      s  stop (back to start, paused)
  left / right  seek 5 s     l  toggle loop
  q  quit
"""
import argparse
import os
import struct
import sys
import time
import wave

import numpy as np

AY_CLOCK = 1_022_727
SAMPLE_RATE = 44100
CHIP_PEAK = 0.8         # output level of one chip with all three channels at volume 15
END_OF_STREAM = 0xFF
EMPTY_RUN_BASE = 0x80   # count byte 0x80 + n = n empty ticks
SEEK_SECONDS = 5

# Output level of the AY-3-8910 for volume 0-15 (measured DAC levels; about 3 dB per step).
VOLUME = np.array([0.0, 0.0100, 0.0145, 0.0211, 0.0307, 0.0455, 0.0645, 0.1073,
                   0.1266, 0.2050, 0.2922, 0.3728, 0.4925, 0.6353, 0.8055, 1.0])


def load_mbf(path):
    """Return (tick rate, loop flag, list of frames); a frame is [(chip, reg, value)]."""
    with open(path, "rb") as f:
        data = f.read()
    magic, rate, loop, _ = struct.unpack("<4sHBB", data[:8])
    if magic != b"MBF1":
        raise ValueError(f"{path}: not an MBF1 file")
    frames = []
    i = 8
    while data[i] != END_OF_STREAM:
        count = data[i]
        i += 1
        if count >= EMPTY_RUN_BASE:             # a run of ticks with no register changes
            frames.extend([] for _ in range(max(count - EMPTY_RUN_BASE, 1)))
            continue
        writes = []
        for _ in range(count):
            writes.append((data[i] >> 4, data[i] & 0x0F, data[i + 1]))
            i += 2
        frames.append(writes)
    return rate, bool(loop), frames


def noise_sequence():
    """One full cycle (131,071 steps) of the AY's 17-bit noise shift register, as booleans."""
    bits = np.empty(2 ** 17 - 1, dtype=bool)
    lfsr = 1
    for i in range(len(bits)):
        bits[i] = lfsr & 1
        lfsr = (lfsr >> 1) | (((lfsr ^ (lfsr >> 3)) & 1) << 16)
    return bits


def render(rate, frames, mono=False):
    """Render all frames to an int16 array of shape (samples, 2) at SAMPLE_RATE.

    Like the Mockingboard, chip 0 is the left channel and chip 1 the right one.
    With mono=True both chips go to both channels.
    """
    regs = np.zeros((2, 16), dtype=np.int64)
    phase = np.zeros((2, 3))
    noise_pos = np.zeros(2)         # position in the noise sequence, per chip
    noise = noise_sequence()
    chunks = []
    start = 0
    for index, writes in enumerate(frames):
        for chip, reg, value in writes:
            regs[chip][reg] = value
        end = round((index + 1) * SAMPLE_RATE / rate)
        n = end - start
        start = end
        out = np.zeros((2, n))
        steps = np.arange(1, n + 1)
        for chip in range(2):
            mixer = int(regs[chip][7])
            noise_period = int(regs[chip][6] & 0x1F) or 1
            noise_step = AY_CLOCK / (16.0 * noise_period) / SAMPLE_RATE
            noise_bits = None
            for ch in range(3):
                period = int(regs[chip][2 * ch] | ((regs[chip][2 * ch + 1] & 0x0F) << 8)) or 1
                step = AY_CLOCK / (16.0 * period) / SAMPLE_RATE
                tone_on = not (mixer >> ch) & 1
                noise_on = not (mixer >> (ch + 3)) & 1
                volume = int(regs[chip][8 + ch] & 0x0F)
                if volume and (tone_on or noise_on):
                    # Each source is a 0/1 signal; a disabled one is held high, and the channel is their AND.
                    high = np.ones(n, dtype=bool)
                    if tone_on:
                        high &= ((phase[chip][ch] + step * steps) % 1.0) < 0.5
                    if noise_on:
                        if noise_bits is None:
                            noise_bits = noise[((noise_pos[chip] + noise_step * steps).astype(np.int64)) % len(noise)]
                        high &= noise_bits
                    out[chip] += VOLUME[volume] * np.where(high, 1.0, -1.0)
                phase[chip][ch] = (phase[chip][ch] + step * n) % 1.0
            noise_pos[chip] = (noise_pos[chip] + noise_step * n) % len(noise)
        if mono:
            out[:] = out.sum(axis=0) / 2
        chunks.append(out)
    audio = np.concatenate(chunks, axis=1).T if chunks else np.zeros((0, 2))
    # Fixed scale, as on the card: one chip with all three channels at volume 15 is full
    # output, so one channel at 15 is a third of it. Songs are not rescaled to their own peak.
    return (audio * (CHIP_PEAK * 32767 / 3.0)).astype(np.int16)


def save_wav(path, audio):
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(audio.tobytes())


class Player:
    def __init__(self, audio, loop):
        self.audio = audio
        self.loop = loop
        self.pos = 0
        self.paused = False
        self.finished = False

    def callback(self, outdata, frames, time_info, status):
        out = np.zeros((frames, 2), dtype=np.int16)
        if not self.paused and not self.finished:
            filled = 0
            while filled < frames:
                chunk = self.audio[self.pos:self.pos + frames - filled]
                out[filled:filled + len(chunk)] = chunk
                filled += len(chunk)
                self.pos += len(chunk)
                if self.pos >= len(self.audio):
                    if self.loop and len(self.audio):
                        self.pos = 0
                    else:
                        self.finished = True
                        break
        outdata[:] = out

    def seek(self, seconds):
        self.pos = int(min(max(self.pos + seconds * SAMPLE_RATE, 0), max(len(self.audio) - 1, 0)))
        self.finished = False


def fmt_time(seconds):
    return f"{int(seconds) // 60}:{int(seconds) % 60:02d}"


def play(audio, loop):
    import msvcrt
    import sounddevice as sd

    player = Player(audio, loop)
    total = len(audio) / SAMPLE_RATE
    with sd.OutputStream(samplerate=SAMPLE_RATE, channels=2, dtype="int16", callback=player.callback):
        while True:
            while msvcrt.kbhit():
                key = msvcrt.getwch()
                if key in ("\x00", "\xe0"):          # arrow keys arrive as two characters
                    key = {"K": "left", "M": "right"}.get(msvcrt.getwch(), "")
                if key == " ":
                    player.paused = not player.paused
                elif key == "s":
                    player.pos, player.paused, player.finished = 0, True, False
                elif key == "left":
                    player.seek(-SEEK_SECONDS)
                elif key == "right":
                    player.seek(SEEK_SECONDS)
                elif key == "l":
                    player.loop = not player.loop
                elif key == "q":
                    print()
                    return
            now = player.pos / SAMPLE_RATE
            width = 30
            filled = int(width * now / total) if total else 0
            state = "done" if player.finished else "paused" if player.paused else "play"
            print(f"\r[{'#' * filled}{'-' * (width - filled)}] {fmt_time(now)}/{fmt_time(total)} "
                  f"{state:6} loop={'on ' if player.loop else 'off'}", end="", flush=True)
            if player.finished and not player.paused:
                print()
                return
            time.sleep(0.05)


def main():
    parser = argparse.ArgumentParser(description="Play a Mockingboard .MBF file")
    parser.add_argument("mbf", nargs="+", help="input .MBF file (a path with spaces works without quotes)")
    parser.add_argument("--wav", help="render to this WAV file instead of playing")
    parser.add_argument("--loop", action="store_true", help="loop even if the header flag is off")
    parser.add_argument("--mono", action="store_true", help="mix both chips into both channels (default: chip 1 left, chip 2 right, like the card)")
    args = parser.parse_args()
    args.mbf = " ".join(args.mbf)       # cmd.exe splits an unquoted path at its spaces

    rate, header_loop, frames = load_mbf(args.mbf)
    print(f"{os.path.basename(args.mbf)}: {len(frames)} frames at {rate} Hz "
          f"= {fmt_time(len(frames) / rate)}, rendering...")
    audio = render(rate, frames, mono=args.mono)

    if args.wav:
        save_wav(args.wav, audio)
        print(f"wrote {args.wav}")
        return
    play(audio, args.loop or header_loop)


if __name__ == "__main__":
    sys.exit(main())
