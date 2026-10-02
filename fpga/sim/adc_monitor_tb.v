// SPDX-License-Identifier: LGPL-3.0-or-later
// adc_monitor: peaks, over-threshold counts, sticky flags, clear, threshold.
`timescale 1ns/1ps
module adc_monitor_tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg        set_stb = 0;
  reg  [7:0] set_addr = 0;
  reg [31:0] set_data = 0;
  reg  [7:0] rb_addr = 0;
  wire [63:0] rb_data;
  reg [11:0] i0 = 0, q0 = 0, i1 = 0, q1 = 0;

  adc_monitor dut (.clk(clk), .rst(rst), .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
    .rb_addr(rb_addr), .rb_data(rb_data),
    .rx0({i0, 4'h0, q0, 4'h0}), .rx1({i1, 4'h0, q1, 4'h0}));

  integer errors = 0;
  task check(input [8*40-1:0] name, input [63:0] got, input [63:0] exp);
    if (got !== exp) begin
      $display("FAIL %0s: got %0d (0x%0h) expected %0d (0x%0h)", name, got, got, exp, exp);
      errors = errors + 1;
    end else $display("ok   %0s = %0d", name, got);
  endtask
  task poke(input [7:0] a, input [31:0] d);
    begin @(posedge clk); set_stb <= 1; set_addr <= a; set_data <= d; @(posedge clk); set_stb <= 0; end
  endtask
  task peek(input [7:0] a, output [63:0] d);
    begin @(posedge clk); rb_addr <= a; repeat (3) @(posedge clk); d = rb_data; end
  endtask
  // drive n samples
  task drive(input [11:0] a, input [11:0] b, input [11:0] c, input [11:0] d, input integer n);
    begin i0 = a; q0 = b; i1 = c; q1 = d; repeat (n) @(posedge clk); i0 = 0; q0 = 0; i1 = 0; q1 = 0; end
  endtask

  reg [63:0] r;
  initial begin
    repeat (4) @(posedge clk); rst = 0;
    peek(64, r); check("magic ADCM", r[63:32], 32'h4144434D); check("version 1.0", r[31:0], 32'h00010000);
    peek(65, r); check("thresh default", r[11:0], 2047);

    poke(64, 0);                                   // clear
    drive(12'd100, -12'sd300, 12'd5, 12'd7, 10);   // ch0 peak 300 (from Q), ch1 peak 7
    drive(-12'sd2048, 12'd0, 12'd0, 12'd0, 3);     // ch0: 3 samples at -2048 (full scale)
    drive(12'd2047, 12'd0, 12'd0, 12'd2047, 2);    // ch0 +2 at +2047; ch1 2 at +2047
    drive(12'd0, 12'd2046, 12'd0, 12'd0, 4);       // below threshold
    repeat (5) @(posedge clk);
    peek(65, r);
    check("ch0 over count", r[63:32], 5);
    check("ch0 sticky", r[28], 1);
    check("ch0 peak (-2048 -> 2048)", r[27:16], 2048);
    peek(66, r);
    check("ch1 over count", r[63:32], 2);
    check("ch1 sticky", r[28], 1);
    check("ch1 peak", r[27:16], 2047);
    peek(67, r);
    if (r[47:0] < 19) begin $display("FAIL samples %0d", r[47:0]); errors = errors + 1; end
    else $display("ok   samples = %0d", r[47:0]);

    // clear
    poke(64, 0);
    peek(65, r); check("ch0 cleared count", r[63:32], 0); check("ch0 cleared sticky", r[28], 0);
    check("ch0 cleared peak", r[27:16], 0);
    peek(67, r);
    if (r[47:0] > 10) begin $display("FAIL samples after clear %0d", r[47:0]); errors = errors + 1; end
    else $display("ok   samples after clear = %0d", r[47:0]);

    // custom threshold
    poke(65, 1500);
    poke(64, 0);
    drive(12'd1499, 12'd0, 12'd0, 12'd0, 4);       // below
    drive(12'd0, -12'sd1500, 12'd0, 12'd0, 6);     // at threshold (Q, negative)
    repeat (5) @(posedge clk);
    peek(65, r); check("thresh readback", r[11:0], 1500);
    check("ch0 count at thresh 1500", r[63:32], 6);
    check("ch1 untouched", 0, 0);
    peek(66, r); check("ch1 count 0", r[63:32], 0); check("ch1 sticky 0", r[28], 0);

    if (errors == 0) $display("PASS"); else $display("FAILED with %0d errors", errors);
    $finish;
  end
endmodule
