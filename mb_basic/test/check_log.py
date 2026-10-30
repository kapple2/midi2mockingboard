#!/usr/bin/env python3
"""Check an AY write log from basic_test.lua against the .MBF file that was played.

usage: check_log.py <log> <mbf> [--keys] [--stream] [--dump <ram dump>] [--hangul]
                               [--nocard | --bad | --error <text>]

Without --keys the whole song must match: the logged writes after the driver's
startup silence must equal the MBF's writes, in order.  With --keys the sound
effect is expected and the song is cut short by ESC; the music writes must still
match, apart from chip 1 channels B and C while the effect owns them.

--stream: the song was streamed from disk.  Each refill pauses the music; the
driver tags the silence and volume-restore writes around it as "paused".  Those
are checked separately, the gaps are measured, and the music must still match.
--dump: the ring (from its start page up to the tail copy at $7900-$793F) as the player left it at the start of
the song; it must equal the first bytes of the .MBF file, as many as the ring holds (checks the disk reads).
--hangul: the K-HANGEUL / KBASIC disk: the Hangul font, KBASIC and the CHRGET patch must be
the same at the end as at the first note (basic_test.lua writes "#HANGUL same").
"""
import struct
import sys

SFX_ON_CHIP1 = {2, 3, 4, 5, 9, 10}
# What the player's built-in blip writes, then the hand-back of the channels
SFX_BLIP = [(1, 2, 0xA0), (1, 3, 0x00), (1, 9, 0x0F), (1, 9, 0x0C), (1, 9, 0x09),
            (1, 9, 0x06), (1, 9, 0x03), (1, 9, 0x00)]
MAX_GAP = 1.0           # seconds: the longest pause for one track refill that we accept
TAIL_BYTES = 64            # the dump ends with the 64-byte tail copy of the ring's start


def load_mbf(path):
    data = open(path, "rb").read()
    magic, rate, loop, _ = struct.unpack("<4sHBB", data[:8])
    assert magic == b"MBF1"
    frames, i = [], 8
    while data[i] != 0xFF:
        n = data[i]
        i += 1
        if n >= 0x80:                       # 0x80 + k: k empty ticks
            frames.extend([] for _ in range(max(n - 0x80, 1)))
            continue
        frames.append([(data[i + 2 * k] >> 4, data[i + 2 * k] & 15, data[i + 2 * k + 1]) for k in range(n)])
        i += 2 * n
    return rate, frames, data


def load_log(path):
    writes, notes, screen = [], {}, []
    in_screen = False
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if in_screen:
            screen.append(line)
        elif line == "#SCREEN":
            in_screen = True
        elif line.startswith("#"):
            parts = line.split()
            try:
                notes[parts[0]] = float(parts[1]) if len(parts) > 1 else True
            except ValueError:
                notes[parts[0]] = " ".join(parts[1:])      # #PC / #IOB debugging notes on a hang
        else:
            t, chip, reg, val, paused = line.split()
            writes.append((float(t), int(chip), int(reg), int(val), int(paused)))
    return writes, notes, screen


def arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None


def main():
    log, mbf = sys.argv[1], sys.argv[2]
    keys = "--keys" in sys.argv
    stream = "--stream" in sys.argv
    writes, notes, screen = load_log(log)
    problems = []
    text = "\n".join(screen)

    if "--error" in sys.argv:
        want = arg("--error")
        print("screen:", [row.strip() for row in screen if row.strip()][-4:])
        if want not in text:
            sys.exit(f"FAIL: the screen does not show {want}")
        if any(w[2] < 8 for w in writes):
            sys.exit("FAIL: the player wrote tone/mixer registers after the error")
        print("PASS")
        return
    if "--bad" in sys.argv:
        print("screen:", [row.strip() for row in screen if row.strip()][-4:])
        if "FILE TYPE MISMATCH" not in text:
            sys.exit("FAIL: player did not reject the file")
        if any(w[2] < 8 for w in writes):
            sys.exit("FAIL: the player wrote tone/mixer registers for a bad file")
        print("PASS")
        return
    rate, frames, raw = load_mbf(mbf)
    if "--nocard" in sys.argv:
        print("screen:", [row.strip() for row in screen if row.strip()][-4:])
        if "I/O ERROR" not in text:
            sys.exit("FAIL: player did not report a missing card")
        if writes:
            sys.exit(f"FAIL: {len(writes)} AY writes without a card")
        print("PASS")
        return
    if notes.get("#TIMEOUT"):
        problems.append("MAME timed out (the BASIC lines did not finish)")
    if "--hangul" in sys.argv:
        print(f"Hangul font, KBASIC and CHRGET patch: {notes.get('#HANGUL')}")
        if notes.get("#HANGUL") != "same":
            problems.append("the Hangul font / KBASIC / CHRGET patch changed while the song played")

    if arg("--dump"):
        ram = open(arg("--dump"), "rb").read()
        n = min(len(raw), len(ram) - TAIL_BYTES)      # the ring holds len(ram) - 64 bytes
        if ram[:n] == raw[:n]:
            print(f"ring at song start matches the file ({n} bytes)")
        else:
            bad = next(i for i in range(n) if ram[i] != raw[i])
            problems.append(f"RAM differs from the file at offset {bad} (sector {bad // 256})")

    # The driver's startup only writes volumes 8-10 (silence); the first write to
    # registers 0-7 is the start of the song.
    start = next((i for i, w in enumerate(writes) if w[2] < 8), None)
    if start is None:
        sys.exit("FAIL: no song writes in the log")
    song = writes[start:]
    music = [w for w in song if not w[4]]
    paused = [w for w in song if w[4]]
    if not stream and paused:
        problems.append(f"{len(paused)} writes were tagged paused without streaming")

    expected = [(f, c, r, v) for f, fr in enumerate(frames) for c, r, v in fr]
    sfx_t = notes.get("#SFX")
    esc_t = notes.get("#ESC")
    got = [(t, c, r, v) for t, c, r, v, _ in music]

    # Group the paused writes into refill gaps: silence, the disk read, then the restore.
    gaps = []
    for w in paused:
        if gaps and w[0] - gaps[-1][-1][0] < 5.0 and not any(g[4] == 0 and gaps[-1][-1][0] < g[0] < w[0] for g in song):
            gaps[-1].append(w)
        else:
            gaps.append([w])

    if keys:
        # Drop everything the effect owns, and the hand-back writes, from both sides.
        def music_only(w):
            return not (w[1] == 1 and w[2] in SFX_ON_CHIP1)
        got_music = [w for w in got if music_only(w) and (esc_t is None or w[0] < esc_t)]
        exp_music = [e for e in expected if not (e[1] == 1 and e[2] in SFX_ON_CHIP1)]
        n = len(got_music)
        pairs = list(zip(got_music[:n], exp_music[:n]))
        bad = [(g, e) for g, e in pairs if g[1:] != e[1:]]
        print(f"music writes compared: {len(pairs)}, mismatches: {len(bad)}")
        if bad:
            problems.append(f"music mismatch, first: got {bad[0][0]} expected {bad[0][1]}")

        # The effect: after the key press, chip 1 sees the blip, then the hand-back.
        after = [w for w in got if sfx_t is not None and w[0] >= sfx_t and w[1] == 1 and w[2] in SFX_ON_CHIP1]
        blip = [(c, r, v) for _, c, r, v in after[:len(SFX_BLIP)]]
        print(f"effect writes: {blip}")
        if blip != SFX_BLIP:
            problems.append(f"effect writes differ from the blip: {blip}")
        handback = [(c, r, v) for _, c, r, v in after[len(SFX_BLIP):len(SFX_BLIP) + 6]]
        print(f"hand-back writes: {handback}")
        # The channels must go back to what the music last wrote there, including
        # writes the effect suppressed. Work out that state from the MBF itself.
        if len(after) > len(SFX_BLIP):
            t0 = got[0][0]

            def stalled(t):         # seconds the music stood still (refill gaps) before time t
                return sum(g[-1][0] - g[0][0] for g in gaps if g[0][0] < t)
            frame_at = round((after[len(SFX_BLIP)][0] - t0 - stalled(after[len(SFX_BLIP)][0])) * rate)
            state = {}
            for fr in frames[:frame_at + 1]:
                for c, r, v in fr:
                    state[(c, r)] = v
            want = [(1, r, state.get((1, r), 0)) for r in (2, 3, 4, 5, 9, 10)]
            print(f"music state at frame {frame_at}: {want}")
            first_frame = round((after[0][0] - t0 - stalled(after[0][0])) * rate)
            held = [(f, c, r, v) for f in range(first_frame, frame_at + 1) for c, r, v in frames[f]
                    if c == 1 and r in SFX_ON_CHIP1]
            print(f"music writes held back during the effect (frames {first_frame}-{frame_at}): {len(held)}")
            if handback != want:
                problems.append(f"hand-back wrong: got {handback} expected {want}")
        else:
            problems.append("no hand-back writes after the effect")
        if after:
            span = after[len(SFX_BLIP) - 1][0] - after[0][0]
            print(f"effect length {span * 1000:.1f} ms (6 ticks at {rate} Hz = {5000 / rate:.1f} ms between first and last)")
        if esc_t is None:
            problems.append("ESC was not sent")
    else:
        n = len(expected)
        got_w = [(c, r, v) for _, c, r, v in got[:n]]
        exp_w = [(c, r, v) for _, c, r, v in expected]
        print(f"song writes: expected {n}, logged after start {len(got)}")
        mism = next((i for i, (g, e) in enumerate(zip(got_w, exp_w)) if g != e), None)
        if mism is not None:
            problems.append(f"write {mism} differs: got {got_w[mism]} expected {exp_w[mism]}")
        if len(got) < n:
            problems.append(f"only {len(got)} of {n} writes logged")
        # After the last frame the driver silences the chips: extra volume writes.
        extra = got[n:]
        print(f"writes after the song: {len(extra)} (silence)")
        if extra and not all(r in (8, 9, 10) and v == 0 for _, c, r, v in extra):
            problems.append("unexpected writes after the end of the song")

        first = {}
        for (f, _, _, _), (t, _, _, _) in zip(expected, got[:n]):
            first.setdefault(f, t)
        t0 = first[0]

        if stream:
            # --- refill gaps -------------------------------------------------
            lengths = [g[-1][0] - g[0][0] for g in gaps]
            print(f"refill gaps: {len(gaps)}, lengths "
                  f"{', '.join(f'{x:.2f}' for x in lengths[:8])}{' ...' if len(lengths) > 8 else ''} s; "
                  f"longest {max(lengths, default=0):.2f} s, total {sum(lengths):.2f} s")
            if max(lengths, default=0) > MAX_GAP:
                problems.append(f"a refill gap of {max(lengths):.2f} s is longer than {MAX_GAP} s")
            # Each gap: six silence writes, then the volumes restored to the music's state.
            n_before = 0
            for gi, g in enumerate(gaps):
                gap_start = g[0][0]
                n_before = sum(1 for w in got if w[0] < gap_start)
                state = {}
                for _, c, r, v in expected[:n_before]:
                    state[(c, r)] = v
                tags = [(c, r, v) for _, c, r, v, _ in g]
                vols = [(c, r) for c in (0, 1) for r in (8, 9, 10)]
                silence = [(c, r, 0) for c, r in vols]
                restore = [(c, r, state.get((c, r), 0)) for c, r in vols]
                if tags != silence + restore:
                    problems.append(f"gap {gi}: paused writes {tags} expected {silence + restore}")
                    break
            # --- timing with the gaps taken out ------------------------------
            gap_ends = [(g[0][0], g[-1][0] - g[0][0]) for g in gaps]
            devs = []
            for f, t in first.items():
                stalled = sum(length for start_t, length in gap_ends if start_t < t)
                devs.append(t - t0 - stalled - f / rate)
            slack = 0.025 * len(gaps) + 0.005 + 25e-6 * (max(first) / rate)
            span = max(abs(d) for d in devs)
            print(f"timing without the gaps: {len(first)} frames over {max(first) / rate:.1f} s, "
                  f"largest offset from the {rate} Hz grid {span * 1000:.1f} ms (allowed {slack * 1000:.1f} ms)")
            if span > slack:
                problems.append("music timing is off by more than one tick per refill")
        else:
            # Separate steady drift (a tick period that is a fraction of a cycle off)
            # from jitter (ticks arriving at uneven intervals), which is audible.
            xs = [f / rate for f in first]
            ys = [t - t0 - f / rate for f, t in first.items()]
            mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
            var = sum((x - mx) ** 2 for x in xs)
            slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / var if var else 0.0
            resid = [y - (my + slope * (x - mx)) for x, y in zip(xs, ys)]
            jitter = max(resid) - min(resid)
            drift_ppm = slope * 1e6
            print(f"timing: {len(first)} frames over {xs[-1]:.1f} s, drift {drift_ppm:.1f} ppm "
                  f"({slope * xs[-1] * 1000:.2f} ms over the song), jitter {jitter * 1000:.3f} ms peak to peak")
            if jitter > 0.0005:
                problems.append(f"frame jitter {jitter * 1000:.3f} ms is above 0.5 ms")
            if abs(drift_ppm) > 100:
                problems.append(f"tick rate is off by {drift_ppm:.0f} ppm (limit 100)")

    if "FINISHED" not in text:
        problems.append("the BASIC line never finished")
    print("screen:", [row.strip() for row in screen if row.strip()][-4:])

    if problems:
        print("FAIL")
        for p in problems:
            print(" -", p)
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
