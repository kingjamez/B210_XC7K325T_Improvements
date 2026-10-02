// SPDX-License-Identifier: LGPL-3.0-or-later
// axi_fifo_2clk_xpm under Vivado xsim with the real XPM models (Icarus can't
// simulate XPM). Run: make -C fpga/sim xsim   (needs Vivado settings64.sh)
//
// Random valid/ready traffic with an in-order data check, both clock ratios,
// distributed (SIZE 0) and block RAM (SIZE 11) variants, and resets from the
// write domain, from the read domain, and while the read clock is stopped.
`timescale 1ns/1ps
module axi_fifo_2clk_xpm_tb;

  integer errors = 0;

  // One FIFO + traffic + scoreboard per instance. The writer runs while
  // TAG_run is set; the reader always drains, so quiescing empties the FIFO.

  localparam int W = 65;

  // ---------------- case A: SIZE 0, wr 100 MHz -> rd 30.72 MHz ----------------
  `define FIFO_CASE(TAG, SZ, WRH, RDH) \
  reg TAG``_wclk = 0, TAG``_rclk = 0, TAG``_rstop = 0, TAG``_rst = 0, TAG``_rst_rd = 0; \
  always #(WRH) TAG``_wclk = ~TAG``_wclk; \
  always #(RDH) if (!TAG``_rstop) TAG``_rclk = ~TAG``_rclk; \
  reg  [W-1:0] TAG``_din = 0; reg TAG``_iv = 0; wire TAG``_ir; \
  wire [W-1:0] TAG``_dout; wire TAG``_ov; reg TAG``_or = 0; \
  reg TAG``_rr = 0; always @(posedge TAG``_rclk) TAG``_rr <= TAG``_rst_rd; \
  axi_fifo_2clk #(.SIZE(SZ), .WIDTH(W)) TAG``_dut ( \
    .reset(TAG``_rst | TAG``_rr), .i_aclk(TAG``_wclk), .i_tdata(TAG``_din), .i_tvalid(TAG``_iv), .i_tready(TAG``_ir), \
    .o_aclk(TAG``_rclk), .o_tdata(TAG``_dout), .o_tvalid(TAG``_ov), .o_tready(TAG``_or)); \
  reg TAG``_run = 0; longint TAG``_wcnt = 0, TAG``_rcnt = 0; \
  always @(posedge TAG``_wclk) begin \
    if (TAG``_iv && TAG``_ir) begin TAG``_wcnt <= TAG``_wcnt + 1; TAG``_din <= TAG``_wcnt + 1; end \
    TAG``_iv <= TAG``_run && ($urandom % 10 < 7); \
  end \
  always @(posedge TAG``_rclk) begin \
    if (TAG``_ov && TAG``_or) begin \
      if (TAG``_dout !== W'(TAG``_rcnt)) begin \
        if (errors < 20) $display("FAIL %s: got %0d expected %0d at %0t", `"TAG`", TAG``_dout, TAG``_rcnt, $time); \
        errors = errors + 1; \
      end \
      TAG``_rcnt <= TAG``_rcnt + 1; \
    end \
    TAG``_or <= ($urandom % 10 < 6); \
  end

  `FIFO_CASE(a, 0,  5.0, 16.276)   // distributed, 100 MHz -> 30.72 MHz
  `FIFO_CASE(b, 11, 5.0, 16.276)   // block RAM,   100 MHz -> 30.72 MHz
  `FIFO_CASE(c, 11, 16.276, 5.0)   // block RAM,   30.72 MHz -> 100 MHz
  `FIFO_CASE(d, 13, 5.0, 5.555)    // block RAM 8K deep, 100 MHz -> 90 MHz (GPIF-like)

  // Drain both sides, then zero the counters (after a reset the FIFO is empty)
  `define QUIESCE(TAG) begin TAG``_run = 0; #400000; end
  `define RESTART(TAG) begin TAG``_din = 0; TAG``_wcnt = 0; TAG``_rcnt = 0; #500; TAG``_run = 1; end


  initial begin
    // power-up: XPM needs its reset sequence; the wrapper resets once by itself
    #2000;
    a_run = 1; b_run = 1; c_run = 1; d_run = 1;
    #200000;

    // 1. reset from the write domain mid-traffic
    `QUIESCE(a) `QUIESCE(b) `QUIESCE(c) `QUIESCE(d)
    a_rst = 1; b_rst = 1; c_rst = 1; d_rst = 1; #40;
    a_rst = 0; b_rst = 0; c_rst = 0; d_rst = 0; #3000;
    `RESTART(a) `RESTART(b) `RESTART(c) `RESTART(d)
    #200000;

    // 2. reset from the read domain (pulse synchronous to o_aclk)
    `QUIESCE(a) `QUIESCE(b) `QUIESCE(c) `QUIESCE(d)
    a_rst_rd = 1; b_rst_rd = 1; c_rst_rd = 1; d_rst_rd = 1; #100;
    a_rst_rd = 0; b_rst_rd = 0; c_rst_rd = 0; d_rst_rd = 0; #3000;
    `RESTART(a) `RESTART(b) `RESTART(c) `RESTART(d)
    #200000;

    // 3. read clock stopped, reset asserted twice while stopped, clock resumes
    `QUIESCE(a) `QUIESCE(b)
    a_rstop = 1; b_rstop = 1; #2000;
    a_rst = 1; b_rst = 1; #100; a_rst = 0; b_rst = 0; #2000;
    a_rst = 1; b_rst = 1; #100; a_rst = 0; b_rst = 0; #5000;
    a_rstop = 0; b_rstop = 0; #5000;
    `RESTART(a) `RESTART(b)
    #200000;

    `QUIESCE(a) `QUIESCE(b) `QUIESCE(c) `QUIESCE(d)
    $display("words: a %0d  b %0d  c %0d  d %0d", a_rcnt, b_rcnt, c_rcnt, d_rcnt);
    if (a_rcnt < 1000 || b_rcnt < 1000 || c_rcnt < 1000 || d_rcnt < 1000) begin
      $display("FAIL: FIFO stalled (too few words after the last phase)"); errors++;
    end
    if (a_wcnt != a_rcnt || b_wcnt != b_rcnt || c_wcnt != c_rcnt || d_wcnt != d_rcnt) begin
      $display("FAIL: words lost/stuck: w/r a %0d/%0d b %0d/%0d c %0d/%0d d %0d/%0d",
        a_wcnt, a_rcnt, b_wcnt, b_rcnt, c_wcnt, c_rcnt, d_wcnt, d_rcnt); errors++;
    end
    if (errors == 0) $display("PASS"); else $display("FAILED with %0d errors", errors);
    $finish;
  end
endmodule
