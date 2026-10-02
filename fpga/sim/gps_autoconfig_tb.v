// SPDX-License-Identifier: LGPL-3.0-or-later
// gps_autoconfig: frame bytes, ACK/NAK, and the never-drive-a-busy-pin rule.
`timescale 1ns/1ps
module gps_autoconfig_tb;
  localparam integer DIV = 16;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg  rx = 1'b1;            // module TXD
  reg  ext_drive = 1'b0;     // something else drives the TX pad (contention case)
  reg  ext_level = 1'b1;
  wire tx_oe, txd;
  wire [3:0] status;
  // Pad model: pull-up; our driver; or an external driver
  wire tx_pad = tx_oe ? txd : (ext_drive ? ext_level : 1'b1);

  gps_autoconfig #(.CLKDIV(DIV), .MIN_OBSERVE(500), .OBSERVE_CYCLES(8000), .MIN_RX_TOGGLES(4), .ACK_TIMEOUT(20000)) dut (
    .clk(clk), .rst(rst), .rx_in(rx), .tx_pin_in(tx_pad),
    .tx_oe(tx_oe), .txd(txd), .status(status));

  integer errors = 0;
  task check(input [8*40-1:0] name, input [31:0] got, input [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %0s: got %0d (0x%0h) expected %0d (0x%0h)", name, got, got, exp, exp);
      errors = errors + 1;
    end else $display("ok   %0s", name);
  endtask

  task send_rx(input [7:0] b);
    integer i;
    begin
      rx = 0; repeat (DIV) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin rx = b[i]; repeat (DIV) @(posedge clk); end
      rx = 1; repeat (DIV) @(posedge clk);
    end
  endtask

  // Expected frame (same bytes tools/gnss_status --ubx-config sends)
  reg [7:0] exp_frame [0:47];
  initial $readmemh("gps_autoconfig_frame.hex", exp_frame);

  // Decode what we transmit
  reg [7:0] got_frame [0:63];
  integer ngot = 0, oe_cycles = 0;
  always @(posedge clk) if (tx_oe) oe_cycles = oe_cycles + 1;
  initial begin : decoder
    integer i; reg [7:0] b;
    forever begin
      @(negedge tx_pad);
      if (tx_oe) begin
        repeat (DIV / 2) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin repeat (DIV) @(posedge clk); b[i] = tx_pad; end
        repeat (DIV) @(posedge clk);
        if (ngot < 64) got_frame[ngot] = b;
        ngot = ngot + 1;
      end
    end
  end

  // Background traffic on RX (module TXD) during OBSERVE
  task chat(input integer n);
    integer k; begin for (k = 0; k < n; k = k + 1) send_rx("$"); end
  endtask

  task reset_dut;
    begin rst = 1; ngot = 0; oe_cycles = 0; repeat (5) @(posedge clk); rst = 0; end
  endtask

  task wait_state(input [2:0] s);
    integer t; begin t = 0; while (dut.state !== s && t < 200000) begin @(posedge clk); t = t + 1; end end
  endtask

  integer i, mism;
  initial begin
    // 1. Happy path: RX active, TX pad idle-high -> frame sent, ACK seen
    reset_dut;
    fork chat(30); join
    wait_state(3'd5);  // S_WAIT_ACK
    check("1 sent", status[1], 1);
    check("1 bytes sent", ngot, 48);
    mism = 0;
    for (i = 0; i < 48; i = i + 1) if (got_frame[i] !== exp_frame[i]) mism = mism + 1;
    check("1 frame matches", mism, 0);
    check("1 pad released", tx_oe, 0);
    send_rx(8'h24); send_rx(8'hB5); send_rx(8'h62); send_rx(8'h05); send_rx(8'h01);
    send_rx(8'h02); send_rx(8'h00); send_rx(8'h06); send_rx(8'h8A);
    repeat (10) @(posedge clk);
    check("1 status ack", status, 4'b0110);

    // 2. NAK
    reset_dut;
    chat(30);
    wait_state(3'd5);
    send_rx(8'hB5); send_rx(8'h62); send_rx(8'h05); send_rx(8'h00);
    send_rx(8'h02); send_rx(8'h00); send_rx(8'h06); send_rx(8'h8A);
    repeat (10) @(posedge clk);
    check("2 status nak", status, 4'b1010);

    // 3. Contention: something toggles the TX pad -> never drive it
    reset_dut;
    ext_drive = 1;
    fork
      chat(30);
      begin repeat (20) begin ext_level = 0; repeat (50) @(posedge clk); ext_level = 1; repeat (50) @(posedge clk); end end
    join
    wait_state(3'd1);  // S_SKIPPED
    repeat (5000) @(posedge clk);
    check("3 skipped", status, 4'b0001);
    check("3 never drove pad", oe_cycles, 0);

    // 4. TX pad held low by something -> never drive it
    reset_dut;
    ext_drive = 1; ext_level = 0;
    chat(30);
    wait_state(3'd1);
    check("4 skipped (pad low)", status, 4'b0001);
    check("4 never drove pad", oe_cycles, 0);
    ext_drive = 0; ext_level = 1;

    // 5. Silent RX -> no module, skip
    reset_dut;
    wait_state(3'd1);
    check("5 skipped (no rx)", status, 4'b0001);
    check("5 never drove pad", oe_cycles, 0);

    // 6. No reply to the first frame -> retry, ACK on the second
    reset_dut;
    chat(30);
    wait_state(3'd5);
    check("6 first frame sent", ngot, 48);
    wait_state(3'd0);            // timed out, back to OBSERVE
    chat(30);                    // RX burst for the re-check
    wait_state(3'd5);
    check("6 retried", dut.tries, 2);
    check("6 second frame complete", ngot, 96);
    send_rx(8'hB5); send_rx(8'h62); send_rx(8'h05); send_rx(8'h01);
    send_rx(8'h02); send_rx(8'h00); send_rx(8'h06); send_rx(8'h8A);
    repeat (10) @(posedge clk);
    check("6 status ack after retry", status, 4'b0110);

    if (errors == 0) $display("PASS"); else $display("FAILED with %0d errors", errors);
    $finish;
  end
endmodule
