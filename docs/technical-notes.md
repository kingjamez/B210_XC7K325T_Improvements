# Technical notes

What changed relative to the vendor's Kintex-7 port of the Ettus B200 design,
why, and how it was verified. All measurements: one board, Linux, UHD 4.9,
unless stated.

## Board facts used here

- XC7K325T-FFG676-2, AD9361 in CMOS mode, FX3 USB 3, compat number 16.0
  (stock UHD treats it as a B210).
- u-blox MAX-M10S (firmware SPG 5.10, protocol 34.10), **no backup supply**:
  every power-up is a cold start with default settings. Its UART runs at
  **38400 baud** at power-up on these boards (the datasheet default is 9600).
  Module TXD → FPGA pin B14, module RXD ← FPGA pin A14, TIMEPULSE → B15.
  SMA PPS → G11.
- 40 MHz VCTCXO. Its tune voltage rests at 1.65 V (1 MΩ/1 MΩ divider). The
  ADF4001 reference PLL drives it only through 100 kΩ and three-states its
  charge pump for `clock_source=internal`. A resistor from the AD9361 AUXDAC1
  to the tune node is marked not-fitted; fitting it would allow clean
  on-board GPS disciplining (future work).
- Reference mux (SN74LVC1G3157) selects 10M IN (SMA) or an unconnected
  "GPS 10 MHz" net; this board has no GPSDO 10 MHz source.

## GPS detected by stock UHD (`gps_autoconfig.v`)

Stock UHD's GPS detection sends `*IDN?`, listens for 650 ms and accepts a
"generic NMEA" GPS only if it sees a `$GP…` sentence ending in `,*hh` with a
good checksum. The module's defaults (`$GN` talker, NMEA 4.11) never match.
UHD probes only once per FPGA load, early in the open (before the radio clock
runs).

`gps_autoconfig` runs in the always-on bus clock, once per FPGA load:

1. Waits until B14 shows a burst of UART traffic while A14 stays idle-high
   (the module has one UART TX, so this proves A14 is not a module output).
   Otherwise it gives up and never drives A14.
2. Sends one UBX-CFG-VALSET (RAM layer) at 38400 baud: main talker GP, NMEA
   2.1, GGA and RMC only (every UART byte becomes a UHD control packet), 2 Hz
   measurement rate (so UHD's 650 ms window always contains a burst). Key IDs
   from the u-blox M10 SPG 5.10 interface description.
3. Waits for UBX-ACK-ACK/NAK; retries up to 8 times on no reply (a frame sent
   while UHD resets the USB interface can be corrupted).

Only after an ACK does UHD's GPSDO UART receive the GPS (at 38400). Until then
it sees an idle line, which keeps UHD exactly as without a GPS. Two safeguards
handle UHD's once-per-load probe: on the ACK the UART is reset (an earlier
probe may have armed it), and a stale "no GPSDO" verdict is hidden so the next
open probes again; if UHD rejects the module while the path has been open for
over 1.5 s, the path closes until the next load.

Verified: detection on every open after the first following a power-up, both
after a physical replug and after a software cold reset of the module;
`gps_locked`, `gps_time` correct; the configuration frame bit-exact in
simulation, including refusal to drive a busy or low pin.

## PPS

- **Separate sources.** The vendor's PPS auto-switch merged the GPS and SMA
  PPS and fed the result to every time source; with both present it produced
  two edges per second. Removed: `gpsdo` uses the GPS PPS (B15), `external`
  uses the SMA (G11). Verified with a second GPSDO on the SMA: each source sees
  only its own pulse.
- **Internal PPS glitch.** Ettus `pps_generator` without output pipelining
  produced a spurious internal PPS edge 250 ms after each real one (an
  unregistered compare sampled in another clock domain). Fixed with
  `PIPELINE("OUT")`; every edge now exactly 1 s apart.
- **Health.** Each PPS gets VALID (last two periods agree within 0.1 % and the
  next edge is not overdue), missed-pulse and bad-edge counters. Antenna
  unplugged: invalid within ~1 s, one missed count per second; VALID again
  ~2 s after the pulses resume.
- **GPS vs SMA offset.** Both edge ages come from one register read, so their
  difference is the edge offset: a second GPSDO on the SMA measured +132 ns ±
  11.5 ns relative to the on-board module.

## `clock_source=gpsdo` (`adf4001_guard.v`)

UHD's `gpsdo` clock source selects the reference mux's GPSDO input and turns on
the ADF4001 charge pump. On these boards nothing drives that input, so the
loop pulled the oscillator to the end of its range (−13.9 ppm). The guard sits
in the ADF4001's SPI lines: UHD's waveform passes through unchanged, and while
`gpsdo` is selected the charge-pump bit (three-state, as UHD itself uses for
`internal`) is forced in each word. `internal` and `external` are unaffected.

Verified: internal −0.68 ppm, external (nothing connected) −13.87 ppm as
before, gpsdo −0.67 ppm; tested against Ettus's own SPI core at several clock
dividers, including back-to-back writes.

## Oscillator monitor (`osc_monitor.v`)

Counts 100 MHz bus-clock cycles (VCTCXO × 2.5, independent of UHD's master
clock rate) between GPS (or SMA) PPS edges, rejecting periods outside
±200 ppm, and exposes the running sum atomically. Resolution 0.01 ppm per
second, improving with averaging. Measured: −0.664 ppm free-running, −0.001
ppm locked to an external GPSDO 10 MHz.

## Clock-domain-crossing FIFOs (`axi_fifo_2clk_xpm.v`)

The vendor build synthesized the Ettus *simulation model* of `axi_fifo_2clk`
(the real one depends on Spartan-6 netlists). It inferred ~28k LUTs of LUT RAM
and had no constraints on its gray-coded pointer crossings. Replaced by a
drop-in wrapper around Xilinx `xpm_fifo_async` (block RAM for large FIFOs),
with a reset sequencer: XPM ignores a new reset while the previous one is in
progress, which needs the read clock running, and the radio clock stops
during master-clock changes.

| | before | after |
|---|---|---|
| LUTs | 57,331 | 30,562 |
| LUTs as memory | 28,095 | 5,567 |
| Block RAM tiles | 56 | 89 |
| Setup slack (WNS) | +0.60 ns | +3.84 ns |
| Pointer bus skew | unconstrained | constrained, met (+9.2 ns slack) |

Verified against Xilinx's XPM simulation models (random traffic, both clock
ratios, resets from either domain and with the read clock stopped) and on
hardware: RX streaming unchanged at every rate, and TX / full-duplex streaming
without lost or corrupted packets up to 61.44 MS/s (`tools/gpif_stress.py`).

## USB interface timing (FX3 GPIF, `gpif2_slave_fifo32.v`, `b210.xdc`)

The FX3 USB controller and the FPGA exchange 32-bit words at 100 MHz (the
FX3's synchronous slave FIFO interface; the FPGA drives the clock, IFCLK). In
the vendor port this interface had **no timing constraints**: only a clock
definition on the IFCLK output that nothing referenced, and none of the
interface registers in the I/O cells. Every build placed them differently.
Checked against the CYUSB301X datasheet (clock to data 7 ns, data hold after
clock 2 ns, flags 8 ns; FX3 input setup 2 ns, hold 0.5 ns) with 0–1 ns of
board delay, the FX3's data reached the FPGA's input registers in the middle
of its transition in **every** build: worst-case setup −4 to −6 ns. Builds
worked because real delays are a few ns faster than worst case. Any unrelated
change could move the placement and break USB: UHD then failed to open the
board (control acknowledgement timeouts or "packet parse error" while
initializing the AD9361).

Fix:
- all interface registers (32 data in, 32 data out, the FX3 flags) are in the
  I/O cells, plus a per-pin copy of the output enable, so the paths are fixed;
- IFCLK comes from a spare output of the clock generator, 261° (2.75 ns ahead
  of the FPGA's interface clock), which centres the input window;
- `b210.xdc` describes the interface from the datasheet (generated clock on
  IFCLK, input/output delays, the two-cycle capture the state machine was
  written for), so Vivado checks it on every build, and `build.tcl` refuses to
  write a bitstream that misses it.

Worst-case slack now: FX3 → FPGA setup +0.11 ns, hold +0.10 ns; FPGA → FX3
setup +1.9 to +2.5 ns, hold +0.8 ns, identical in every build for the inputs.
On hardware: 20/20 opens; TX and full duplex up to 61.44 MS/s with no sequence
errors; RX streaming unchanged. The cycle-level protocol is the Ettus one,
unchanged.

## Receive DSP: halfband rounding and saturation (`rnd_clip_slice.v`)

Measured first: the RX output DC offset is ≈ −120 dBFS at every decimation, so
extra rounding for DC has nothing to gain (the chain's final noise-shaped
rounding already handles it). But the DDC halfband outputs were taken as plain
bit slices, which truncate and **wrap on overflow**, and the default
coefficients' sum of |h| is ~1.64× their DC gain, so worst-case inputs can
overflow there. They are now rounded (round half to even) and saturated,
combinationally (same latency). Bit-exact against a Python model over ~20,000
vectors; no change in streaming or DC on hardware. The transmit chain has the
same pattern and is unchanged in this release.

## Receive DSP: CIC droop compensation (`droop_comp.v`)

The DDC decimates with a 4-stage CIC (rate R) followed by 0–2 halfbands
(H = 1, 2, 4). The CIC's sinc⁴ response rolls the passband off: at 0.4 × the
output rate by up to 9.7 dB with no halfband (odd decimations), 2.3 dB with
one and 0.6 dB with two. A 13-tap symmetric FIR at the output rate, on I and
Q, after the halfbands, flattens it:
- coefficients are minimax designs for 0–0.4 × the output rate, including the
  halfbands' own response (`sw/dsp_models/droop_comp.py`), 18-bit, DC gain
  exactly 1;
- the 762 possible (H, R) settings share 18 coefficient sets (CIC rates
  grouped where they differ by < 0.03 dB); worst design residual 0.029 dB;
- the set is selected from the CIC rate and halfband settings UHD already
  programs, so no host change is needed; R = 1 is a pass-through;
- round half to even and saturating; fixed delay of 6 output samples, also
  when turned off (telemetry CTRL[5], `docs/registers.md`), so toggling it
  doesn't move timestamps;
- bit-exact against the Python model (`fpga/sim/droop_comp_tb.v`).

Measured with `tools/droop_test.py` (the receiver's own noise floor on a
channel without antenna as a flat source; on/off spectra over |f| ≤ 0.4 ×
rate):

| Decimation | H | R | Droop at 0.4 × rate | On/off vs model | Ripple off → on |
|---|---|---|---|---|---|
| 15 | 1 | 15 | −9.6 dB | 0.09 dB | 9.7 → 0.9 dB |
| 6 | 2 | 3 | −2.1 dB | 0.12 dB | 2.4 → 0.5 dB |
| 12 | 4 | 3 | −0.5 dB | 0.09 dB | 1.3 → 0.7 dB |
| 127 | 1 | 127 | −9.7 dB | 0.21 dB | 12.7 → 3.8 dB |
| 256 | 4 | 64 | −0.6 dB | 0.13 dB | 6.1 → 5.5 dB |

The on/off ratio (the compensator's own effect) matches the model within the
measurement's repeatability. What remains of the ripple is the analog front
end and, at very low rates, the receiver's noise floor, which isn't flat near
DC.

## Wideband filter profiles at decimation 1 (`wb_fir.v`)

At decimation 1 the FPGA passes the AD9361's samples straight through. Measured
on a channel without antenna, the noise floor at 0.49–0.5 fs is only 0.6 dB
(61.44 MS/s) to 1.8 dB (56 MS/s) below mid-band: the AD9361's filters leave
the band edges open, so whatever folds in from beyond Nyquist lands in the
outer ~15% of the band. `wb_fir.v` is a 33-tap symmetric FIR, one sample per
clock, active only at decimation 1, with profiles selected by telemetry
CTRL[7:6]:

| Profile | Passband (ripple) | Stop band |
|---|---|---|
| 0 (default) | bypass, no added delay | – |
| 1 | 0.42 fs (0.16 dB p-p) | ≥ 50 dB from 0.49 fs |
| 2 | 0.40 fs (0.19 dB p-p) | ≥ 45 dB from 0.47 fs |
| 3 | 0.36 fs (0.12 dB p-p) | ≥ 61 dB from 0.44 fs |

Coefficients from `sw/dsp_models/wb_fir.py` (remez, 18-bit, DC gain exactly
1); bit-exact against the model (`fpga/sim/wb_fir_tb.v`). A profile adds a
delay of 16 samples; it cannot remove aliases that already fold into the
passband. Measured with `tools/wb_test.py` (profile vs bypass on a channel
without antenna): 43–53 dB stop band at 30.72–61.44 MS/s (limited by the
measurement), passband within 0.1–0.2 dB of the design. Builds that need the
96 DSP slices can define `K7_NO_WB_FIR`.

## Transmit: CORDIC saturation (`cordic_z24.v`, `duc_chain.v`)

The DUC shifts frequency with a CORDIC whenever UHD tunes part of the offset
digitally. It keeps two guard bits internally, but its output dropped the top
one without saturating, so a rotated I/Q pair above full scale wrapped to the
opposite sign. That happens when I and Q are both above about 0.86 of full
scale, as with full-scale QPSK or QAM. (Ettus's own comment in `duc_chain.v`
notes the missing headroom.) Measured over the air with a constant A(1+1j)
shifted 1 MHz by the CORDIC (`tools/tx_test.py`):

| A | Carrier, stock → this image | Worst product, stock → this image |
|---|---|---|
| 0.8 | 56.3 → 56.8 dB | −29 → −29 dBc |
| 0.9 | 46.9 → 57.2 dB | +5.7 → −21.9 dBc |
| 1.0 | 39.1 → 57.5 dB | +15.8 → −18.6 dBc |

`cordic_z24` now has a `saturate` parameter, used by the DUC only (the DDC's
input has headroom and is unchanged); `fpga/sim/cordic_sat_tb.v` shows it is
bit-identical below full scale and saturates instead of wrapping above. The
remaining products near A = 1 are ordinary clipping. The transmit halfbands
already rounded and saturated; nothing else in the chain wraps.

Other transmit measurements (same setup, −6 dBFS tone, TX gain 50 dB): LO
leakage −37 dBc, image −47 dBc, ±3rd-order products below −49 dBc (the
measurement floor), gain steps 10.0 dB per 10 dB. Full-duplex note: with the
TX and RX LOs within ~2 MHz of each other the receiver shows strong products
at carrier + k × (LO spacing); they move with the RX tuning, don't change
with RX gain and vanish with the LOs a few MHz apart (AD9361 synthesizer
interaction).

## ADC overload monitor (`adc_monitor.v`)

Peak |I|/|Q|, over-threshold count and sticky flag per AD9361 data slot,
on raw samples. Verified: RX2 antenna on the FM band, peak from −34 to −0.1
dBFS between 20 and 60 dB gain; clipping counted and flagged at 76 dB; the
antenna-less channel stays at the noise floor.
