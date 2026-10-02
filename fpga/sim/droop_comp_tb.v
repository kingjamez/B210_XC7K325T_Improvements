// SPDX-License-Identifier: LGPL-3.0-or-later
// droop_comp vs the Python model (sw/dsp_models/droop_comp.py): bit-exact,
// several (H, R) sets, pass-through cases, saturation.
`timescale 1ns/1ps
module droop_comp_tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg        enable = 1, hb1 = 0, hb2 = 0, stb = 0;
  reg  [7:0] rate = 1;
  reg  [23:0] xi = 0, xq = 0;
  wire        ostb;
  wire [23:0] yi, yq;
  droop_comp dut (.clk(clk), .rst(rst), .enable(enable), .cic_rate(rate),
    .hb1_en(hb1), .hb2_en(hb2), .strobe_in(stb), .i_in(xi), .q_in(xq),
    .strobe_out(ostb), .i_out(yi), .q_out(yq));

  // expected outputs, FIFO
  reg [23:0] expq [0:1023];
  integer wr = 0, rd = 0, errors = 0, checked = 0, skip = 0;
  always @(posedge clk) if (ostb) begin
    if (skip > 0) skip = skip - 1;
    else if (rd < wr) begin
      if (yi !== expq[rd % 1024] || yq !== expq[rd % 1024]) begin
        if (errors < 10) $display("FAIL #%0d: i=%h q=%h expected i=%h", rd, yi, yq, expq[rd % 1024]);
        errors = errors + 1;
      end
      rd = rd + 1; checked = checked + 1;
    end
  end

  task send(input [23:0] v);   // one sample every 3 clocks; Q = I
    begin
      @(negedge clk); xi = v; xq = v; stb = 1;
      @(negedge clk); stb = 0;
      @(negedge clk);
    end
  endtask

  integer fd, r, en, hi, rt, k;
  reg [23:0] x, y;
  reg [8*8-1:0] tag;
  initial begin
    repeat (4) @(posedge clk); rst = 0;
    fd = $fopen("build/droop_comp_vectors.txt", "r");
    if (fd == 0) begin $display("FAILED: no vectors"); $finish; end
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%s", tag);
      if (r != 1) begin end
      else if (tag == "C") begin
        r = $fscanf(fd, "%d %d %d", en, hi, rt);
        // drain, reconfigure, wait for the coefficient reload, flush history
        repeat (40) @(posedge clk);
        while (rd < wr) @(posedge clk);
        enable = en; hb1 = (hi >= 1); hb2 = (hi == 2); rate = rt;
        repeat (30) @(posedge clk);
        skip = 13;
        for (k = 0; k < 13; k = k + 1) send(24'd0);
        repeat (20) @(posedge clk);
        $display("case enable=%0d hidx=%0d rate=%0d", en, hi, rt);
      end else begin
        r = $sscanf(tag, "%h", x);
        r = $fscanf(fd, "%h", y);
        expq[wr % 1024] = y; wr = wr + 1;
        send(x);
      end
    end
    repeat (40) @(posedge clk);
    $display("%0d samples checked, %0d mismatches", checked, errors);
    if (errors == 0 && checked > 3000) $display("PASS"); else $display("FAILED");
    $finish;
  end
endmodule
