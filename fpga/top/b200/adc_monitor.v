//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// ADC overload monitor for both RX channels, on raw AD9361 samples (before
// the radio's DC offset / IQ correction). radio_clk domain, one sample per
// clock per channel (the B200 radios take rx0/rx1 every radio_clk cycle).
// rx0/rx1 = {I[11:0], 4'b0, Q[11:0], 4'b0}, two's complement.
// ch0/ch1 here are the AD9361's data slots (rx0/rx1), not UHD channels.
// Measured: one channel streaming -> it is in slot 0; two channels -> UHD
// channel 0 is in slot 1, UHD channel 1 in slot 0 (tools/adc_status maps it).
//
// On radio 0's user settings bus (stock UHD "enable_user_regs"), register
// range 64-95 (front end, docs/plan/README.md):
//
// Write
//   64  CLEAR   any write clears peaks, counters and flags
//   65  THRESH  [11:0] overload threshold on |I| or |Q|, default 2047
//               (full scale: +2047 or -2048)
// Readback (64-bit; UHD: peek64(N * 8))
//   64  {"ADCM", major[15:0], minor[15:0]}
//   65  ch0 {over_count[31:0], 3'b0, sticky, peak[11:0], 4'h0, thresh[11:0]}
//   66  ch1 (same layout)
//   67  {16'h0, samples[47:0]}   samples since clear (= radio_clk cycles)
//
//   peak       largest |I| or |Q| since clear (0..2048)
//   over_count samples with |I| or |Q| >= THRESH (saturates)
//   sticky     at least one such sample since clear

module adc_monitor #(
  parameter [7:0] BASE = 8'd64
) (
  input             clk,
  input             rst,
  input             set_stb,
  input      [7:0]  set_addr,
  input      [31:0] set_data,
  input      [7:0]  rb_addr,
  output reg [63:0] rb_data,
  input      [31:0] rx0,
  input      [31:0] rx1
);
  localparam [15:0] VERSION_MAJOR = 16'd1;
  localparam [15:0] VERSION_MINOR = 16'd0;

  wire clear  = set_stb && set_addr == BASE;
  reg  [11:0] thresh = 12'd2047;
  always @(posedge clk)
    if (rst) thresh <= 12'd2047;
    else if (set_stb && set_addr == BASE + 8'd1) thresh <= set_data[11:0];

  // |x| of a 12-bit two's complement value, 0..2048
  function [11:0] mag(input [11:0] x);
    mag = x[11] ? (~x + 12'd1) : x;     // -2048 -> 12'h800 = 2048 (as unsigned)
  endfunction

  // Register the inputs once (they come straight from the IOB registers)
  reg [11:0] i0, q0, i1, q1;
  always @(posedge clk) begin
    i0 <= rx0[31:20]; q0 <= rx0[15:4];
    i1 <= rx1[31:20]; q1 <= rx1[15:4];
  end

  wire [11:0] m0 = (mag(i0) > mag(q0)) ? mag(i0) : mag(q0);
  wire [11:0] m1 = (mag(i1) > mag(q1)) ? mag(i1) : mag(q1);

  reg [11:0] peak0 = 0, peak1 = 0;
  reg [31:0] over0 = 0, over1 = 0;
  reg        sticky0 = 0, sticky1 = 0;
  reg [47:0] samples = 0;

  always @(posedge clk) begin
    if (rst || clear) begin
      peak0 <= 0; peak1 <= 0; over0 <= 0; over1 <= 0;
      sticky0 <= 0; sticky1 <= 0; samples <= 0;
    end else begin
      if (samples != 48'hFFFFFFFFFFFF) samples <= samples + 1'b1;
      if (m0 > peak0) peak0 <= m0;
      if (m1 > peak1) peak1 <= m1;
      if (m0 >= thresh) begin sticky0 <= 1'b1; if (over0 != 32'hFFFFFFFF) over0 <= over0 + 1'b1; end
      if (m1 >= thresh) begin sticky1 <= 1'b1; if (over1 != 32'hFFFFFFFF) over1 <= over1 + 1'b1; end
    end
  end

  always @(posedge clk) begin
    case (rb_addr)
      BASE:          rb_data <= {32'h4144434D, VERSION_MAJOR, VERSION_MINOR};   // "ADCM"
      BASE + 8'd1:   rb_data <= {over0, 3'b0, sticky0, peak0, 4'h0, thresh};
      BASE + 8'd2:   rb_data <= {over1, 3'b0, sticky1, peak1, 4'h0, thresh};
      BASE + 8'd3:   rb_data <= {16'h0, samples};
      default:       rb_data <= 64'h0;
    endcase
  end

endmodule
