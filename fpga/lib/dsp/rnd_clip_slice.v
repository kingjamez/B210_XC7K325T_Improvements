//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Scale a wide two's complement value down by 2^SHIFT with convergent
// rounding (round half to even, no DC bias), then saturate to OUT_W bits.
// Combinational, so it can replace a plain bit slice
//   in[OUT_W-1+SHIFT:SHIFT]
// without changing latency or strobe alignment. The plain slice truncates
// (-0.5 LSB bias) and wraps on overflow; this one clips.
//
// Used on the DDC halfband outputs: the default hb47 coefficients have a
// DC gain of 2^18 but a sum of |h| of ~1.64 x 2^18, so a worst-case input
// (e.g. a clipped ADC) can exceed full scale at the slice.

module rnd_clip_slice #(
  parameter IN_W  = 47,
  parameter SHIFT = 18,
  parameter OUT_W = 24
) (
  input  [IN_W-1:0]  in,
  output [OUT_W-1:0] out
);
  // in + (2^(SHIFT-1) - 1) + in[SHIFT], in IN_W+1 bits so it cannot overflow
  wire [IN_W:0] ext  = {in[IN_W-1], in};
  wire [IN_W:0] bias = {{(IN_W+1-SHIFT){1'b0}}, {(SHIFT-1){1'b1}}} + in[SHIFT];
  wire [IN_W:0] sum  = ext + bias;
  wire [IN_W-SHIFT:0] q = sum[IN_W:SHIFT];          // rounded, IN_W+1-SHIFT bits

  clip #(.bits_in(IN_W + 1 - SHIFT), .bits_out(OUT_W)) clip_i (.in(q), .out(out));
endmodule
