// SPDX-License-Identifier: LGPL-3.0-or-later
// adf4001_guard driven by the real Ettus simple_spi_core, programmed the way
// UHD's spi_core_3000 does it for the ADF4001 (24 bits, MOSI on the rising
// edge, slave 1), at several SPI clock dividers.
`timescale 1ns/1ps
module adf4001_guard_spi_tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg        set_stb = 0;
  reg  [7:0] set_addr = 0;
  reg [31:0] set_data = 0;
  wire       ready;
  wire [7:0] sen;
  wire       sclk, mosi;
  reg        force_free_run = 0;

  simple_spi_core #(.BASE(8), .WIDTH(8), .CLK_IDLE(0), .SEN_IDLE(8'hFF)) spi (
    .clock(clk), .reset(rst), .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
    .readback(), .readback_stb(), .ready(ready),
    .sen(sen), .sclk(sclk), .mosi(mosi), .miso(1'b0), .debug());

  wire pll_le, pll_sclk, pll_mosi, forced;
  adf4001_guard guard (.clk(clk), .rst(rst), .sen_n(sen[1]), .sclk(sclk), .mosi(mosi),
    .force_free_run(force_free_run), .pll_le(pll_le), .pll_sclk(pll_sclk),
    .pll_mosi(pll_mosi), .forced(forced));

  // Reference: what the ADF4001 would latch with the original direct wiring
  wire ref_le = sen[1], ref_sclk = ~sen[1] & sclk, ref_mosi = ~sen[1] & mosi;
  reg [23:0] ref_sh = 0, ref_word = 0;
  always @(posedge ref_sclk) if (!ref_le) ref_sh <= {ref_sh[22:0], ref_mosi};
  always @(posedge ref_le) ref_word <= ref_sh;

  // ADF4001 model behind the guard
  reg [23:0] adf_sh = 0, adf_word = 0;
  integer adf_loads = 0;
  always @(posedge pll_sclk) if (!pll_le) adf_sh <= {adf_sh[22:0], pll_mosi};
  always @(posedge pll_le) begin adf_word <= adf_sh; adf_loads = adf_loads + 1; end

  integer errors = 0;
  task check(input [8*48-1:0] name, input [31:0] got, input [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %0s: got 0x%06h expected 0x%06h", name, got, exp);
      errors = errors + 1;
    end else $display("ok   %0s", name);
  endtask

  task poke(input [7:0] a, input [31:0] d);
    begin
      @(posedge clk); set_stb <= 1; set_addr <= a; set_data <= d;
      @(posedge clk); set_stb <= 0;
    end
  endtask

  // spi_core_3000: divider, then ctrl, then data (left-justified) triggers
  task uhd_spi(input [15:0] div, input [23:0] w);
    integer t;
    begin
      poke(8 + 0, div);
      poke(8 + 1, {1'b0 /*mosi_edge RISE: bit 31 only for FALL*/, 1'b1 /*miso RISE*/, 6'd24, 24'h000002 /*slave 1*/});
      poke(8 + 2, {w, 8'h00});
      repeat (5) @(posedge clk);
      t = 0; while (!ready && t < 10000000) begin @(posedge clk); t = t + 1; end
    end
  endtask

  task xfer(input [8*40-1:0] name, input [15:0] div, input [23:0] w, input [23:0] exp);
    integer l0;
    begin
      l0 = adf_loads;
      uhd_spi(div, w);
      repeat (2000) @(posedge clk);    // let the guard replay
      check({name, " (direct wiring)"}, ref_word, w);
      check({name, " loads"}, adf_loads - l0, 1);
      check(name, adf_word, exp);
    end
  endtask

  localparam [23:0] FUNC_LOCK = 24'h1F80A2;   // addr 2, bit 8 = 0 (CP normal)
  localparam [23:0] RCNT      = 24'h000104;

  integer d;
  reg [15:0] divs [0:3];
  initial begin
    divs[0] = 1; divs[1] = 2; divs[2] = 10; divs[3] = 100;
    repeat (5) @(posedge clk); rst = 0; repeat (5) @(posedge clk);
    for (d = 0; d < 4; d = d + 1) begin
      $display("-- divider %0d", divs[d]);
      force_free_run = 0;
      xfer("pass func", divs[d], FUNC_LOCK, FUNC_LOCK);
      xfer("pass R",    divs[d], RCNT, RCNT);
      force_free_run = 1;
      xfer("force func", divs[d], FUNC_LOCK, FUNC_LOCK | 24'h100);
      xfer("R untouched", divs[d], RCNT, RCNT);
    end
    // UHD program_regs(): latches 3, 2, 0, 1 back to back, no gaps, every divider
    for (d = 0; d < 4; d = d + 1) begin : burst
      integer l0;
      $display("-- burst, divider %0d", divs[d]);
      force_free_run = 1;
      l0 = adf_loads;
      uhd_spi(divs[d], 24'h1F80A3); uhd_spi(divs[d], 24'h1F80A2);
      uhd_spi(divs[d], RCNT);       uhd_spi(divs[d], 24'h000A01);
      repeat (4000) @(posedge clk);
      check("burst: 4 words loaded", adf_loads - l0, 4);
      check("burst: last word is N, bit 8 forced", adf_word, 24'h000B01);
    end
    if (errors == 0) $display("PASS"); else $display("FAILED with %0d errors", errors);
    $finish;
  end
endmodule
