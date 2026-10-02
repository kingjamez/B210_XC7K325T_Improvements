VIVADO ?= vivado

.PHONY: all clean

all:
	mkdir -p build && cd .. && $(VIVADO) -mode batch -nojournal -log fpga/build/vivado.log -source fpga/scripts/build.tcl

clean:
	rm -rf build .Xil
