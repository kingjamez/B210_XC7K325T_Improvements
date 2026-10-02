#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Transmit quality checks by over-the-air loopback: TX on channel 0
(TX/RX port), RX on channel 1 (RX2 port), one antenna on each.

TRANSMITS. Defaults: 915 MHz (US ISM band), TX gain capped at 50 dB (a few
tens of microwatts at most), short bursts. Use only where that is legal; a
cable with >= 30 dB attenuation between the ports works too.

    tools/tx_test.py [--fpga IMG] [--freq 915e6] [--gain 50] [--rx-gain 30] [--tests 1,2,3,4]

Frequency plan (F = --freq): TX LO at F - 3 MHz, RX LO at F + 2.5 MHz, RX at
30.72 MS/s. The TX and RX LOs are kept 5.5 MHz apart on purpose: within ~2 MHz
of each other the AD9361's two synthesizers interact and the receiver shows
strong spurs (carrier + k x LO spacing) that are not on the air.

1. Tone at +1 MHz from the TX LO (F - 2 MHz), 0.5 FS: TX LO leakage, TX
   image, +3x / -3x products, in dBc.
2. TX gain sweep 0 .. --gain: received level should track 1 dB/dB.
3. Band-limited noise (|f| < 0.35 x 7.68 MS/s) at peak 0.25 .. 1.0 FS: the
   level just outside the band should stay put.
4. CORDIC headroom: constant A(1+1j), shifted +1 MHz by the FPGA's CORDIC
   (same RF as test 1). Without headroom the CORDIC overflows near full
   scale: the carrier drops and spurs appear.
"""
import argparse, os, sys, threading, time
import numpy as np
os.environ.setdefault("UHD_LOG_FASTPATH_DISABLE", "1")
import uhd

ap = argparse.ArgumentParser()
ap.add_argument("--fpga", default="")
ap.add_argument("--serial", default="")
ap.add_argument("--freq", type=float, default=915e6)
ap.add_argument("--gain", type=float, default=50.0)
ap.add_argument("--rx-gain", type=float, default=30.0)
ap.add_argument("--tests", default="1,2,3,4")
ap.add_argument("--allow-gain-above-50", action="store_true")
a = ap.parse_args()
if a.gain > 50 and not a.allow_gain_above_50:
    sys.exit("TX gain capped at 50 dB (use --allow-gain-above-50 deliberately)")
tests = {int(v) for v in a.tests.split(",")}

MCR, TXR = 30.72e6, 7.68e6
args = f"type=b200,master_clock_rate={MCR:g}"
args += (",fpga=" + a.fpga) if a.fpga else ""
args += (",serial=" + a.serial) if a.serial else ""
u = uhd.usrp.MultiUSRP(args)
TX, RX = 0, 1
F, TXLO, RXLO = a.freq, a.freq - 3e6, a.freq + 2.5e6
u.set_tx_rate(TXR, TX); u.set_rx_rate(MCR, RX)
u.set_tx_antenna("TX/RX", TX); u.set_rx_antenna("RX2", RX)
u.set_tx_gain(0, TX); u.set_rx_gain(a.rx_gain, RX)
u.set_rx_freq(uhd.types.TuneRequest(RXLO), RX)
fs_rx = u.get_rx_rate(RX)
sa = uhd.usrp.StreamArgs("fc32", "sc16"); sa.channels = [TX]; txs = u.get_tx_stream(sa)
sa = uhd.usrp.StreamArgs("fc32", "sc16"); sa.channels = [RX]; rxs = u.get_rx_stream(sa)


def transmit(buf, stop):
    md = uhd.types.TXMetadata(); md.start_of_burst = True
    while not stop.is_set():
        txs.send(buf, md, 1.0); md.start_of_burst = False
    md.end_of_burst = True
    txs.send(np.zeros((1, 0), np.complex64), md)


def capture(n=1 << 21):
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done); cmd.num_samps = n + 200000; cmd.stream_now = True
    rxs.issue_stream_cmd(cmd)
    out = np.zeros(n + 200000, np.complex64); tmp = np.zeros(rxs.get_max_num_samps(), np.complex64)
    md = uhd.types.RXMetadata(); got = 0
    while got < len(out):
        k = rxs.recv(tmp, md, 2.0)
        if k == 0:
            break
        m = min(k, len(out) - got); out[got:got + m] = tmp[:m]; got += m
    return out[200000:got]


def burst(buf, gain):
    u.set_tx_gain(gain, TX)
    stop = threading.Event()
    th = threading.Thread(target=transmit, args=(buf, stop), daemon=True); th.start()
    time.sleep(0.3)
    x = capture()
    stop.set(); th.join(3)
    u.set_tx_gain(0, TX)
    return x


def psd(x, nfft=16384):
    w = np.blackman(nfft)
    segs = [x[i:i + nfft] for i in range(0, len(x) - nfft, nfft // 2)]
    p = np.mean([np.abs(np.fft.fft(s * w)) ** 2 for s in segs], axis=0)
    return np.fft.fftshift(np.fft.fftfreq(nfft, 1 / fs_rx)) + RXLO, 10 * np.log10(np.fft.fftshift(p) + 1e-30)


def level(f, p, rf, span=4):
    i = np.argmin(np.abs(f - rf))
    return p[max(0, i - span):i + span + 1].max()


N = int(round(TXR / 1e3)) * 8                 # integer number of 1 MHz cycles at the TX rate
t = np.arange(N) / TXR
tone = (0.5 * np.exp(2j * np.pi * 1e6 * t)).astype(np.complex64)


def tx_plain():                               # TX LO at TXLO, CORDIC idle
    u.set_tx_freq(uhd.types.TuneRequest(TXLO), TX)
    time.sleep(0.2)


print(f"TX LO {TXLO / 1e6:g} MHz (ch0 TX/RX), RX LO {RXLO / 1e6:g} MHz at {fs_rx / 1e6:g} MS/s (ch1 RX2), "
      f"TX gain <= {a.gain:g} dB", flush=True)
f, p0 = psd(capture())
floor = np.median(p0)

if 1 in tests:
    tx_plain()
    f, p = psd(burst(tone, a.gain))
    ref = level(f, p, TXLO + 1e6)
    print(f"1. tone at {(TXLO + 1e6) / 1e6:g} MHz (0.5 FS, gain {a.gain:g} dB): {ref - floor:5.1f} dB above the RX floor")
    for name, rf in (("TX LO leakage", TXLO), ("TX image", TXLO - 1e6), ("+3x product", TXLO + 3e6),
                     ("-3x product", TXLO - 3e6), ("RX image", 2 * RXLO - TXLO - 1e6)):
        print(f"   {name:14s} {level(f, p, rf) - ref:6.1f} dBc")
    print(f"   (floor {floor - ref:6.1f} dBc)")

if 2 in tests:
    tx_plain()
    print("2. gain sweep (tone 0.5 FS):")
    prev = None
    for g in range(0, int(a.gain) + 1, 10):
        f, p = psd(burst(tone, g))
        lv = level(f, p, TXLO + 1e6) - floor
        print(f"   gain {g:2d} dB: {lv:5.1f} dB above floor" + ("" if prev is None else f"  step {lv - prev:5.1f} dB"))
        prev = lv

if 3 in tests:
    tx_plain()
    rng = np.random.default_rng(1)
    spec = np.zeros(N, complex)
    fb = np.fft.fftfreq(N, 1 / TXR)
    inb = np.abs(fb) < 0.35 * TXR
    spec[inb] = rng.normal(size=inb.sum()) + 1j * rng.normal(size=inb.sum())
    noise = np.fft.ifft(spec)
    noise /= np.max(np.maximum(np.abs(noise.real), np.abs(noise.imag)))
    print("3. band-limited noise: just outside the band (0.40..0.48 x 7.68 MHz from the LO) relative to in-band:")
    for amp in (0.25, 0.5, 0.75, 0.9, 1.0):
        f, p = psd(burst((amp * noise).astype(np.complex64), a.gain))
        fr = f - TXLO
        inband = np.median(p[np.abs(fr) < 0.3 * TXR])
        oob = np.median(p[(np.abs(fr) > 0.40 * TXR) & (np.abs(fr) < 0.48 * TXR)])
        print(f"   peak {amp:4.2f} FS: in-band {inband - floor:5.1f} dB above floor, outside {oob - inband:6.1f} dB")

if 4 in tests:
    u.set_tx_freq(uhd.types.TuneRequest(TXLO + 1e6, -1e6), TX)            # LO at TXLO, CORDIC +1 MHz
    time.sleep(0.2)
    print("4. CORDIC headroom: constant A(1+1j), CORDIC +1 MHz:")
    for amp in (0.5, 0.7, 0.8, 0.9, 1.0):
        f, p = psd(burst(np.full(N, amp * (1 + 1j), np.complex64), a.gain))
        cw = level(f, p, TXLO + 1e6)
        keep = np.abs(f - (TXLO + 1e6)) > 50e3
        for rf in (TXLO, RXLO, 2 * RXLO - TXLO - 1e6):                    # LO leak, RX DC, RX image
            keep &= np.abs(f - rf) > 50e3
        keep &= np.abs(f - RXLO) < 0.45 * fs_rx
        spur = p[keep].max(); fsp = f[keep][np.argmax(p[keep])]
        print(f"   A {amp:3.1f}: carrier {cw - floor:5.1f} dB above floor, worst other {spur - cw:6.1f} dBc "
              f"at {fsp / 1e6:.2f} MHz")
u.set_tx_gain(0, TX)
