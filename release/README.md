# Prebuilt image

`b210_k7.bin`: built from this repository with Vivado 2024.1
(`cd fpga && make`), xc7k325tffg676-2, timing met including the USB (FX3)
interface against the FX3 datasheet. Verify the download against
`SHA256SUMS` (`sha256sum -c SHA256SUMS`).

| | |
|---|---|
| GNSS/PPS telemetry | v1.8 (`docs/registers.md`) |
| ADC monitor | v1.0 |
| UHD compat | 16.0 (stock UHD sees a B210) |
| Utilization | 32.2k LUTs (15.8%), 89.5 BRAM tiles (20%), 232 DSP (28%) |

## Changes in this release

- **Transmit: no more wrap-around at full scale.** The TX frequency shifter
  (CORDIC) wrapped to the opposite sign when I and Q were both near full scale
  (full-scale QPSK/QAM with any digital tuning offset): the carrier collapsed
  by up to 17 dB with products up to +16 dBc. It now saturates; measured over
  the air the carrier holds and products stay at −19 to −22 dBc even when
  driven past full scale.
- **Wideband filter profiles** at decimation 1 (56–61.44 MS/s, where the
  AD9361 leaves the band edges open): three 33-tap profiles with 45–61 dB stop
  bands, selected with telemetry CTRL[7:6]. Off by default (no change unless
  you turn one on).
- **Transmit measured over the air** at low power: LO leakage −37 dBc, image
  −47 dBc, third-order products below −49 dBc, linear gain.
- New tools: `tools/tx_test.py` (transmit checks, transmits) and
  `tools/wb_test.py` (wideband profiles).

Previous release: USB interface timing fix, CIC droop compensation, TX
streaming tested.

Tested on hardware (one board, Linux, UHD 4.9): 20/20 UHD opens, GPS detection
and telemetry, RX streaming up to 61.44 MS/s and 2 × 30.72 MS/s with zero
drops, TX / full duplex with no lost packets, droop compensation within
0.11 dB of its design, wideband profiles, transmit tests above. See the
limitations in the top-level `README.md`.

Load it with `--args "type=b200,fpga=/path/to/b210_k7.bin"` or a `uhd.conf`
entry (`docs/user-guide.md`). Nothing is written to the board.
