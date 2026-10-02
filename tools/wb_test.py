#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Measure the wideband filter profiles (decimation 1) against the model.

Receive only. Use a channel with no antenna (default channel 0, RX2): the
receiver's noise floor is the test signal. For each rate (decimation 1) it
captures with telemetry CTRL[7:6] = 0 (bypass) and each profile 1..3 and
compares the spectrum ratio with sw/dsp_models/wb_fir.py:
  - passband: max deviation from the model over |f| <= the profile's edge;
  - stop band: measured attenuation over the profile's stop band (limited by
    the measurement floor, so "at least").

    tools/wb_test.py [--fpga IMG] [--channel 0] [--rates 61.44e6,56e6,30.72e6]
"""
import argparse, os, sys
import numpy as np
os.environ.setdefault("UHD_LOG_FASTPATH_DISABLE", "1")
import uhd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sw", "dsp_models"))
import wb_fir as model  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--fpga", default="")
ap.add_argument("--serial", default="")
ap.add_argument("--channel", type=int, default=0)
ap.add_argument("--gain", type=float, default=60)
ap.add_argument("--samples", type=int, default=4_000_000)
ap.add_argument("--rates", default="61.44e6,56e6,30.72e6")
a = ap.parse_args()
ch = a.channel


def capture(st, n):
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done); cmd.num_samps = n + 200000; cmd.stream_now = True
    st.issue_stream_cmd(cmd)
    out = np.zeros(n + 200000, np.complex64); tmp = np.zeros(st.get_max_num_samps(), np.complex64)
    md = uhd.types.RXMetadata(); got = 0
    while got < len(out):
        k = st.recv(tmp, md, 2.0)
        if k == 0:
            break
        m = min(k, len(out) - got); out[got:got + m] = tmp[:m]; got += m
    return out[200000:got]


def psd(x, nfft=2048):
    w = np.hanning(nfft)
    segs = [x[i:i + nfft] for i in range(0, len(x) - nfft, nfft // 2)]
    p = np.mean([np.abs(np.fft.fft(s * w)) ** 2 for s in segs], axis=0)
    return np.fft.fftshift(np.fft.fftfreq(nfft)), np.fft.fftshift(p)


def smooth(f, p, width=0.01):
    """Average PSD over +-width (fraction of fs) for a stable ratio."""
    out = np.empty_like(p)
    for i, fi in enumerate(f):
        out[i] = p[np.abs(f - fi) <= width].mean()
    return out


print(f"channel {ch}, gain {a.gain:g} dB, decimation 1")
print(f"{'rate':>9} {'prof':>4} | {'pass edge':>9} {'max dev vs model':>17} | {'stop from':>9} {'measured atten':>15} {'model':>7}")
for rate in [float(v) for v in a.rates.split(",")]:
    args = f"type=b200,enable_user_regs,master_clock_rate={rate:g}"
    args += (",fpga=" + a.fpga) if a.fpga else ""
    args += (",serial=" + a.serial) if a.serial else ""
    u = uhd.usrp.MultiUSRP(args)
    u.set_master_clock_rate(rate)              # device args alone don't stick on re-open
    regs = u.get_user_settings_iface(0)
    ver = regs.peek64(0)
    assert (ver >> 32) == 0x4B374F50 and (ver & 0xffff) >= 8, "needs telemetry v1.8+"
    ctrl0 = int(regs.peek64(6 * 8)) & 0xFFFFFFFF
    u.set_rx_rate(rate, ch)
    assert abs(u.get_rx_rate(ch) - rate) < 1, f"rate {u.get_rx_rate(ch)} != {rate} (decimation must be 1)"
    u.set_rx_freq(uhd.types.TuneRequest(700e6), ch)
    u.set_rx_gain(a.gain, ch); u.set_rx_antenna("RX2", ch); u.set_rx_bandwidth(min(rate, 56e6), ch)
    sa = uhd.usrp.StreamArgs("fc32", "sc16"); sa.channels = [ch]
    st = u.get_rx_stream(sa)
    res = {}
    for prof in (0, 1, 2, 3):
        regs.poke32(0, (ctrl0 & ~0xC0) | (prof << 6))
        f, p = psd(capture(st, a.samples))
        res[prof] = smooth(f, p)
    regs.poke32(0, ctrl0)
    for prof in (1, 2, 3):
        fp, fst, _ = model.PROFILES[prof]
        ratio = 10 * np.log10(res[prof] / res[0])
        # model smoothed the same way as the measurement
        expect = 10 * np.log10(smooth(f, 10 ** (model.response(model.coefs(prof), np.abs(f)) / 10)))
        pb = np.abs(f) <= fp - 0.01
        dev = np.max(np.abs((ratio - expect)[pb] - np.median((ratio - expect)[pb])))
        sb = np.abs(f) >= fst + 0.005
        meas = -np.median(ratio[sb]); mod = -np.median(expect[sb])
        print(f"{rate / 1e6:7.2f}M {prof:4d} | {fp:7.2f}fs {dev:14.3f} dB | {fst:7.2f}fs {meas:12.1f} dB {mod:6.1f} dB", flush=True)
    del st, u
