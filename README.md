# B210_XC7K325T_Improvements

An open replacement FPGA image for the **USRP B210-compatible clones built on
a Xilinx Kintex-7 XC7K325T + AD9361**. These boards enumerate as an Ettus B210
and run the Ettus B200 FPGA design ported from Spartan-6, which leaves most of
the much larger FPGA unused. This image keeps full compatibility with **stock
UHD** and adds a working GPS, PPS fixes, monitoring, and a cleaner, more
robust FPGA design.

Free and open: FPGA code is LGPL-3.0-or-later (Ettus headers intact), host
tools are GPL-3.0.

**Nothing is flashed.** UHD loads the FPGA image over USB every time it opens
the board (`--args "type=b200,fpga=/path/to/image.bin"`). Trying this image
cannot brick a board; unplugging it or loading another image undoes it.

## What you get

| | Vendor image | This image |
|---|---|---|
| On-board GPS seen by UHD | No ("No GPSDO found") | **Yes**: stock UHD detects a generic NMEA GPS |
| GPS sensors (`gps_locked`, `gps_time`, GGA/RMC) | None | **Available in any UHD application** |
| `time_source=gpsdo` | Rejected | **Works**: device time = GPS time, PPS-aligned |
| GPS PPS vs SMA PPS | Merged into one signal for all time sources; **two edges per second** when both are connected | **Separate**: `gpsdo` = on-board GPS, `external` = SMA, never mixed |
| Internal PPS | Spurious extra edge 250 ms after each real one | Fixed |
| `clock_source=gpsdo` | Rejected | Accepted and safe: oscillator free-runs instead of being pulled ~14 ppm off |
| PPS / GPS / oscillator monitoring | None | PPS health, missed pulses, oscillator error vs GPS (0.01 ppm/s), PPS offset between sources, GPS UART diagnostics |
| ADC overload monitoring | None | Peak level, clip counts and sticky flags per channel |
| FPGA resources | ~56k LUTs, of which ~28k used as RAM by simulation-model FIFOs | ~31k LUTs; proper block-RAM clock-domain-crossing FIFOs with Vivado-checked constraints; much more timing margin |
| DDC halfband outputs | Truncate and can wrap on overflow | Rounded and saturating |

Everything works with stock UHD (no UHD fork, no patched drivers) and stock
applications such as SDR++ and GNU Radio. The added monitoring is read through
UHD's standard user-register interface (`enable_user_regs`) with the small
command-line tools in `tools/`.

## Measured on hardware

Linux (UHD 4.9), one board, with the on-board GPS antenna connected:

- **RX streaming**: 0 dropped samples, overruns or sequence errors in 10 s
  runs at 30.72, 40, 56 and 61.44 MS/s (1 channel) and 2 × 15.36 / 2 × 30.72
  MS/s, full 16-bit samples, with `num_recv_frames=128,recv_frame_size=16360`.
  (The vendor image gives the same throughput; this image does not change it.)
- **GPS**: detected by stock UHD on every open after the first one following a
  power-up; `gps_time` matches the host clock to the second; after
  `set_time_next_pps`, device time follows GPS with every PPS edge 1 s apart.
- **PPS health**: unplugging the GPS antenna marks the PPS invalid within ~1 s
  and counts each missing pulse; it recovers ~2 s after the pulses return.
- **PPS isolation**: with a second GPSDO's PPS on the SMA, `gpsdo` and
  `external` each see only their own source, one edge per second.
- **Oscillator**: free-running error −0.66 ppm on the test board, measured in
  the FPGA against GPS. With an external GPSDO's 10 MHz on 10M IN and
  `clock_source=external`, the error is −0.001 ppm.
- **ADC monitor**: peak tracks RX gain as expected; clipping is counted and
  flagged when the ADC is driven into full scale.

Details: `docs/technical-notes.md`.

## Limitations (please read)

- **Tested on one board.** Other boards of the same clone family are very
  likely identical, but only one has been tested. If a board's GPS is wired
  differently, the GPS auto-configuration does nothing and the board behaves
  like it has no GPS; it never drives a GPS pin it hasn't verified is safe.
- **Transmit is not yet tested on hardware.** The TX path was rebuilt along
  with the receive path (new clock-domain-crossing FIFOs) and passes
  simulation and timing, but no TX test has been run on a board yet. Treat TX
  as experimental with this release.
- **The oscillator is not GPS-disciplined.** `clock_source=gpsdo` gives GPS
  *time* but the 40 MHz oscillator free-runs (about −0.7 ppm on the test
  board: ~700 Hz error at 1 GHz). For frequency accuracy, feed a GPSDO's
  10 MHz into 10M IN and use `clock_source=external`, or correct in software
  using the measured error. True on-board disciplining needs a hardware change
  on these boards (a missing resistor) and is not part of this release.
- **First open after power-up**: UHD's GPS check can run before the FPGA has
  configured the GPS module, so the first open may say "No GPSDO found".
  Open again (or keep the app open): later opens detect it.
- **GPS needs sky view and ~5 minutes after power-up** to get a fix: the
  module has no backup battery on these boards, so every power-up is a cold
  start.
- **One process at a time.** As with any UHD device, only the application
  that has the board open can read GPS sensors and telemetry.
- `gps_servo` is listed by UHD but always errors (it only exists on Ettus's
  own GPSDO module). `ref_locked` can read "locked" even with
  `clock_source=internal`; don't rely on it in that mode.
- **Platforms**: verified on Linux. macOS streaming was verified with the
  vendor image; this image's GPS features on macOS and anything on Windows
  are not yet tested.
- **Building it yourself** needs a Vivado licence that covers the XC7K325T
  (the free Vivado edition does not). See `docs/building.md`.
- Receive DSP: CIC droop compensation is not included yet (work in progress),
  so the passband edges at odd decimation rates roll off as with the stock
  design.

## Quick start

1. Get the image: `release/b210_k7.bin` (check it against `release/SHA256SUMS`),
   or build it yourself (`docs/building.md`).
2. Check the board and image:
   ```bash
   uhd_usrp_probe --args "type=b200,fpga=/path/to/b210_k7.bin"
   ```
   Expect "Found a generic NMEA GPS device" (open twice after a power-up) and
   clock sources `internal, external, gpsdo`.
3. Make it the default for your board so every UHD application uses it
   (`~/.config/uhd.conf`, matched by serial so other USRPs keep their images):
   ```ini
   [serial=YOURSERIAL]
   fpga=/path/to/b210_k7.bin
   num_recv_frames=128
   recv_frame_size=16360
   ```
4. Build the tools and look at the GPS and PPS:
   ```bash
   make -C tools
   tools/gnss_status --seconds 30
   ```

Full instructions: `docs/user-guide.md`. Register map: `docs/registers.md`.

## Repository

| Path | Contents |
|---|---|
| `fpga/top/b200/` | Board top level (7-series port of the Ettus `b200`), pin constraints, new blocks (GPS, PPS, monitors) |
| `fpga/lib/` | The Ettus USRP FPGA library files this design uses |
| `fpga/ip/` | Vivado clock IP (`.xci`) |
| `fpga/scripts/` | Non-project Vivado build (`build.tcl`, `sources.tcl`) |
| `fpga/sim/` | Icarus Verilog testbenches, full-design elaboration check, Vivado xsim test of the FIFOs |
| `sw/dsp_models/` | Python reference models used for bit-exact tests |
| `tools/` | `gnss_status`, `pps_probe`, `adc_status`, `baseline.sh` (stock UHD) |
| `docs/` | User guide, register map, build instructions, technical notes |
| `release/` | Prebuilt image, checksum and release notes |

## Principles

- Stock UHD wherever possible; host-side changes kept small and upstreamable.
- All work original. FPGA code stays LGPL-3.0-or-later with the Ettus
  copyright headers intact; host code is GPL-3.0.
- Measure first: every change in this image was verified in simulation and on
  hardware, and the limitations above are what has *not* been verified yet.

Not affiliated with Ettus Research, National Instruments, AMD/Xilinx, Analog
Devices or u-blox. USRP is a trademark of National Instruments. Provided as
is, without warranty.
