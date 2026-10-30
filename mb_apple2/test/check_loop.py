#!/usr/bin/env python3
"""Check a streamed song that restarts itself (STREAM_RESTART) against its .MBF file.

usage: check_loop.py <log from mb_test.lua in "loop" mode> <mbf>

The first pass must equal the file's writes exactly. After the song ends the player refills
the ring from the first track and starts again: the second pass must begin with the same
writes, in order, until ESC stops it.
"""
import sys

from check_log import load_log, load_mbf


def main():
    log, mbf = sys.argv[1], sys.argv[2]
    rate, frames, _ = load_mbf(mbf)
    writes, notes, screen = load_log(log)
    expected = [(c, r, v) for fr in frames for c, r, v in fr]
    song = writes[next(i for i, w in enumerate(writes) if w[2] < 8):]
    problems = []

    first = [(c, r, v) for _, c, r, v, _ in song[:len(expected)]]
    if first != expected:
        problems.append("the first pass differs from the file")
    # the second pass starts at the next write to registers 0-7 (the stop and restart only write volumes)
    rest = song[len(expected):]
    start2 = next((i for i, w in enumerate(rest) if w[2] < 8), None)
    if start2 is None:
        problems.append("the song did not start again")
    else:
        end_of_first = song[len(expected) - 1][0]
        gap = rest[start2][0] - end_of_first
        esc_t = notes.get("#ESC")
        second = [(c, r, v) for t, c, r, v, _ in rest[start2:] if not isinstance(esc_t, float) or t < esc_t]
        n = len(second)
        print(f"first pass: {len(expected)} writes, second pass: {n} writes, "
              f"restarted {gap:.2f} s after the end")
        if n < 20:
            problems.append(f"only {n} writes in the second pass")
        elif second != expected[:n]:
            bad = next(i for i in range(n) if second[i] != expected[i])
            problems.append(f"the second pass differs from the file at write {bad}: {second[bad]} vs {expected[bad]}")
        if gap > 6:
            problems.append(f"restart took {gap:.1f} s")
    if problems:
        print("screen:", [row.strip() for row in screen if row.strip()][-4:])
        print("FAIL: " + "; ".join(problems))
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
