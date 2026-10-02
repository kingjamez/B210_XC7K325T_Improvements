#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CIC droop compensation for the B200 DDC (N5): design and evaluation.

DDC: CIC (4 stages, rate R) -> optional halfbands (hb47, /2 each) -> output.
UHD (B200) uses halfbands while the decimation is even, so H = 1, 2 or 4 and
R = decimation / H (1..255). The compensator is a symmetric FIR at the output
rate whose response is 1/droop over the passband, with integer coefficients
(COEF_BITS, DC gain 2^COEF_FRAC).

    python3 droop_comp.py study           # flatness vs number of taps
    python3 droop_comp.py rom OUT NTAPS   # coefficient table for the FPGA
"""
import sys
import numpy as np

N_CIC = 4
PASS = 0.40            # passband edge, fraction of the output rate
COEF_BITS = 18
COEF_FRAC = 16         # DC gain = 2^16; leaves headroom for the boost (<= ~3.1x)

HB47 = np.array([-62, 0, 194, 0, -440, 0, 855, 0, -1505, 0, 2478, 0, -3900, 0,
    5990, 0, -9187, 0, 14632, 0, -26536, 0, 83009, 131071, 83009, 0, -26536, 0,
    14632, 0, -9187, 0, 5990, 0, -3900, 0, 2478, 0, -1505, 0, 855, 0, -440, 0,
    194, 0, -62], dtype=float)
HB47 /= HB47.sum()


def cic_droop(x, R, H):
    """|H_cic| at x (fraction of the output rate), CIC rate R, H halfband factor."""
    if R == 1:
        return np.ones_like(x)
    u = x / (R * H)                     # cycles per CIC input sample
    num = np.sin(np.pi * R * u)
    den = R * np.sin(np.pi * u)
    out = np.ones_like(x)
    nz = u != 0
    out[nz] = np.abs(num[nz] / den[nz]) ** N_CIC
    return out


def hb_resp(x, H):
    """Combined halfband magnitude at x (fraction of the output rate)."""
    r = np.ones_like(x)
    # the last halfband runs at 2*fout, the one before at 4*fout
    for k in range({1: 0, 2: 1, 4: 2}[H]):
        f = x / (2 ** (k + 1))          # cycles per sample at that filter's input rate
        w = np.exp(-2j * np.pi * np.outer(f, np.arange(len(HB47))))
        r *= np.abs(w @ HB47)
    return r


def fir_resp(h, x):
    w = np.exp(-2j * np.pi * np.outer(x, np.arange(len(h))))
    return np.abs(w @ h)


def design(R, H, ntaps, iters=60):
    """Symmetric FIR approximating 1/droop on [0, PASS] in the minimax sense
    (Lawson's iteratively reweighted least squares on the relative error),
    with the gain above the passband held near its band-edge value."""
    assert ntaps % 2 == 1
    M = (ntaps - 1) // 2
    xp = np.linspace(0, PASS, 300)
    target = 1.0 / (cic_droop(xp, R, H) * hb_resp(xp, H))
    xs = np.linspace(PASS + 0.04, 0.5, 40)
    def basis(x):
        return np.column_stack([np.ones_like(x)] + [2 * np.cos(2 * np.pi * k * x) for k in range(1, M + 1)])
    Bp, Bs = basis(xp) / target[:, None], basis(xs) / target[-1]   # relative error
    wp = np.ones(len(xp))
    for _ in range(iters):
        A = np.vstack([Bp * np.sqrt(wp)[:, None], 0.03 * Bs])
        b = np.concatenate([np.sqrt(wp), 0.03 * np.ones(len(xs))])
        c, *_ = np.linalg.lstsq(A, b, rcond=None)
        e = np.abs(Bp @ c - 1.0)
        wp = wp * (e + 1e-12)
        wp /= wp.sum() / len(wp)
    h = np.concatenate([c[:0:-1], c])
    return h / np.sum(h)


def quantize(h):
    q = np.round(h * (1 << COEF_FRAC)).astype(int)
    q[len(q) // 2] += (1 << COEF_FRAC) - q.sum()   # keep DC gain exact
    lim = (1 << (COEF_BITS - 1)) - 1
    assert np.all(np.abs(q) <= lim), "coefficient overflow"
    return q


def flatness(R, H, q):
    """Max |deviation| in dB over [0, PASS] of CIC x halfbands x compensator."""
    x = np.linspace(0, PASS, 800)
    tot = cic_droop(x, R, H) * hb_resp(x, H) * fir_resp(q / (1 << COEF_FRAC), x)
    db = 20 * np.log10(tot)
    return np.max(np.abs(db - db[0])), np.max(fir_resp(q / (1 << COEF_FRAC), np.linspace(0, 0.5, 400)))


def uncompensated(R, H):
    x = np.linspace(0, PASS, 800)
    db = 20 * np.log10(cic_droop(x, R, H) * hb_resp(x, H))
    return np.max(np.abs(db))


def study():
    cases = [(R, H) for H in (1, 2, 4) for R in (2, 3, 4, 5, 7, 8, 15, 16, 31, 63, 127, 255) if R > 1]
    print("worst uncompensated droop over [0,0.4]: H=1 %.2f dB, H=2 %.2f dB, H=4 %.2f dB" % tuple(
        max(uncompensated(R, H) for R in range(2, 256)) for H in (1, 2, 4)))
    for ntaps in (9, 11, 13, 15, 17, 19, 21, 23):
        worst = max((flatness(R, H, quantize(design(R, H, ntaps)))[0], R, H) for R, H in cases)
        peak = max(flatness(R, H, quantize(design(R, H, ntaps)))[1] for R, H in cases)
        print(f"{ntaps:2d} taps: worst passband deviation {worst[0]:.3f} dB (R={worst[1]}, H={worst[2]}), max FIR gain {peak:.2f}")


def rom(out, ntaps):
    """One row per (H index, R): the (ntaps+1)/2 unique coefficients, hex."""
    M = (ntaps + 1) // 2
    worst = 0
    with open(out, "w") as f:
        for hi, H in enumerate((1, 2, 4)):
            for R in range(256):
                if R <= 1:
                    q = np.zeros(ntaps, dtype=int); q[ntaps // 2] = 1 << COEF_FRAC
                else:
                    q = quantize(design(R, H, ntaps))
                    worst = max(worst, flatness(R, H, q)[0])
                for c in q[:M]:
                    f.write(f"{c & ((1 << COEF_BITS) - 1):05x}\n")
    print(f"wrote {out}: 3 x 256 x {M} coefficients, worst deviation {worst:.3f} dB")


if __name__ == "__main__":
    if sys.argv[1] == "study":
        study()
    elif sys.argv[1] == "rom":
        rom(sys.argv[2], int(sys.argv[3]))


# ---- FPGA artefacts -------------------------------------------------------
NT = 13          # taps used in fpga/lib/dsp/droop_comp.v
M = (NT + 1) // 2


GROUP_TOL = 0.03   # dB: CIC rates share a coefficient set within this error


def _error_matrix(H):
    """E[i, j] = worst passband deviation when rate Rs[j] uses rate Rs[i]'s set."""
    x = np.linspace(0, PASS, 400)
    Rs = np.arange(2, 256)
    Qs = [quantize(design(R, H, NT)) for R in Rs]
    W = np.exp(-2j * np.pi * np.outer(np.arange(NT), x))
    F = np.abs(np.array(Qs, float) / (1 << COEF_FRAC) @ W)
    D = np.array([cic_droop(x, R, H) for R in Rs]) * hb_resp(x, H)[None, :]
    E = np.zeros((len(Rs), len(Rs)))
    for i in range(len(Rs)):
        tot = 20 * np.log10(F[i][None, :] * D)
        E[i] = np.max(np.abs(tot - tot[:, :1]), axis=1)
    return Rs, Qs, E


_GROUPS = {}


def groups(H):
    """[(lo_rate, hi_rate, coefficients)] covering CIC rates 2..255 for halfband
    factor H: greedy ranges sharing one representative set within GROUP_TOL."""
    if H not in _GROUPS:
        Rs, Qs, E = _error_matrix(H)
        out, lo = [], 0
        while lo < len(Rs):
            best = None
            for hi in range(lo, len(Rs)):
                w = E[lo:hi + 1, lo:hi + 1].max(axis=1)
                r = int(np.argmin(w))
                if w[r] > GROUP_TOL:
                    break
                best = (int(Rs[lo]), int(Rs[hi]), [int(v) for v in Qs[lo + r]])
            out.append(best)
            lo = Rs.tolist().index(best[1]) + 1
        _GROUPS[H] = out
    return _GROUPS[H]


def coef_set(R, H):
    """Integer coefficients c0..c6 (c6 = centre) exactly as the FPGA uses them."""
    if R <= 1:
        return [0] * (M - 1) + [1 << COEF_FRAC]
    for lo, hi, q in groups(H):
        if lo <= R <= hi:
            return q[:M]
    raise ValueError(R)


def write_vh(out):
    """Verilog include: function droop_coef(hidx, rate, k) -> signed 18-bit,
    as a rate -> set lookup (ranges) plus a small coefficient table."""
    worst = 0
    sets, sel = [], {}
    for hi_, H in enumerate((1, 2, 4)):
        for lo, hi, q in groups(H):
            sel.setdefault(hi_, []).append((lo, hi, len(sets)))
            sets.append(q[:M])
        for R in range(2, 256):
            c = coef_set(R, H)
            worst = max(worst, flatness(R, H, np.array(c + c[-2::-1]))[0])
    L = ["// Generated by sw/dsp_models/droop_comp.py vh -- do not edit.",
         f"// 13-tap minimax CIC droop compensators, DC gain 2^{COEF_FRAC}, passband 0..{PASS} x output rate.",
         f"// {len(sets)} coefficient sets; CIC rates share a set within {GROUP_TOL} dB. Worst {worst:.3f} dB.",
         "// hidx: 0 = no halfband, 1 = one, 2 = two. rate = CIC rate (2..255).",
         "function [4:0] droop_set(input [1:0] hidx, input [7:0] rate);",
         "  begin",
         "    droop_set = 5'd0;"]
    for hi_ in (0, 1, 2):
        for lo, hi, s in sel[hi_]:
            L.append(f"    if (hidx == 2'd{hi_} && rate >= 8'd{lo} && rate <= 8'd{hi}) droop_set = 5'd{s};")
    L += ["  end", "endfunction", "",
          "function signed [17:0] droop_tab(input [4:0] s, input [2:0] k);",
          "  case ({s, k})"]
    for s, q in enumerate(sets):
        for k, v in enumerate(q):
            L.append(f"    8'h{(s << 3) | k:02x}: droop_tab = {'-' if v < 0 else ''}18'sd{abs(v)};")
    L += ["    default: droop_tab = 18'sd0;", "  endcase", "endfunction", "",
          "function signed [17:0] droop_coef(input [1:0] hidx, input [7:0] rate, input [2:0] k);",
          "  droop_coef = droop_tab(droop_set(hidx, rate), k);",
          "endfunction", ""]
    open(out, "w").write("\n".join(L))
    print(f"wrote {out}: {len(sets)} sets, worst passband deviation {worst:.3f} dB")


def round_half_even_shift(v, s):
    q, r = divmod(v, 1 << s)
    half = 1 << (s - 1)
    if r > half or (r == half and (q & 1)):
        q += 1
    return q


def fir_model(xs, c, width=24):
    """Bit-exact integer model of droop_comp_fir: 13 taps, symmetric."""
    taps = list(c) + list(c[-2::-1])
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    hist = [0] * NT
    out = []
    for x in xs:
        hist = [x] + hist[:-1]
        acc = sum(t * h for t, h in zip(taps, hist))
        out.append(max(lo, min(hi, round_half_even_shift(acc, COEF_FRAC))))
    return out


def write_vectors(out, n=600, seed=3):
    """Cases: (enable, hidx, rate) + random 24-bit samples incl. full scale;
    lines: 'C enable hidx rate' then 'x y' per sample (hex, two's complement)."""
    rnd = np.random.default_rng(seed)
    cases = [(1, 0, 15), (1, 0, 255), (1, 1, 3), (1, 2, 4), (1, 0, 1), (0, 0, 15), (1, 0, 7)]
    with open(out, "w") as f:
        for en, hi, R in cases:
            H = (1, 2, 4)[hi]
            c = coef_set(R if en else 1, H)
            xs = list(rnd.integers(-(1 << 23), 1 << 23, n))
            xs[50:80] = [(1 << 23) - 1, -(1 << 23)] * 15        # full-scale alternation: saturation
            ys = fir_model(xs, c)
            f.write(f"C {en} {hi} {R}\n")
            for x, y in zip(xs, ys):
                f.write(f"{int(x) & 0xffffff:06x} {int(y) & 0xffffff:06x}\n")
    print(f"wrote {out}")


if __name__ == "__main__" and sys.argv[1] in ("vh", "vectors"):
    (write_vh if sys.argv[1] == "vh" else write_vectors)(sys.argv[2])
