// SPDX-License-Identifier: LGPL-3.0-or-later
// adf4001_guard: words pass through unchanged, except function/init latches
// get the charge pump three-stated while force_free_run is set.
`timescale 1ns/1ps
module adf4001_guard_tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg sen_n = 1, sclk = 0, mosi = 0, force_free_run = 0;
  wire pll_le, pll_sclk, pll_mosi, forced;

  adf4001_guard dut (.clk(clk), .rst(rst), .sen_n(sen_n), .sclk(sclk), .mosi(mosi),
    .force_free_run(force_free_run), .pll_le(pll_le), .pll_sclk(pll_sclk),
    .pll_mosi(pll_mosi), .forced(forced));

  // ADF4001 model: shift on SCLK rising, load on LE rising
  reg [23:0] adf_sh = 0, adf_latched = 0;
  integer adf_loads = 0;
  always @(posedge pll_sclk) if (!pll_le) adf_sh <= {adf_sh[22:0], pll_mosi};
  always @(posedge pll_le) begin adf_latched <= adf_sh; adf_loads = adf_loads + 1; end

  integer errors = 0;
  task check(input [8*40-1:0] name, input [31:0] got, input [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %0s: got 0x%06h expected 0x%06h", name, got, exp);
      errors = errors + 1;
    end else $display("ok   %0s", name);
  endtask

  // UHD side, like simple_spi_core: MSB first, data changes with SCLK low.
  // Driven on negedge so the DUT's edge detector samples settled signals.
  task uhd_write(input [23:0] w);
    integer i;
    begin
      sen_n = 0; repeat (7) @(negedge clk);
      for (i = 23; i >= 0; i = i - 1) begin
        sclk = 0; mosi = w[i]; repeat (5) @(negedge clk);
        sclk = 1;              repeat (5) @(negedge clk);
      end
      sclk = 0; repeat (5) @(negedge clk);
      sen_n = 1; repeat (2000) @(negedge clk);   // replay finishes well before the next word
    end
  endtask

  task xfer(input [8*40-1:0] name, input [23:0] w, input [23:0] exp);
    integer loads0;
    begin
      loads0 = adf_loads;
      uhd_write(w);
      check({name, " loaded once"}, adf_loads - loads0, 1);
      check(name, adf_latched, exp);
    end
  endtask

  // Words as UHD builds them (addr in [1:0]); bit 8 of latches 2/3 = CP mode
  localparam [23:0] INIT_LOCK  = 24'h1F80A3 & ~24'h100;  // addr 3, CP normal
  localparam [23:0] FUNC_LOCK  = 24'h1F80A2 & ~24'h100;  // addr 2, CP normal
  localparam [23:0] FUNC_TRI   = 24'h1F81A2;             // addr 2, CP three-state
  localparam [23:0] RCNT       = 24'h000104;             // addr 0, bit 8 set (R counter bits)
  localparam [23:0] NCNT       = 24'h000A01;             // addr 1, N counter

  initial begin
    repeat (5) @(posedge clk); rst = 0;

    // 1. Pass-through when not forcing (clock_source internal / external)
    xfer("pass init",  INIT_LOCK, INIT_LOCK);
    xfer("pass func",  FUNC_LOCK, FUNC_LOCK);
    xfer("pass R",     RCNT, RCNT);
    xfer("pass N",     NCNT, NCNT);
    check("not forced yet", forced, 0);

    // 2. clock_source=gpsdo: lock requests become three-state
    force_free_run = 1;
    xfer("force init", INIT_LOCK, INIT_LOCK | 24'h100);
    xfer("force func", FUNC_LOCK, FUNC_LOCK | 24'h100);
    xfer("R (bit 8 already set)", RCNT, RCNT);
    xfer("N gets bit 8 (harmless while three-stated)", NCNT, NCNT | 24'h100);
    xfer("tri stays tri", FUNC_TRI, FUNC_TRI);
    check("forced flag", forced, 1);

    // 3. Back to external: pass-through again
    force_free_run = 0;
    xfer("pass func again", FUNC_LOCK, FUNC_LOCK);

    if (errors == 0) $display("PASS"); else $display("FAILED with %0d errors", errors);
    $finish;
  end
endmodule
