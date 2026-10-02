//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Sits between UHD's SPI master (simple_spi_core, slave 1) and the ADF4001
// reference PLL that steers the 40 MHz VCTCXO.
//
// Why: UHD's clock_source=gpsdo sets ref_sel=1 (mux input 2, the GPSDO
// module's 10 MHz on a real B210) and tells the ADF4001 to lock. This board
// has no GPSDO 10 MHz there, so the loop drives the VCTCXO to the end of its
// range: -13.9 ppm measured. The u-blox has no 10 MHz output.
//
// What: a pass-through, wired exactly like the original (LE = slave select,
// SCLK and MOSI gated by it), so UHD's own SPI waveform reaches the chip.
// While force_free_run is set (sampled at the start of each transfer), MOSI
// is forced to 1 during bit 8 of the 24-bit word (the 16th bit sent, MSB
// first). In the function and initialization latches (address 2, 3) bit 8 is
// the charge pump mode, 1 = three-state, which is what UHD itself programs
// for clock_source=internal: the VCTCXO free-runs. Register layout as UHD
// programs it (host/lib/usrp/common/adf4001_ctrl.cpp).
//
// The address bits come last, so the R and N counter words (address 0, 1)
// get bit 8 set as well. That is harmless: with the charge pump three-stated
// the counters do nothing, and UHD rewrites all four latches, with ref_sel=0
// first, when the clock source changes to external.
//
// The forcing window opens and closes on SCLK falling edges, when UHD changes
// MOSI (mosi_edge = rising for the ADF4001), so the level is stable around
// the ADF4001's sampling (rising) edge. An earlier version captured and
// replayed words at 12.5 MHz; on this board that corrupted the ADF4001
// (false lock, +15.7 ppm), so the waveform is no longer regenerated.
//
// All signals are in bus_clk, the clock simple_spi_core generates sclk from.

module adf4001_guard (
  input  clk,
  input  rst,
  // from UHD's SPI master
  input  sen_n,          // slave select for the ADF4001 (active low)
  input  sclk,
  input  mosi,
  // policy
  input  force_free_run, // 1 = keep the charge pump three-stated
  // to the ADF4001
  output pll_le,
  output pll_sclk,
  output pll_mosi,
  output reg forced = 1'b0   // a 0 in bit 8 was overridden since reset
);

  reg       sclk_q = 1'b0, sen_q = 1'b1;
  reg [5:0] rises  = 6'd0;
  reg       f_xfer = 1'b0;     // policy for the current transfer
  reg       win    = 1'b0;     // bit 8 is on MOSI

  wire rise = sclk & ~sclk_q;
  wire fall = ~sclk & sclk_q;

  always @(posedge clk) begin
    sclk_q <= sclk;
    sen_q  <= sen_n;
    if (sen_n) begin
      rises <= 6'd0;
      win   <= 1'b0;
    end else begin
      if (sen_q) f_xfer <= force_free_run;           // start of transfer
      if (rise) rises <= rises + 1'b1;
      if (fall) win <= f_xfer && (rises == 6'd15);   // after 15 bits: bit 8 is next
      if (win && rise && !mosi && !rst) forced <= 1'b1;
    end
    if (rst) forced <= 1'b0;
  end

  assign pll_le   = sen_n;
  assign pll_sclk = ~sen_n & sclk;
  assign pll_mosi = ~sen_n & (mosi | win);

endmodule
