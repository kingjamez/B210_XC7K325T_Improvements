// Loopback test: telemetry registers -> gps_uart_bridge TX -> RX -> RX ring.
// Run: make -C fpga/sim gps_uart_bridge
`timescale 1ns/1ps

module gps_uart_bridge_tb;
  reg radio_clk = 0, bus_clk = 0;
  always #16.276 radio_clk = ~radio_clk;   // 30.72 MHz
  always #5      bus_clk   = ~bus_clk;     // 100 MHz
  reg radio_rst = 1, bus_rst = 1;

  reg        set_stb = 0;
  reg  [7:0] set_addr = 0;
  reg [31:0] set_data = 0;
  reg  [7:0] rb_addr = 0;
  wire [63:0] rb_data;

  wire [7:0] tx_byte, rx_byte;
  wire tx_valid, rx_valid, txd;
  wire [15:0] clkdiv;

  gnss_pps_telemetry tel (
    .clk(radio_clk), .rst(radio_rst),
    .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
    .rb_addr(rb_addr), .rb_data(rb_data),
    .pps_gps(1'b0), .pps_ext(1'b0), .io_a(1'b1), .io_b(txd),
    .uart_rx_sel(), .gps_tx_en(), .clkdiv_override(clkdiv), .bridge_tx(),
    .uhd_uart_en(), .autocfg_status(4'b0000), .osc_sel_ext(), .osc_snap(64'h0), .osc_last(32'h0),
    .tx_byte(tx_byte), .tx_byte_valid(tx_valid),
    .rx_byte(rx_byte), .rx_byte_valid(rx_valid));

  // Loopback at a fast baud (clkdiv 32 bus_clk cycles) to keep the sim short.
  gps_uart_bridge dut (
    .ctrl_clk(radio_clk), .ctrl_rst(radio_rst),
    .tx_byte(tx_byte), .tx_byte_valid(tx_valid),
    .rx_byte(rx_byte), .rx_byte_valid(rx_valid),
    .uart_clk(bus_clk), .uart_rst(bus_rst),
    .clkdiv(16'd32), .rxd(txd), .txd(txd));

  task poke(input [7:0] a, input [31:0] d);
    begin
      @(posedge radio_clk); set_stb <= 1; set_addr <= a; set_data <= d;
      @(posedge radio_clk); set_stb <= 0;
    end
  endtask
  task peek(input [7:0] a, output [63:0] d);
    begin
      @(posedge radio_clk); rb_addr <= a;
      @(posedge radio_clk); #1 d = rb_data;
    end
  endtask

  // UBX-MON-VER poll: B5 62 0A 04 00 00 0E 34
  reg [7:0] msg [0:7];
  integer i, errors = 0, n;
  reg [63:0] r;
  initial begin
    msg[0]=8'hB5; msg[1]=8'h62; msg[2]=8'h0A; msg[3]=8'h04;
    msg[4]=8'h00; msg[5]=8'h00; msg[6]=8'h0E; msg[7]=8'h34;
    repeat (10) @(posedge bus_clk);
    radio_rst = 0; bus_rst = 0;
    repeat (10) @(posedge radio_clk);

    peek(0, r);
    if (r[31:0] !== 32'h00010006) begin $display("FAIL version %h", r[31:0]); errors = errors + 1; end

    // Send the 8 bytes three times (24 bytes) to exercise ordering and the ring.
    for (n = 0; n < 3; n = n + 1)
      for (i = 0; i < 8; i = i + 1) poke(2, msg[i]);

    // 24 bytes * 10 bits * 32 cycles * 10 ns = ~77 us, plus FIFO latency
    #120000;

    peek(9, r);
    if (r[31:0] !== 24) begin $display("FAIL rx_total %0d (expected 24)", r[31:0]); errors = errors + 1; end
    else $display("ok   rx_total = 24");

    for (n = 0; n < 3; n = n + 1) begin
      peek(16 + n, r);
      for (i = 0; i < 8; i = i + 1)
        if (r[8*i +: 8] !== msg[i]) begin
          $display("FAIL ring word %0d byte %0d: %h expected %h", n, i, r[8*i +: 8], msg[i]);
          errors = errors + 1;
        end
      $display("ok?  ring word %0d = %h", n, r);
    end

    poke(1, 1);
    peek(9, r);
    if (r[31:0] !== 0) begin $display("FAIL rx_total after clear %0d", r[31:0]); errors = errors + 1; end

    if (errors == 0) $display("PASS"); else $display("FAILED with %0d errors", errors);
    $finish;
  end
endmodule
