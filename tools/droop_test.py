#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Measure the RX passband shape with CIC droop compensation off and on.

Receive only. Uses the receiver's own noise floor as a flat test signal: run it
on a channel with no antenna (or a 50-ohm load). For each decimation it streams
with telemetry CTRL[5] = 1 (compensation off) and 0 (on), averages power
spectra, and reports
  - the on/off ratio vs the model (sw/dsp_models/droop_comp.py: 1/droop), and
  - the flatness of the compensated passband over |f| <= 0.4 x output rate.

    tools/droop_test.py --fpga IMG [--channel 1] [--mcr 32e6]
"""
import argparse, os, sys
import numpy as np
import uhd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sw", "dsp_models"))
import droop_comp as model  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--fpga", default="")
ap.add_argument("--channel", type=int, default=1)
ap.add_argument("--mcr", type=float, default=32e6)
ap.add_argument("--gain", type=float, default=60)
ap.add_argument("--samples", type=int, default=2_000_000)
ap.add_argument("--decims", default="15,127,6,254,12,1")
a = ap.parse_args()

args = "type=b200,enable_user_regs,master_clock_rate=%g" % a.mcr
if a.fpga:
    args += ",fpga=" + a.fpga
u = uhd.usrp.MultiUSRP(args)
regs = u.get_user_settings_iface(0)
rb = lambda n: regs.peek64(n * 8)
wr = lambda n, v: regs.poke32(n * 4, v)
ver = rb(0)
assert (ver >> 32) == 0x4B374F50 and (ver & 0xffff) >= 7, "needs telemetry v1.7+"

ch = a.channel
u.set_rx_gain(a.gain, ch)
u.set_rx_freq(uhd.types.TuneRequest(700e6), ch)
u.set_rx_bandwidth(20e6, ch)            # keep the analog filter well outside the band


def capture(n):
    sa = uhd.usrp.StreamArgs("fc32", "sc16"); sa.channels = [ch]
    st = u.get_rx_stream(sa)
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done)
    cmd.num_samps = n + 200000; cmd.stream_now = True
    st.issue_stream_cmd(cmd)
    out = np.zeros(n + 200000, np.complex64); tmp = np.zeros(st.get_max_num_samps(), np.complex64)
    md = uhd.types.RXMetadata(); got = 0
    while got < len(out):
        k = st.recv(tmp, md, 2.0)
        if k == 0: break
        m = min(k, len(out) - got); out[got:got + m] = tmp[:m]; got += m
    del st
    return out[200000:got]                # drop the start transient


def psd(x, nfft=1024):
    w = np.hanning(nfft)
    segs = [x[i:i + nfft] for i in range(0, len(x) - nfft, nfft // 2)]
    p = np.mean([np.abs(np.fft.fft(s * w)) ** 2 for s in segs], axis=0)
    return np.fft.fftshift(np.fft.fftfreq(nfft)), np.fft.fftshift(p)


def bands(f, p, edge=0.4, nb=32):
    """Average PSD in nb bands over |f| <= edge, skipping +-1.5% around DC."""
    centres, vals = [], []
    edges = np.linspace(-edge, edge, nb + 1)
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (f >= lo) & (f < hi) & (np.abs(f) > 0.015)
        if m.any():
            centres.append((lo + hi) / 2); vals.append(p[m].mean())
    return np.array(centres), 10 * np.log10(np.array(vals))


ctrl0 = int(rb(6)) & 0xffffffff
print(f"telemetry v{(ver >> 16) & 0xffff}.{ver & 0xffff}, channel {ch}, mcr {a.mcr / 1e6:g} MHz")
print(f"{'decim':>5} {'H':>2} {'R':>4} {'rate MS/s':>9} | {'droop @0.4':>10} | {'on/off vs model':>16} | {'flat off':>8} {'flat on':>8}")
for d in [int(v) for v in a.decims.split(",")]:
    u.set_rx_rate(a.mcr / d, ch)
    d = int(round(a.mcr / u.get_rx_rate(ch)))   # the decimation UHD actually set
    H = 4 if d % 4 == 0 else 2 if d % 2 == 0 else 1
    R = d // H
    res = {}
    for name, bit in (("off", 0x20), ("on", 0)):
        wr(0, (ctrl0 & ~0x20) | bit)
        f, p = psd(capture(a.samples))
        res[name] = bands(f, p)
    fc, off = res["off"]; _, on = res["on"]
    ratio = (on - off) - (on - off)[np.argmin(np.abs(fc))]
    expect = -20 * np.log10(model.cic_droop(np.abs(fc), max(R, 1), H)) if R > 1 else np.zeros_like(fc)
    err = np.max(np.abs(ratio - expect))
    droop = 20 * np.log10(model.cic_droop(np.array([0.4]), R, H))[0] if R > 1 else 0.0
    print(f"{d:5d} {H:2d} {R:4d} {a.mcr / d / 1e6:9.4f} | {droop:8.2f} dB | max err {err:6.3f} dB | "
          f"{np.ptp(off):6.2f} dB {np.ptp(on):6.2f} dB", flush=True)
wr(0, ctrl0)
