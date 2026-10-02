// SPDX-License-Identifier: LGPL-3.0-or-later
// osc_monitor: good-period accumulation, missing-pulse rejection, PPS select,
// transfer to the second clock domain. Scaled "second" = 1000 clk.
`timescale 1ns/1ps
module osc_monitor_tb;
  reg clk = 0, rclk = 0;
  always #5 clk = ~clk;          // bus_clk
  always #8.138 rclk = ~rclk;    // radio_clk ~61.44 MHz

  reg pps_gps = 0, pps_ext = 0, sel_ext = 0;
  wire [63:0] snap;
  wire [31:0] last;
  osc_monitor #(.NOMINAL(1000), .TOL(20)) dut (.clk(clk), .pps_gps(pps_gps), .pps_ext(pps_ext),
    .rclk(rclk), .sel_ext(sel_ext), .snap_r(snap), .last_period_r(last));

  integer errors = 0;
  task check(input [8*40-1:0] name, input [63:0] got, input [63:0] exp);
    if (got !== exp) begin
      $display("FAIL %0s: got %0d expected %0d", name, got, exp); errors = errors + 1;
    end else $display("ok   %0s = %0d", name, got);
  endtask

  // pulse on the GPS pin every p clk cycles
  task gps_period(input integer p);
    begin pps_gps = 1; repeat (100) @(posedge clk); pps_gps = 0; repeat (p - 100) @(posedge clk); end
  endtask
  task ext_period(input integer p);
    begin pps_ext = 1; repeat (100) @(posedge clk); pps_ext = 0; repeat (p - 100) @(posedge clk); end
  endtask

  integer k, kg, ke;
  initial begin
    repeat (20) @(posedge clk);
    // first edge only arms; then 5 periods of 1002 (+2000 ppm vs 1000... in tolerance 20)
    for (k = 0; k < 6; k = k + 1) gps_period(1002);
    repeat (50) @(posedge rclk);
    check("edges after 6 pulses (5 periods)", snap[63:48], 5);
    check("sum = 5 x 1002", snap[47:0], 5010);
    check("last period", last, 1002);

    // missing pulse: one 2004-cycle gap must be rejected
    gps_period(2004);
    for (k = 0; k < 3; k = k + 1) gps_period(998);
    repeat (50) @(posedge rclk);
    // the 50-rclk wait above stretched one period to ~1082 (rejected), the
    // 2004 gap is rejected, then two good 998 periods
    check("edges (gap rejected)", snap[63:48], 5 + 2);
    check("sum (gap rejected)", snap[47:0], 5010 + 2 * 998);
    check("last period 998", last, 998);

    // select EXT: GPS pulses ignored, EXT periods counted
    sel_ext = 1;
    fork
      begin for (kg = 0; kg < 4; kg = kg + 1) gps_period(700); end   // ignored while EXT is selected
      begin repeat (30) @(posedge clk); for (ke = 0; ke < 4; ke = ke + 1) ext_period(1001); end
    join
    repeat (50) @(posedge rclk);
    // switching the source makes an artifact edge and a short period (both
    // rejected), then 3 good EXT periods
    check("edges after EXT", snap[63:48], 7 + 3);
    check("sum after EXT", snap[47:0], 5010 + 2 * 998 + 3 * 1001);

    if (errors == 0) $display("PASS"); else $display("FAILED with %0d errors", errors);
    $finish;
  end
endmodule
