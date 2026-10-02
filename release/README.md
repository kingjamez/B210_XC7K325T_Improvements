# Prebuilt image

`b210_k7.bin`: built from this repository with Vivado 2024.1
(`cd fpga && make`), xc7k325tffg676-2, timing met (setup slack +2.35 ns).
Verify the download against `SHA256SUMS` (`sha256sum -c SHA256SUMS`).

| | |
|---|---|
| GNSS/PPS telemetry | v1.6 (`docs/registers.md`) |
| ADC monitor | v1.0 |
| UHD compat | 16.0 (stock UHD sees a B210) |
| Utilization | 31.4k LUTs (15%), 89 BRAM tiles (20%), 100 DSP (12%) |

Tested on hardware (one board, Linux, UHD 4.9): UHD open and GPS detection,
GPS/PPS telemetry, oscillator monitor, ADC monitor, RX streaming up to 61.44
MS/s with zero drops. **TX not yet tested on hardware.** See the limitations
in the top-level `README.md`.

Load it with `--args "type=b200,fpga=/path/to/b210_k7.bin"` or a `uhd.conf`
entry (`docs/user-guide.md`). Nothing is written to the board.
