# B210_XC7K325T_Improvements

Open FPGA and host improvements for the **USRP B210-compatible clone built on
a Xilinx Kintex-7 XC7K325T + AD9361**. These boards ship with the Ettus B200
FPGA design ported from Spartan-6, which leaves about 85% of the much larger
FPGA unused. This project puts that headroom to work while staying compatible
with **stock UHD** on Linux, macOS and Windows.

## Status

Working on hardware:

- Stock UHD 4.x streams **61.44 MS/s (1 channel) and 2 × 30.72 MS/s with full
  16-bit samples** on macOS with zero drops. It only needs larger USB frames
  (`num_recv_frames=128,recv_frame_size=16360`).
- New FPGA image with **GPS/PPS telemetry** readable through stock UHD
  (`enable_user_regs`): PPS edge counts, period, width and age; GPS UART pin
  and baud detection; and a UART bridge to the onboard u-blox MAX-M10S.
- Fixed a spurious internal PPS edge 250 ms after each real one (upstream
  Ettus `pps_generator`).
- Measured the 40 MHz VCTCXO against GPS PPS: free-running offset −0.68 ppm,
  steerable ~13 ppm through the onboard ADF4001 loop.

In progress:

- GPS detected by stock UHD (`gpsdo` time source, `gps_*` sensors).
- GPS-disciplined oscillator.
- Cleaner receive DSP: CIC rounding and saturation, droop compensation,
  wideband filtering for 56 MS/s.
- Block-RAM FIFOs in place of LUT RAM.
- An SDR++ source module, with macOS as a first-class target.

Source, build scripts (Vivado 2024.1) and documentation will be published
here as each piece is verified on hardware.

## Principles

- Stock UHD wherever possible; any host changes kept small and upstreamable.
- All work original. FPGA code stays under LGPL-3.0-or-later with the Ettus
  copyright headers intact; host code is GPL-3.0.
- Nothing is flashed: the FPGA image loads over USB each time UHD opens the
  device (`--args "type=b200,fpga=/path/to/image.bin"`), so trying an image
  can't brick a board.

Not affiliated with Ettus Research, National Instruments, AMD/Xilinx,
Analog Devices or u-blox. USRP is a trademark of National Instruments.
