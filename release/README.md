# Prebuilt image

`b210_k7.bin`: built from this repository with Vivado 2024.1
(`cd fpga && make`), xc7k325tffg676-2, timing met including the USB (FX3)
interface against the FX3 datasheet. Verify the download against
`SHA256SUMS` (`sha256sum -c SHA256SUMS`).

| | |
|---|---|
| GNSS/PPS telemetry | v1.7 (`docs/registers.md`) |
| ADC monitor | v1.0 |
| UHD compat | 16.0 (stock UHD sees a B210) |
| Utilization | 31.6k LUTs (15.5%), 89 BRAM tiles (20%), 136 DSP (16%) |

## Changes in this release

- **USB interface timing fixed.** The FX3 ↔ FPGA interface was never
  timing-constrained in the vendor port, so whether UHD could open the board
  reliably depended on how each build happened to be placed. Its registers are
  now in the I/O cells, the interface clock phase is centred, and the build is
  checked against the FX3 datasheet (`docs/technical-notes.md`). The previous
  image worked on the test board, but with no margin; please update.
- **CIC droop compensation.** The receive passband is now flat to 0.4 × the
  sample rate at every decimation (it used to roll off by up to 9.7 dB at odd
  decimations). On by default; telemetry CTRL bit 5 turns it off.
- **Transmit data path tested** on hardware: TX and full-duplex streaming up
  to 61.44 MS/s with no lost or corrupted packets (RF output not yet
  characterized).
- New tools: `tools/gpif_stress.py` (USB interface check, optional TX) and
  `tools/droop_test.py` (passband measurement).

Tested on hardware (one board, Linux, UHD 4.9): 20/20 UHD opens, GPS
detection and telemetry, oscillator monitor, ADC monitor, RX streaming up to
61.44 MS/s and 2 × 30.72 MS/s with zero drops, TX / full duplex as above,
passband before/after. See the limitations in the top-level `README.md`.

Load it with `--args "type=b200,fpga=/path/to/b210_k7.bin"` or a `uhd.conf`
entry (`docs/user-guide.md`). Nothing is written to the board.
