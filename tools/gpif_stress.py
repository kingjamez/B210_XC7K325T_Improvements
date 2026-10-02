#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stress the FX3 <-> FPGA USB interface (GPIF) of a K7 B210 image.

    tools/gpif_stress.py --fpga IMG [--serial S] [--opens 20]
    tools/gpif_stress.py --fpga IMG --tx            # also stream TX: transmits (use a 50-ohm load)

1. Opens: makes the device N times. Each open runs UHD's full initialization
   (GPIF reset, codec reset, self-tests), where GPIF timing faults used to show
   up as ctrl ack timeouts or packet parse errors. (UHD loads the image only if
   it differs from the one already in the FPGA.)
2. With --tx only: TX streams of zero-valued samples (only carrier leakage leaves
   the antenna port) at --tx-freq / --tx-gain (defaults 915 MHz, 0 dB), alone
   and full duplex with RX, at each rate in --rates. Counts TX sequence errors
   (packets lost or corrupted host -> FPGA), underflows, RX overflows and drops.

RX-only throughput is covered by tools/baseline.sh.
"""
import argparse, os, sys, threading, time
import numpy as np
os.environ.setdefault("UHD_LOG_FASTPATH_DISABLE", "1")   # no U/O/D console spam; counted below
import uhd

ap = argparse.ArgumentParser()
ap.add_argument("--fpga", default="")
ap.add_argument("--serial", default="")
ap.add_argument("--opens", type=int, default=20)
ap.add_argument("--tx", action="store_true", help="run the TX tests (transmits)")
ap.add_argument("--tx-freq", type=float, default=915e6)
ap.add_argument("--tx-gain", type=float, default=0.0)
ap.add_argument("--rates", default="15.36e6,30.72e6,61.44e6",
                help="sample rates; master clock = rate. TX-only: 1 ch, and 2 ch up to 30.72e6. "
                     "Full duplex only where rate x channels <= 30.72e6 (USB 3 carries about 2 x 245 MB/s)")
ap.add_argument("--duration", type=float, default=10.0)
a = ap.parse_args()

base = "type=b200,num_recv_frames=128,recv_frame_size=16360,num_send_frames=128,send_frame_size=16360"
if a.fpga:
    base += ",fpga=" + a.fpga
if a.serial:
    base += ",serial=" + a.serial

# ---- 1. opens ----
ok = 0
for i in range(a.opens):
    try:
        u = uhd.usrp.MultiUSRP(base)
        u.get_mboard_name()
        del u
        ok += 1
    except Exception as e:  # noqa: BLE001
        print(f"open {i + 1}: FAIL {str(e).splitlines()[0][:120]}", flush=True)
print(f"opens: {ok}/{a.opens}", flush=True)
if not a.tx or ok == 0:
    sys.exit(0 if ok == a.opens else 1)

# ---- 2. TX and full duplex ----
EV = uhd.types.TXMetadataEventCode


def run(rate, chans, duplex):
    u = uhd.usrp.MultiUSRP(base + f",master_clock_rate={rate:g}")
    for c in chans:
        u.set_tx_rate(rate, c)
        u.set_tx_freq(uhd.types.TuneRequest(a.tx_freq), c)
        u.set_tx_gain(a.tx_gain, c)
        u.set_tx_antenna("TX/RX", c)
        if duplex:
            u.set_rx_rate(rate, c)
            u.set_rx_freq(uhd.types.TuneRequest(a.tx_freq + 20e6), c)
            u.set_rx_antenna("RX2", c)
    sa = uhd.usrp.StreamArgs("fc32", "sc16"); sa.channels = list(chans)
    tx = u.get_tx_stream(sa)
    rx = u.get_rx_stream(sa) if duplex else None
    stop = threading.Event()
    cnt = {"seq": 0, "under": 0, "other": 0, "tx_samps": 0, "rx_samps": 0, "over": 0, "drop": 0, "rx_err": 0}

    def async_reader():
        md = uhd.types.TXAsyncMetadata()
        while not stop.is_set():
            if not tx.recv_async_msg(md, 0.1):
                continue
            ev = md.event_code
            if ev in (EV.seq_error, EV.seq_error_in_packet):
                cnt["seq"] += 1
            elif ev in (EV.underflow, EV.underflow_in_packet):
                cnt["under"] += 1
            elif ev != EV.burst_ack:
                cnt["other"] += 1

    def rx_reader():
        buf = np.zeros((len(chans), 1 << 18), np.complex64)
        md = uhd.types.RXMetadata()
        cmd = uhd.types.StreamCMD(uhd.types.StreamMode.start_cont); cmd.stream_now = len(chans) == 1
        if len(chans) > 1:
            cmd.time_spec = u.get_time_now() + uhd.types.TimeSpec(0.2)
        rx.issue_stream_cmd(cmd)
        while not stop.is_set():
            n = rx.recv(buf, md, 1.0)
            cnt["rx_samps"] += n
            if md.error_code == uhd.types.RXMetadataErrorCode.overflow:
                cnt["drop" if md.out_of_sequence else "over"] += 1
            elif md.error_code not in (uhd.types.RXMetadataErrorCode.none,):
                cnt["rx_err"] += 1
        rx.issue_stream_cmd(uhd.types.StreamCMD(uhd.types.StreamMode.stop_cont))

    th = [threading.Thread(target=async_reader, daemon=True)]
    if duplex:
        th.append(threading.Thread(target=rx_reader, daemon=True))
    for t in th:
        t.start()
    zeros = np.zeros((len(chans), 1 << 18), np.complex64)
    md = uhd.types.TXMetadata(); md.start_of_burst = True
    t_end = time.monotonic() + a.duration
    while time.monotonic() < t_end:
        cnt["tx_samps"] += tx.send(zeros, md, 1.0)
        md.start_of_burst = False
    md.end_of_burst = True
    tx.send(np.zeros((len(chans), 0), np.complex64), md)
    time.sleep(0.5)
    stop.set()
    for t in th:
        t.join(3)
    del tx, rx, u
    want = rate * a.duration
    name = f"{'duplex' if duplex else 'tx'} {len(chans)}ch {rate / 1e6:g} MS/s"
    print(f"{name:24} tx {cnt['tx_samps'] / want * 100:5.1f}%  seq_err {cnt['seq']}  underflow {cnt['under']}  "
          f"other {cnt['other']}" + (f" | rx {cnt['rx_samps'] / want * 100:5.1f}%  overflow {cnt['over']}  "
                                     f"drop {cnt['drop']}  rx_err {cnt['rx_err']}" if duplex else ""), flush=True)
    return cnt["seq"] + cnt["drop"] + cnt["rx_err"] + cnt["other"]


print(f"TX at {a.tx_freq / 1e6:g} MHz, gain {a.tx_gain:g} dB, zero samples", flush=True)
bad = 0
for r in [float(v) for v in a.rates.split(",")]:
    combos = [((0,), False)]
    if r <= 30.72e6:
        combos += [((0,), True), ((0, 1), False)]
    if r <= 15.36e6:
        combos += [((0, 1), True)]
    for chans, duplex in combos:
        try:
            bad += run(r, chans, duplex)
        except Exception as e:  # noqa: BLE001
            bad += 1
            print(f"{r / 1e6:g} MS/s {len(chans)}ch duplex={duplex}: FAIL {str(e).splitlines()[0][:120]}", flush=True)
sys.exit(1 if bad or ok != a.opens else 0)
