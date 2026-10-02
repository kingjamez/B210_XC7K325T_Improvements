// SPDX-License-Identifier: LGPL-3.0-or-later
// wb_fir vs the Python model (sw/dsp_models/wb_fir.py): bit-exact, a sample on
// every clock (decimation 1), all profiles, bypass, inactive, saturation.
`timescale 1ns/1ps
module wb_fir_tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg        active = 0, stb = 0;
  reg  [1:0] prof = 0;
  reg  [23:0] xi = 0;
  wire        ostb;
  wire [23:0] yi, yq;
  wb_fir dut (.clk(clk), .rst(rst), .profile(prof), .active(active),
    .strobe_in(stb), .i_in(xi), .q_in(~xi),
    .strobe_out(ostb), .i_out(yi), .q_out(yq));

  reg [23:0] expq [0:4095];
  integer wr = 0, rd = 0, errors = 0, checked = 0, skip = 0;
  always @(posedge clk) if (ostb) begin
    if (skip > 0) skip = skip - 1;
    else if (rd < wr) begin
      if (yi !== expq[rd % 4096]) begin
        if (errors < 10) $display("FAIL #%0d: i=%h expected %h", rd, yi, expq[rd % 4096]);
        errors = errors + 1;
      end
      rd = rd + 1; checked = checked + 1;
    end
  end

  integer fd, r, pr, ac, k;
  reg [23:0] x, y;
  reg [8*8-1:0] tag;
  initial begin
    repeat (4) @(posedge clk); rst = 0;
    fd = $fopen("build/wb_fir_vectors.txt", "r");
    if (fd == 0) begin $display("FAILED: no vectors"); $finish; end
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%s", tag);
      if (r != 1) begin end
      else if (tag == "C") begin
        r = $fscanf(fd, "%d %d", pr, ac);
        @(negedge clk); stb = 0;
        repeat (30) @(posedge clk);
        while (rd < wr) @(posedge clk);
        prof = pr; active = ac;
        repeat (6) @(posedge clk);
        // flush the history with 33 zeros, then stream on every clock
        skip = 33;
        for (k = 0; k < 33; k = k + 1) begin @(negedge clk); xi = 0; stb = 1; end
        $display("case profile=%0d active=%0d", pr, ac);
      end else begin
        r = $sscanf(tag, "%h", x);
        r = $fscanf(fd, "%h", y);
        expq[wr % 4096] = y; wr = wr + 1;
        @(negedge clk); xi = x; stb = 1;
      end
    end
    @(negedge clk); stb = 0;
    repeat (40) @(posedge clk);
    $display("%0d samples checked, %0d mismatches", checked, errors);
    if (errors == 0 && checked > 2000) $display("PASS"); else $display("FAILED");
    $finish;
  end
endmodule
