# User guide

For the Kintex-7 XC7K325T + AD9361 B210-compatible clones. These boards
enumerate as an Ettus B210 (USB ID `2500:0020`) but need a Kintex-7 FPGA image:
UHD's stock `usrp_b210_fpga.bin` is a Spartan-6 image and will not load on them
(UHD reports an error such as `fx3 is in state 5`).

## 1. Requirements

- UHD 4.x (tested with 4.9 on Linux and 4.10 on macOS) and a USB 3 port.
- `libuhd` development headers to build the tools (`libuhd-dev` on Debian/Ubuntu,
  `libuhd` on Arch, Homebrew `uhd` on macOS), a C++17 compiler and `make`.
- The image `b210_k7.bin` (`release/` in this repository, or build it: `docs/building.md`).
- For GPS: the GPS antenna connected, with sky view.

## 2. Loading the image

UHD loads the FPGA image every time it opens the board; nothing is written to
the board. Pass the image explicitly:

```bash
uhd_usrp_probe --args "type=b200,fpga=/path/to/b210_k7.bin"
```

or make it the default for this board in UHD's user config file,
`~/.config/uhd.conf` (Windows: `%APPDATA%\uhd.conf`). Match on the board's
serial (shown by `uhd_find_devices`) so other USRPs keep their own images:

```ini
[serial=YOURSERIAL]
fpga=/path/to/b210_k7.bin
num_recv_frames=128
recv_frame_size=16360
```

Every UHD application (SDR++, GNU Radio, your own code) then uses it without
extra arguments. Arguments an application passes explicitly still take
precedence. Repeat the section for each board.

`num_recv_frames=128,recv_frame_size=16360` lets stock UHD stream up to
61.44 MS/s (1 channel) and 2 × 30.72 MS/s without drops; with UHD's defaults
drops start above about 40 MS/s.

## 3. GPS and timing

On every FPGA load the image configures the on-board u-blox MAX-M10S (which has
no backup battery and forgets its settings at power-off) so that stock UHD
recognises it as a generic NMEA GPS. It checks that the GPS pins are wired as
expected first, and never drives a pin the module is driving.

What you get in UHD:

| | |
|---|---|
| Sensors | `gps_locked`, `gps_time` (UTC seconds), `gps_gpgga`, `gps_gprmc` (raw sentences: they contain your position) |
| `time_source=gpsdo` | Device time latched by the on-board GPS PPS |
| `time_source=external` | Device time latched by the PPS on the SMA input |
| `clock_source=internal` | Free-running 40 MHz oscillator |
| `clock_source=external` | Locked to a 10 MHz reference on 10M IN |
| `clock_source=gpsdo` | Accepted, but the oscillator free-runs (see limitations) |

Setting device time to GPS time (UHD C++):

```cpp
usrp->set_time_source("gpsdo");
// wait for a PPS edge, then
const auto t = usrp->get_mboard_sensor("gps_time").to_int();
usrp->set_time_next_pps(uhd::time_spec_t(double(t + 1)));
```

Notes:

- After a power-up the module needs about 5 minutes with sky view for a fix;
  `gps_time` is correct before `gps_locked` turns true.
- The first open after a power-up may print "No GPSDO found": UHD checked
  before the FPGA finished configuring the module. Open again.
- The GPS PPS and the SMA PPS are fully separate. Connecting both is fine.
- `gps_servo` always errors (it exists only on Ettus's own GPSDO module).

## 4. Frequency accuracy

The 40 MHz oscillator is not GPS-disciplined in this release. Its error is
measured continuously against the GPS PPS and shown by `tools/gnss_status`.
Options:

- Feed a GPSDO's 10 MHz into **10M IN** and use `clock_source=external`
  (measured: −0.001 ppm against GPS).
- Correct in software using the measured error (e.g. a tuning offset).

## 5. Tools

Build: `make -C tools` (needs libuhd headers). All are receive-only except
`gpif_stress.py --tx`.

### `tools/gnss_status`

GPS/PPS telemetry, once per second:

```bash
tools/gnss_status [--fpga PATH] [--seconds N] [--clock internal|external|gpsdo]
```

Shows PPS edges, period (ppm), pulse width and age for the GPS and SMA PPS;
PPS health (VALID, missed and bad-edge counts); the offset between the two
PPS edges when both are present; the oscillator error against GPS (last
second and running mean); the GPS auto-configuration status; and GPS UART
activity and baud rate.

Advanced (talk to the GPS module directly; they check the TX pin is idle
first and refuse otherwise):

| Option | Does |
|---|---|
| `--ubx-probe` | Ask the module for its firmware version (UBX-MON-VER) |
| `--ubx-config` | Re-send the configuration the FPGA applies at load |
| `--ubx-reset` | Cold-reset the module to its power-up defaults |
| `--osc-ref gps\|ext` | Measure the oscillator against the GPS or the SMA PPS |

### `tools/pps_probe`

Latches the FPGA time on each PPS edge of the selected time source and prints
the oscillator error:

```bash
tools/pps_probe --fpga PATH --source gpsdo|external|internal --seconds 30 [--clock internal|external]
```

### `tools/adc_status`

ADC overload monitor while streaming (samples are discarded):

```bash
tools/adc_status --freq 98.1e6 --rate 10e6 --gain 50 --channels 0|1|0,1 [--ant RX2|TX/RX] [--thresh N]
```

Per channel: peak (dBFS), samples at or above the threshold (default full
scale = clipping) and a sticky "CLIPPED" flag. Use it to set RX gain.

### `tools/baseline.sh`

RX throughput benchmark using UHD's `benchmark_rate`
(`BENCH=/path/to/benchmark_rate` if your UHD package has no examples).

### `tools/gpif_stress.py`

USB interface check for an image (Python UHD bindings):

```bash
tools/gpif_stress.py --fpga PATH [--opens 20]          # repeated opens, receive only
tools/gpif_stress.py --fpga PATH --tx                  # also TX / full-duplex streams
```

Each open runs UHD's full initialization (USB interface and codec reset;
UHD loads the image only if it differs from the one already loaded). `--tx` **transmits**: zero-valued samples
(only carrier leakage) at 915 MHz and 0 dB gain by default (`--tx-freq`,
`--tx-gain`); use a 50 Ω load or make sure that is legal where you are. It
counts TX sequence errors (packets lost or corrupted on the way to the FPGA),
underflows, RX overflows and drops; all should be 0.

### `tools/droop_test.py`

Measures the receive passband with droop compensation off and on, receive
only, on a channel **without an antenna** (default channel 1): the receiver's
own noise floor is the flat test signal.

```bash
tools/droop_test.py [--fpga PATH] [--channel 1] [--decims 15,127,6,254,12,1]
```

Prints, per decimation, the expected droop, how closely the measured on/off
ratio matches the design model, and the passband ripple off and on.

### Turning droop compensation off

It is on by default. Telemetry CTRL bit 5 turns it off for both channels
(read-modify-write, the other CTRL bits matter; re-apply after each open):

```python
import uhd
u = uhd.usrp.MultiUSRP("type=b200,enable_user_regs")
regs = u.get_user_settings_iface(0)
ctrl = regs.peek64(6 * 8) & 0xFFFFFFFF   # readback 6 = CTRL
regs.poke32(0, ctrl | 0x20)               # off;  ctrl & ~0x20 = on
```

## 6. SDR++ and other applications

No changes are needed. With the `uhd.conf` section above, SDR++'s USRP source
opens the board with this image and its **Clock** selector offers `internal`,
`external` and `gpsdo`. Only one application can have the board open at a
time.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `fx3 is in state 5`, or the FPGA load fails | A Spartan-6 image was loaded. Pass `fpga=` or add the `uhd.conf` section |
| "No GPSDO found" | First open after power-up (open again), or GPS not connected / not wired as expected (`gnss_status` shows the auto-configuration status) |
| `set_clock_source("gpsdo")` throws | That session did not detect the GPS; open again |
| Dropped samples at high rates | Add `num_recv_frames=128,recv_frame_size=16360` |
| PPS shows invalid | No GPS fix yet, antenna disconnected, or nothing on the SMA |
| UHD fails to open: "packet parse error" or an ack timeout while initializing the codec | With this image's USB interface constraints this should not happen; with an image you built yourself, check that the build finished with timing met (it stops otherwise), then run `tools/gpif_stress.py` |
