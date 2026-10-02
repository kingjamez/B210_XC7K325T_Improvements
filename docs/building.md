# Building

## Licence requirement

The XC7K325T is **not** supported by the free Vivado edition (ML Standard).
Building needs **Vivado 2024.1 ML Enterprise** or another licence that covers
this device (AMD offers a time-limited evaluation licence).

## FPGA image

```bash
cd fpga && make          # non-project Vivado flow, ~25-30 min
```

Output: `fpga/build/b210_k7.bin`, plus utilization and timing reports in
`fpga/build/`. The script refuses to write a bitstream if timing is not met.
Vivado must be on `PATH` (`source <vivado>/settings64.sh`) or pass
`VIVADO=/path/to/vivado`.

Vivado writes a `B210_Project_Firmwire.gen/` folder and `clockInfo.txt` in the
repository root during the build (both are git-ignored).

## Simulation (run before every build: seconds, not minutes)

```bash
make -C fpga/sim          # Icarus Verilog testbenches, must print PASS
make -C fpga/sim elab     # full-design elaboration check, must print ELAB OK
make -C fpga/sim xsim     # FIFO wrapper against Xilinx's XPM models (needs Vivado)
```

Needs Icarus Verilog (`iverilog`) and Python 3. Bit-exact tests compare the
HDL against reference models in `sw/dsp_models/`.

Many library files use CRLF line endings; keep them CRLF when editing.

## Tools

```bash
make -C tools             # needs libuhd headers, C++17
```
