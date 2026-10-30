#!/usr/bin/env python3
"""Check the AY write log of basic_test.lua against the .MBF file the Apple II should have played.

usage: check_basic.py <log> <expected.MBF> [--dump <RAM $6000-$80FF>]

- the RAM dump (taken at the first note) starts with exactly the expected file
- the AY register writes match the file's writes, in order, tick by tick (jitter under 3 ms)
- afterwards only the volume-off writes of MB_STOP follow
"""
import struct
import sys


def load_mbf(path):
    data = open(path, "rb").read()
    magic, rate, _, _ = struct.unpack("<4sHBB", data[:8])
    assert magic == b"MBF1"
    frames, i = [], 8
    while data[i] != 0xFF:
        n = data[i]
        i += 1
        if n >= 0x80:
            frames.extend([] for _ in range(max(n - 0x80, 1)))
            continue
        frames.append([(data[i + 2 * k] >> 4, data[i + 2 * k] & 15, data[i + 2 * k + 1]) for k in range(n)])
        i += 2 * n
    return rate, frames, data


def main():
    log, mbf = sys.argv[1], sys.argv[2]
    rate, frames, raw = load_mbf(mbf)
    writes, screen = [], []
    in_screen, timeout = False, False
    for line in open(log, encoding="utf-8"):
        line = line.rstrip("\n")
        if in_screen:
            screen.append(line)
        elif line == "#SCREEN":
            in_screen = True
        elif line == "#TIMEOUT":
            timeout = True
        elif not line.startswith("#"):
            t, chip, reg, val, _ = line.split()
            writes.append((float(t), int(chip), int(reg), int(val)))
    problems = []
    if timeout:
        problems.append("MAME timed out (the BASIC lines did not finish)")

    arg = sys.argv[sys.argv.index("--dump") + 1] if "--dump" in sys.argv else None
    if arg:
        ram = open(arg, "rb").read()
        if ram[:len(raw)] == raw:
            print(f"RAM at $6000 holds the expected file ({len(raw)} bytes)")
        else:
            bad = next((i for i in range(min(len(raw), len(ram))) if ram[i] != raw[i]), min(len(raw), len(ram)))
            problems.append(f"RAM differs from the expected file at offset {bad} (of {len(raw)})")

    start = next((i for i, w in enumerate(writes) if w[2] < 8), None)
    if start is None:
        problems.append("no song writes in the log")
    else:
        song = writes[start:]
        expected = [(f, c, r, v) for f, fr in enumerate(frames) for c, r, v in fr]
        got = song[:len(expected)]
        mism = [(g, e) for g, e in zip(got, expected) if g[1:] != e[1:]]
        print(f"writes compared: {len(got)} of {len(expected)}, mismatches: {len(mism)}")
        if len(got) < len(expected):
            problems.append(f"only {len(got)} of {len(expected)} writes were made")
        if mism:
            problems.append(f"first mismatch: got {mism[0][0]} expected {mism[0][1]}")
        if got:
            # the first write of each tick (a frame's pairs follow one another over a few ms)
            first = {}
            for g, e in zip(got, expected):
                first.setdefault(e[0], g[0])
            t0 = first[min(first)] - min(first) / rate
            dev = [t - (t0 + f / rate) for f, t in first.items()]
            jitter = max(dev) - min(dev)
            # MAME's timer 1 runs a steady 22.5 ppm slow, so allow 3 ms of jitter plus 30 ppm of drift
            allowed = 0.003 + 30e-6 * len(frames) / rate
            print(f"timing: {len(frames)} ticks over {len(frames) / rate:.1f} s, spread {jitter * 1000:.2f} ms "
                  f"(allowed {allowed * 1000:.1f} ms)")
            if jitter > allowed:
                problems.append(f"timing spread {jitter * 1000:.1f} ms")
        tail = song[len(expected):]
        if any(not (w[2] in (8, 9, 10) and w[3] == 0) for w in tail):
            problems.append(f"unexpected writes after the song: {tail[:4]}")

    text = "\n".join(screen)
    if "FINISHED" not in text:
        problems.append("the BASIC line never finished")
    if problems:
        print("screen:", [row.strip() for row in screen if row.strip()][-6:])
        print("FAIL: " + "; ".join(problems))
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
