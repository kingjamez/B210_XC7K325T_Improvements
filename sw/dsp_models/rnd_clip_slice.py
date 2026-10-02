#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reference model for fpga/lib/dsp/rnd_clip_slice.v and vector generator.

y = clip(round_half_even(x / 2**SHIFT), OUT_W bits)

    python3 rnd_clip_slice.py OUTFILE [count]
writes one {in, out} hex word per line for the Icarus testbench.
"""
import random, sys

IN_W, SHIFT, OUT_W = 47, 18, 24


def model(x, in_w=IN_W, shift=SHIFT, out_w=OUT_W):
    """x: signed int within in_w bits. Returns signed int within out_w bits."""
    q, r = divmod(x, 1 << shift)            # floor division, 0 <= r < 2^shift
    half = 1 << (shift - 1)
    if r > half or (r == half and (q & 1)):  # round half to even
        q += 1
    lo, hi = -(1 << (out_w - 1)), (1 << (out_w - 1)) - 1
    return max(lo, min(hi, q))


def vectors(n, seed=1):
    rnd = random.Random(seed)
    lo, hi = -(1 << (IN_W - 1)), (1 << (IN_W - 1)) - 1
    v = [lo, hi, 0, -1, 1]
    full = 1 << (OUT_W - 1 + SHIFT)          # first value that clips
    half = 1 << (SHIFT - 1)
    for k in range(-3, 4):                   # around the clip boundaries
        v += [full + k, -full + k, full - half + k, -full - half + k]
    for m in range(-8, 9):                   # exact halves: ties to even
        v += [(m << SHIFT) + half, (m << SHIFT) - half]
    for _ in range(n):
        e = rnd.choice([IN_W - 1, OUT_W + SHIFT, OUT_W + SHIFT - 2, SHIFT + 4])
        v.append(rnd.randint(-(1 << e), (1 << e) - 1))
    return [x for x in v if lo <= x <= hi]


if __name__ == "__main__":
    out = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
    with open(out, "w") as f:
        for x in vectors(n):
            y = model(x)
            # one word per line ({in, out}): $readmemh splits on whitespace
            w = ((x & ((1 << IN_W) - 1)) << OUT_W) | (y & ((1 << OUT_W) - 1))
            f.write(f"{w:018x}\n")
    # self-checks of the model
    assert model(3 << (SHIFT - 1)) == 2 and model(1 << (SHIFT - 1)) == 0      # 1.5 -> 2, 0.5 -> 0
    assert model(-(1 << (SHIFT - 1))) == 0 and model(-(3 << (SHIFT - 1))) == -2
    assert model(1 << (IN_W - 2)) == (1 << (OUT_W - 1)) - 1
