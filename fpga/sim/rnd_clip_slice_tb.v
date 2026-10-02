// SPDX-License-Identifier: LGPL-3.0-or-later
// rnd_clip_slice vs the Python model (sw/dsp_models/rnd_clip_slice.py): bit-exact.
`timescale 1ns/1ps
module rnd_clip_slice_tb;
  reg  [46:0] in;
  wire [23:0] out;
  rnd_clip_slice #(.IN_W(47), .SHIFT(18), .OUT_W(24)) dut (.in(in), .out(out));

  reg [70:0] vec [0:40000];
  integer i, n, errors;
  reg [46:0] x; reg [23:0] y;
  initial begin
    for (i = 0; i <= 40000; i = i + 1) vec[i] = 71'bx;
    $readmemh("build/rnd_clip_slice_vectors.hex", vec);
    errors = 0; n = 0;
    for (i = 0; i <= 40000 && vec[i] !== 71'bx; i = i + 1) begin
      {x, y} = vec[i];
      in = x; #1;
      if (out !== y) begin
        if (errors < 10) $display("FAIL in=%h got %h expected %h", x, out, y);
        errors = errors + 1;
      end
      n = n + 1;
    end
    $display("%0d vectors, %0d mismatches", n, errors);
    if (errors == 0 && n > 1000) $display("PASS"); else $display("FAILED");
    $finish;
  end
endmodule
