# Register map

The added blocks sit on **radio 0's user settings bus**, reachable from stock
UHD with the `enable_user_regs` device argument:

```cpp
auto usrp = uhd::usrp::multi_usrp::make("type=b200,enable_user_regs");
auto regs = usrp->get_user_settings_iface(0);
regs->poke32(N * 4, value);        // write register N
uint64_t v = regs->peek64(N * 8);  // read readback N
```

The authoritative description is the header comment of each HDL file.

## GNSS / PPS telemetry, `fpga/top/b200/gnss_pps_telemetry.v` (v1.8)

Tick counts are in radio clock cycles (= the master clock rate) unless noted.

### Write

| N | Name | Bits |
|---|---|---|
| 0 | CTRL | [0] GPS UART RX pin: 0 = B14 (default), 1 = A14 · [1] drive GPS UART TX on the other pin (default 0) · [2] TX from the host bridge instead of UHD's UART · [3] feed the GPS UART to UHD's GPSDO path (set automatically after a successful auto-configuration) · [4] oscillator monitor reference: 0 = GPS PPS, 1 = SMA PPS · [5] CIC droop compensation off, both RX channels (default 0 = on; v1.7+) · [7:6] wideband filter profile at decimation 1, both RX channels: 0 = off (default), 1–3 (v1.8+) · [31:16] UART bit time in 100 MHz cycles (default 2604 = 38400 baud; 0 = UHD's value) |
| 1 | CLEAR | Any write clears counters and the RX ring |
| 2 | TXBYTE | [7:0] byte to send through the host UART bridge |

Don't set CTRL[1] unless the pin it drives shows zero toggles (readback 5):
driving a pin the GPS module also drives is contention. `gnss_status
--ubx-probe` does this check for you.

### Readback

| N | Contents |
|---|---|
| 0 | `{"K7OP", major[15:0], minor[15:0]}` |
| 1 | `{gps_pps_edges, ext_pps_edges}` since clear |
| 2 | `{gps_pps_period, ext_pps_period}` ticks between the last two edges |
| 3 | `{gps_pps_age, ext_pps_age}` ticks since the last edge (saturates) |
| 4 | `{gps_pps_width, ext_pps_width}` high time of the last pulse |
| 5 | `{a14_toggles, b14_toggles}` |
| 6 | `{0, CTRL}` |
| 7 | `{0, ext_valid, gps_valid, pps_ext, pps_gps, b14, a14}`: live levels and PPS health (valid = consistent period, not overdue) |
| 8 | `{a14_min_run, b14_min_run}` shortest level in ticks: baud = master clock / min_run |
| 9 | `{0, rx_total}` bytes received by the bridge since clear |
| 10 | `{0, autocfg_status}` GPS auto-configuration `{nak, ack, sent, skipped}` |
| 11 | `{gps_missed, gps_bad, ext_missed, ext_bad}` 16 bits each: missing pulses and irregular edges since clear |
| 12 | `{good_edges[15:0], tick_sum[47:0]}` oscillator monitor: 100 MHz cycles summed over good PPS periods. Read twice: error = Δsum / (Δedges × 10⁸) − 1 (both wrap) |
| 13 | `{0, last_period}` last good PPS period in 100 MHz cycles |
| 16–47 | RX ring: 256 bytes from the GPS UART, readback 16+i = bytes 8i..8i+7 |

## ADC overload monitor, `fpga/top/b200/adc_monitor.v` (v1.0)

Raw AD9361 samples (before DC/IQ correction), both data slots. With one
channel streaming that channel is in slot 0; with two, UHD channel 0 is in slot
1 and channel 1 in slot 0 (`tools/adc_status` handles this).

| N | Write | Readback |
|---|---|---|
| 64 | CLEAR (any write) | `{"ADCM", major, minor}` |
| 65 | THRESH [11:0], default 2047 (full scale) | slot 0: `{over_count[31:0], 3'b0, sticky, peak[11:0], 4'b0, thresh[11:0]}` |
| 66 | | slot 1, same layout |
| 67 | | `{0, samples[47:0]}` samples since clear |

`peak` is the largest |I| or |Q| (0..2048); `over_count` counts samples with
|I| or |Q| ≥ THRESH; `sticky` is set by the first such sample.

Registers 96–255 are reserved for future blocks.
