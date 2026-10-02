// SPDX-License-Identifier: LGPL-3.0-or-later
// cordic_z24 saturate=1 vs the original (saturate=0), wired as in duc_chain
// (18-bit samples in the top of a 24-bit word), rotating at 1/30.72 of the clock:
//  1. half-scale random input: outputs identical, no overflow;
//  2. full-scale I = Q: the original wraps; saturate=1 gives +-full scale with the
//     sign of the internal result there and is identical everywhere else.
`timescale 1ns/1ps
module cordic_sat_tb;
  localparam W = 24;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;
  reg [17:0] i18 = 0, q18 = 0;
  reg [31:0] phase = 0;
  wire [W-1:0] x0, y0, x1, y1;
  cordic_z24 #(.bitwidth(W), .saturate(0)) d0 (.clock(clk), .reset(rst), .enable(1'b1),
    .xi({i18, 6'b0}), .yi({q18, 6'b0}), .zi(phase[31:8]), .xo(x0), .yo(y0), .zo());
  cordic_z24 #(.bitwidth(W), .saturate(1)) d1 (.clock(clk), .reset(rst), .enable(1'b1),
    .xi({i18, 6'b0}), .yi({q18, 6'b0}), .zi(phase[31:8]), .xo(x1), .yo(y1), .zo());
  always @(posedge clk) phase <= phase + 32'd139810133;   // 2^32 / 30.72

  integer errors = 0, ovf = 0, cycles = 0, phase_no = 0;
  wire xo0 = d0.x20[W+1] != d0.x20[W];
  wire yo0 = d0.y20[W+1] != d0.y20[W];
  wire [W-1:0] xs = {d0.x20[W+1], {(W-1){~d0.x20[W+1]}}};
  wire [W-1:0] ys = {d0.y20[W+1], {(W-1){~d0.y20[W+1]}}};
  always @(posedge clk) if (!rst && cycles > 40) begin
    if (xo0 | yo0) ovf = ovf + 1;
    if (x1 !== (xo0 ? xs : x0) || y1 !== (yo0 ? ys : y0)) begin
      if (errors < 10) $display("FAIL phase %0d: x1=%h y1=%h (x0=%h y0=%h ovf %b%b)", phase_no, x1, y1, x0, y0, xo0, yo0);
      errors = errors + 1;
    end
    if (phase_no == 1 && (xo0 | yo0)) begin
      if (errors < 10) $display("FAIL: overflow on a half-scale input");
      errors = errors + 1;
    end
  end
  always @(posedge clk) cycles <= cycles + 1;

  integer k;
  initial begin
    repeat (5) @(posedge clk); rst = 0;
    phase_no = 1;                                  // half scale, random
    for (k = 0; k < 20000; k = k + 1) begin
      @(negedge clk); i18 = $random % 65536; q18 = $random % 65536;
    end
    phase_no = 2;                                  // full scale, I = Q
    for (k = 0; k < 20000; k = k + 1) begin
      @(negedge clk); i18 = 18'h1FFFF; q18 = (k & 4096) ? 18'h20000 : 18'h1FFFF;
    end
    repeat (40) @(posedge clk);
    $display("%0d cycles, %0d with overflow (wrap in the original), %0d mismatches", cycles, ovf, errors);
    if (errors == 0 && ovf > 1000) $display("PASS"); else $display("FAILED");
    $finish;
  end
endmodule
