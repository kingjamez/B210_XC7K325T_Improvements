//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// CIC droop compensation for the DDC: a 13-tap symmetric FIR at the DDC
// output rate, I and Q, coefficients chosen automatically from the CIC rate
// and halfband configuration that UHD already programs.
//
// The B200 DDC is CIC (4 stages, rate R) -> 0..2 halfbands (H = 1, 2, 4).
// The CIC rolls the passband off by up to 9.7 dB at 0.4 x the output rate
// (odd decimations, H = 1), 2.3 dB (H = 2) or 0.6 dB (H = 4). The
// coefficient sets come from sw/dsp_models/droop_comp.py (minimax design,
// passband 0 .. 0.4 x output rate, worst residual 0.03 dB including the hb47
// halfbands), one set per (H, R), in droop_comp_coefs.vh. R = 1 (no CIC) and
// enable = 0 select a pure pass-through (centre tap = 2^FRAC).
//
// Fixed group delay: 6 output samples (plus pipeline), also in pass-through.
// The output is rounded (half to even) and saturated to WIDTH bits: the
// filter's gain rises to ~4 above the passband where the CIC attenuates.
//
// When (H, R) or enable changes, the 7 coefficients are reloaded from the ROM
// over 8 clocks; samples in flight during the change see a mix (harmless:
// it only happens when UHD retunes the sample rate).

module droop_comp #(
  parameter WIDTH = 24
) (
  input              clk,
  input              rst,
  input              enable,
  input       [7:0]  cic_rate,
  input              hb1_en,       // first halfband (decim by 2)
  input              hb2_en,       // second halfband (decim by 4 total)
  input              strobe_in,
  input  [WIDTH-1:0] i_in,
  input  [WIDTH-1:0] q_in,
  output             strobe_out,
  output [WIDTH-1:0] i_out,
  output [WIDTH-1:0] q_out
);
  localparam NTAPS = 13, M = 7, CW = 18, FRAC = 16;
  localparam PW = WIDTH + 1 + CW;          // pre-added sample x coefficient
  localparam SW = PW + 3;                  // sum of 7 products

  `include "droop_comp_coefs.vh"           // function droop_coef(hidx, rate, k)

  // ---- coefficient set selection and reload ----
  wire [1:0] hidx = (hb1_en & hb2_en) ? 2'd2 : hb1_en ? 2'd1 : 2'd0;
  wire [10:0] key = {enable, hidx, cic_rate};
  reg  [10:0] key_loaded = 11'h7FF;
  reg  [3:0]  ld_k = 4'd0;
  reg         loading = 1'b0;
  reg signed [CW-1:0] coef [0:M-1];
  integer j;
  initial for (j = 0; j < M; j = j + 1) coef[j] = (j == M - 1) ? (1 << FRAC) : 0;

  reg signed [CW-1:0] rom_q;
  always @(posedge clk)                    // registered ROM read (BRAM/LUT ROM)
    rom_q <= (enable && cic_rate > 8'd1) ? droop_coef(hidx, cic_rate, ld_k[2:0])
                                         : ((ld_k[2:0] == M - 1) ? (1 << FRAC) : 0);

  reg [3:0] ld_k_d = 4'd0;
  reg       loading_d = 1'b0;
  always @(posedge clk) begin
    ld_k_d    <= ld_k;
    loading_d <= loading;
    if (rst) begin
      loading <= 1'b0; key_loaded <= 11'h7FF; ld_k <= 4'd0;
    end else if (!loading && key != key_loaded) begin
      loading <= 1'b1; key_loaded <= key; ld_k <= 4'd0;
    end else if (loading) begin
      if (ld_k == M - 1) loading <= 1'b0;
      else ld_k <= ld_k + 1'b1;
    end
    if (loading_d) coef[ld_k_d[2:0]] <= rom_q;
  end

  // ---- datapath, I and Q ----
  wire [WIDTH-1:0] y_i, y_q;
  wire             stb_i;
  droop_comp_fir #(.WIDTH(WIDTH), .CW(CW), .FRAC(FRAC)) fir_i (
    .clk(clk), .strobe_in(strobe_in), .x_in(i_in),
    .c0(coef[0]), .c1(coef[1]), .c2(coef[2]), .c3(coef[3]), .c4(coef[4]), .c5(coef[5]), .c6(coef[6]),
    .strobe_out(stb_i), .y_out(y_i));
  droop_comp_fir #(.WIDTH(WIDTH), .CW(CW), .FRAC(FRAC)) fir_q (
    .clk(clk), .strobe_in(strobe_in), .x_in(q_in),
    .c0(coef[0]), .c1(coef[1]), .c2(coef[2]), .c3(coef[3]), .c4(coef[4]), .c5(coef[5]), .c6(coef[6]),
    .strobe_out(), .y_out(y_q));
  assign strobe_out = stb_i;
  assign i_out = y_i;
  assign q_out = y_q;
endmodule


// One channel: 13-tap symmetric FIR, taps c0..c5 mirrored, c6 = centre.
// Pipeline (free-running; inputs shift on strobe_in): pre-add, multiply,
// two adder levels, round+saturate register. strobe_out follows strobe_in by
// 5 clocks. Needs at least 1 clock between input strobes.
module droop_comp_fir #(
  parameter WIDTH = 24, CW = 18, FRAC = 16
) (
  input                      clk,
  input                      strobe_in,
  input      [WIDTH-1:0]     x_in,
  input  signed [CW-1:0]     c0, c1, c2, c3, c4, c5, c6,
  output                     strobe_out,
  output reg [WIDTH-1:0]     y_out
);
  localparam PW = WIDTH + 1 + CW, SW = PW + 3;

  reg signed [WIDTH-1:0] x [0:12];
  integer n;
  initial for (n = 0; n < 13; n = n + 1) x[n] = 0;
  always @(posedge clk)
    if (strobe_in) begin
      x[0] <= x_in;
      for (n = 1; n < 13; n = n + 1) x[n] <= x[n - 1];
    end

  // stage 1: symmetric pre-add
  reg signed [WIDTH:0] s [0:6];
  always @(posedge clk) begin
    s[0] <= x[0] + x[12]; s[1] <= x[1] + x[11]; s[2] <= x[2] + x[10];
    s[3] <= x[3] + x[9];  s[4] <= x[4] + x[8];  s[5] <= x[5] + x[7];
    s[6] <= x[6];
  end
  // stage 2: multiply
  reg signed [PW-1:0] p [0:6];
  always @(posedge clk) begin
    p[0] <= s[0] * c0; p[1] <= s[1] * c1; p[2] <= s[2] * c2; p[3] <= s[3] * c3;
    p[4] <= s[4] * c4; p[5] <= s[5] * c5; p[6] <= s[6] * c6;
  end
  // stages 3, 4: adder tree
  reg signed [SW-1:0] a0, a1, a2, a3, acc;
  always @(posedge clk) begin
    a0 <= p[0] + p[1]; a1 <= p[2] + p[3]; a2 <= p[4] + p[5]; a3 <= p[6];
    acc <= a0 + a1 + a2 + a3;
  end
  // stage 5: round half to even, saturate
  wire [WIDTH-1:0] y_rc;
  rnd_clip_slice #(.IN_W(SW), .SHIFT(FRAC), .OUT_W(WIDTH)) rcs (.in(acc), .out(y_rc));
  always @(posedge clk) y_out <= y_rc;

  // strobe pipeline: shift (on strobe) -> pre-add -> mult -> add -> acc -> out
  reg [5:0] stb = 6'd0;
  always @(posedge clk) stb <= {stb[4:0], strobe_in};
  assign strobe_out = stb[5];
endmodule
