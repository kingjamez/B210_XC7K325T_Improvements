# Icarus Verilog testbenches (brew install icarus-verilog / apt install iverilog)
LIB := ../lib
TOP := ../top/b200

.PHONY: all gnss_pps_telemetry gps_uart_bridge gps_autoconfig adf4001_guard adc_monitor osc_monitor rnd_clip_slice droop_comp clean

all: gnss_pps_telemetry gps_uart_bridge gps_autoconfig adf4001_guard adc_monitor osc_monitor rnd_clip_slice droop_comp

gnss_pps_telemetry:
	iverilog -g2012 -Wall -o build/$@.vvp $@_tb.v $(TOP)/gnss_pps_telemetry.v \
		$(LIB)/control/setting_reg.v $(LIB)/control/synchronizer.v $(LIB)/control/synchronizer_impl.v
	vvp -n build/$@.vvp | tee build/$@.log
	@grep -q '^PASS' build/$@.log

gps_uart_bridge:
	iverilog -g2012 -I $(LIB)/control -o build/$@.vvp $@_tb.v $(TOP)/gps_uart_bridge.v $(TOP)/gnss_pps_telemetry.v \
		$(LIB)/control/setting_reg.v $(LIB)/control/synchronizer.v $(LIB)/control/synchronizer_impl.v \
		$(LIB)/sim/fifo/axi_fifo_2clk_sim.v $(LIB)/control/bin2gray.v $(LIB)/control/gray2bin.v \
		$(LIB)/wishbone/simple_uart_tx.v $(LIB)/wishbone/simple_uart_rx.v \
		$(LIB)/fifo/axi_fifo.v $(LIB)/fifo/axi_fifo_flop.v $(LIB)/fifo/axi_fifo_flop2.v \
		$(LIB)/fifo/axi_fifo_short.v $(LIB)/fifo/axi_fifo_bram.v $(LIB)/control/ram_2port.v
	vvp -n build/$@.vvp | tee build/$@.log
	@grep -q '^PASS' build/$@.log

gps_autoconfig:
	iverilog -g2012 -Wall -o build/$@.vvp $@_tb.v $(TOP)/gps_autoconfig.v
	vvp -n build/$@.vvp | tee build/$@.log
	@grep -q '^PASS' build/$@.log

adf4001_guard:
	iverilog -g2012 -Wall -o build/$@.vvp $@_tb.v $(TOP)/adf4001_guard.v
	vvp -n build/$@.vvp | tee build/$@.log
	@grep -q '^PASS' build/$@.log
	iverilog -g2012 -o build/$@_spi.vvp $@_spi_tb.v $(TOP)/adf4001_guard.v $(LIB)/control/simple_spi_core.v $(LIB)/control/setting_reg.v
	vvp -n build/$@_spi.vvp | tee build/$@_spi.log
	@grep -q '^PASS' build/$@_spi.log

adc_monitor:
	iverilog -g2012 -Wall -o build/$@.vvp $@_tb.v $(TOP)/adc_monitor.v
	vvp -n build/$@.vvp | tee build/$@.log
	@grep -q '^PASS' build/$@.log

osc_monitor:
	iverilog -g2012 -Wall -o build/$@.vvp $@_tb.v $(TOP)/osc_monitor.v
	vvp -n build/$@.vvp | tee build/$@.log
	@grep -q '^PASS' build/$@.log

rnd_clip_slice:
	python3 ../../sw/dsp_models/rnd_clip_slice.py build/rnd_clip_slice_vectors.hex 20000
	iverilog -g2012 -Wall -o build/$@.vvp $@_tb.v $(LIB)/dsp/rnd_clip_slice.v $(LIB)/dsp/clip.v
	vvp -n build/$@.vvp | tee build/$@.log
	@grep -q '^PASS' build/$@.log

droop_comp:
	python3 ../../sw/dsp_models/droop_comp.py vectors build/droop_comp_vectors.txt
	iverilog -g2012 -I $(LIB)/dsp -o build/$@.vvp $@_tb.v $(LIB)/dsp/droop_comp.v $(LIB)/dsp/rnd_clip_slice.v $(LIB)/dsp/clip.v
	vvp -n build/$@.vvp | tee build/$@.log
	@grep -q '^PASS' build/$@.log

clean:
	rm -rf build/*.vvp build/*.log

$(shell mkdir -p build)

# Connectivity check of the full top level with black-box vendor primitives.
# new_rx_framer.v, new_tx_control.v, gpif2_slave_fifo32.v (unmodified Ettus) use signals before
# declaring them; Vivado accepts that, Icarus doesn't, so those are filtered.
PRIMS := DSP48E1 MULT_MACRO SRLC32E hbdec1 hbdec2 BUFR BUFGMUX IDDR ODDR \
         IBUFGDS IBUFDS BUFG IOBUF b200_clk_gen OBUF IBUF xpm_fifo_async xpm_cdc_sync_rst
.PHONY: elab
elab:
	sed -n '/^set VERILOG_SOURCES/,/^}/p' ../scripts/sources.tcl | grep -E '^\s+fpga/' \
		| sed 's#^ *fpga/#../#' | grep -vE 'hbdec[12]\.v$$' > build/files.f
	python3 gen_stubs.py build/stubs.v $(PRIMS) -- $$(cat build/files.f)
	-iverilog -g2005 -DTARGET_B210 -I ../lib/control -I ../lib/dsp -s b200 -o build/b200.vvp \
		-c build/files.f build/stubs.v > build/elab.log 2>&1
	@if grep 'error' build/elab.log | grep -vE 'new_rx_framer\.v|new_tx_control\.v|gpif2_slave_fifo32\.v|error\(s\) during elaboration'; \
		then echo "ELAB FAILED (see build/elab.log)"; exit 1; else echo "ELAB OK"; fi

# XPM-based axi_fifo_2clk (synthesis version) against Xilinx's own XPM models.
# Needs Vivado on PATH (source <vivado>/settings64.sh). ~1-2 min.
.PHONY: xsim
xsim:
	rm -rf build/xsim && mkdir -p build/xsim
	cd build/xsim && xvlog --sv ../../xsim/axi_fifo_2clk_xpm_tb.sv > xvlog.log 2>&1 \
		&& xvlog ../../$(LIB)/fifo/axi_fifo_2clk_xpm.v $$XILINX_VIVADO/data/verilog/src/glbl.v >> xvlog.log 2>&1 \
		&& xelab -L xpm -debug off --timescale 1ns/1ps axi_fifo_2clk_xpm_tb glbl -s tb > xelab.log 2>&1 \
		&& xsim tb -R > xsim.log 2>&1; grep -E 'FAIL|PASS|words:' xsim.log
	@grep -q '^PASS' build/xsim/xsim.log
