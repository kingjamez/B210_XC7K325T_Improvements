# Host tools. Needs UHD (brew install uhd / apt install libuhd-dev).
PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /usr)
CXXFLAGS ?= -std=c++17 -O2 -Wall -pthread
TOOLS := pps_probe gnss_status adc_status

all: $(TOOLS)

%: %.cpp
	$(CXX) $(CXXFLAGS) $< -I$(PREFIX)/include -L$(PREFIX)/lib -luhd -o $@

clean:
	rm -f $(TOOLS)
