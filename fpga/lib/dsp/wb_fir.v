//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Wideband filter profiles for the DDC at decimation 1 (N6).
//
// At decimation 1 the DDC passes the AD9361's samples straight through, and at
// 56-61.44 MS/s the AD9361's own filters leave the band edges nearly
// unattenuated (anything folding in from beyond Nyquist lands there). This is
// a 33-tap symmetric FIR at the output rate, one sample per clock, with
// selectable coefficient profiles (sw/dsp_models/wb_fir.py, wb_fir_coefs.vh):
//   0  bypass (default): no filtering and no added delay
//   1  flat to 0.42 fs (0.16 dB p-p), >= 50 dB from 0.49 fs
//   2  flat to 0.40 fs (0.19 dB p-p), >= 45 dB from 0.47 fs
//   3  flat to 0.36 fs (0.12 dB p-p), >= 60 dB from 0.44 fs
// It is active only when `active` is set (decimation 1: CIC rate 1, no
// halfbands); otherwise it is a pass-through. A profile other than 0 adds a
// group delay of 16 samples plus 9 clocks of pipeline; switching profiles
// while streaming glitches a few samples.
//
// Coefficients are 18-bit, DC gain 2^16; the output is rounded half to even
// and saturated to WIDTH bits.

module wb_fir #(
  parameter WIDTH = 24
) (
  input              clk,
  input              rst,
  input       [1:0]  profile,
  input              active,
  input              strobe_in,
  input  [WIDTH-1:0] i_in,
  input  [WIDTH-1:0] q_in,
  output             strobe_out,
  output [WIDTH-1:0] i_out,
  output [WIDTH-1:0] q_out
);
  localparam M = 17, CW = 18;

  `include "wb_fir_coefs.vh"              // function wb_coef(profile, k)

  reg [1:0] prof_r = 2'd0;
  reg       use_r  = 1'b0;
  always @(posedge clk) begin
    prof_r <= profile;
    use_r  <= ~rst & active & (profile != 2'd0);
  end

  // Coefficient registers (constant per profile)
  wire [M*CW-1:0] cbus;
  genvar k;
  generate for (k = 0; k < M; k = k + 1) begin : coef
    reg signed [CW-1:0] c = (k == M - 1) ? 18'sd65536 : 18'sd0;
    always @(posedge clk) c <= wb_coef(prof_r, k);
    assign cbus[k*CW +: CW] = c;
  end endgenerate

  wire [WIDTH-1:0] y_i, y_q;
  wire             stb_f;
  wb_fir_ch #(.WIDTH(WIDTH)) fir_i (.clk(clk), .strobe_in(strobe_in), .x_in(i_in),
    .cbus(cbus), .strobe_out(stb_f), .y_out(y_i));
  wb_fir_ch #(.WIDTH(WIDTH)) fir_q (.clk(clk), .strobe_in(strobe_in), .x_in(q_in),
    .cbus(cbus), .strobe_out(), .y_out(y_q));

  assign strobe_out = use_r ? stb_f : strobe_in;
  assign i_out      = use_r ? y_i   : i_in;
  assign q_out      = use_r ? y_q   : q_in;
endmodule


// One channel: 33 taps, c0..c15 mirrored, c16 = centre. Pipeline (free-running,
// inputs shift on strobe_in): pre-add, multiply, five adder levels, round and
// saturate. strobe_out follows strobe_in by 9 clocks.
module wb_fir_ch #(
  parameter WIDTH = 24, CW = 18, FRAC = 16
) (
  input                  clk,
  input                  strobe_in,
  input      [WIDTH-1:0] x_in,
  input      [17*CW-1:0] cbus,
  output                 strobe_out,
  output reg [WIDTH-1:0] y_out
);
  localparam NT = 33, M = 17, PW = WIDTH + 1 + CW, SW = PW + 5;

  wire signed [CW-1:0] c [0:M-1];
  genvar g;
  generate for (g = 0; g < M; g = g + 1) begin : cw
    assign c[g] = cbus[g*CW +: CW];
  end endgenerate

  reg signed [WIDTH-1:0] x [0:NT-1];
  integer n;
  initial for (n = 0; n < NT; n = n + 1) x[n] = 0;
  always @(posedge clk)
    if (strobe_in) begin
      x[0] <= x_in;
      for (n = 1; n < NT; n = n + 1) x[n] <= x[n - 1];
    end

  // pre-add, multiply
  reg signed [WIDTH:0]  s [0:M-1];
  reg signed [PW-1:0]   p [0:M-1];
  always @(posedge clk) begin
    for (n = 0; n < M - 1; n = n + 1) s[n] <= x[n] + x[NT - 1 - n];
    s[M - 1] <= x[M - 1];
    for (n = 0; n < M; n = n + 1) p[n] <= s[n] * c[n];
  end

  // adder tree: 17 -> 9 -> 5 -> 3 -> 2 -> 1
  reg signed [SW-1:0] a1 [0:8];
  reg signed [SW-1:0] a2 [0:4];
  reg signed [SW-1:0] a3 [0:2];
  reg signed [SW-1:0] a4 [0:1];
  reg signed [SW-1:0] acc;
  always @(posedge clk) begin
    for (n = 0; n < 8; n = n + 1) a1[n] <= p[2*n] + p[2*n + 1];
    a1[8] <= p[16];
    for (n = 0; n < 4; n = n + 1) a2[n] <= a1[2*n] + a1[2*n + 1];
    a2[4] <= a1[8];
    a3[0] <= a2[0] + a2[1];
    a3[1] <= a2[2] + a2[3];
    a3[2] <= a2[4];
    a4[0] <= a3[0] + a3[1];
    a4[1] <= a3[2];
    acc   <= a4[0] + a4[1];
  end

  wire [WIDTH-1:0] y_rc;
  rnd_clip_slice #(.IN_W(SW), .SHIFT(FRAC), .OUT_W(WIDTH)) rcs (.in(acc), .out(y_rc));
  always @(posedge clk) y_out <= y_rc;

  // shift, pre-add, multiply, 5 adder levels, output register
  reg [8:0] stb = 9'd0;
  always @(posedge clk) stb <= {stb[7:0], strobe_in};
  assign strobe_out = stb[8];
endmodule
