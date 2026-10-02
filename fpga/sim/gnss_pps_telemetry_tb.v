// Testbench for gnss_pps_telemetry. Run: make -C fpga/sim
`timescale 1ns/1ps

module gnss_pps_telemetry_tb;
  // Scaled-down "second" so the sim is fast: GPS PPS every 1000 clk, 100 high.
  localparam GPS_PERIOD = 1000, GPS_WIDTH = 100;
  localparam EXT_PERIOD = 1500, EXT_WIDTH = 7;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg        set_stb = 0;
  reg  [7:0] set_addr = 0;
  reg [31:0] set_data = 0;
  reg  [7:0] rb_addr = 0;
  wire [63:0] rb_data;

  reg pps_gps = 0, pps_ext = 0, io_a = 1, io_b = 1;
  wire uart_rx_sel, gps_tx_en, uhd_uart_en;
  wire [15:0] clkdiv_override;

  gnss_pps_telemetry dut (
    .clk(clk), .rst(rst),
    .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
    .rb_addr(rb_addr), .rb_data(rb_data),
    .pps_gps(pps_gps), .pps_ext(pps_ext), .io_a(io_a), .io_b(io_b),
    .uart_rx_sel(uart_rx_sel), .gps_tx_en(gps_tx_en), .clkdiv_override(clkdiv_override),
    .bridge_tx(), .uhd_uart_en(uhd_uart_en), .autocfg_status(4'b0110), .osc_sel_ext(), .droop_dis(), .osc_snap(64'h0001_2345_6789_ABCD), .osc_last(32'd100000001), .tx_byte(), .tx_byte_valid(), .rx_byte(8'h00), .rx_byte_valid(1'b0));

  integer errors = 0;
  task check(input [255:0] what, input [63:0] got, input [63:0] exp);
    if (got !== exp) begin
      $display("FAIL %0s: got %0d (0x%0h) expected %0d (0x%0h)", what, got, got, exp, exp);
      errors = errors + 1;
    end else
      $display("ok   %0s = %0d", what, got);
  endtask

  task poke(input [7:0] a, input [31:0] d);
    begin
      @(posedge clk); set_stb <= 1; set_addr <= a; set_data <= d;
      @(posedge clk); set_stb <= 0;
    end
  endtask

  task peek(input [7:0] a, output [63:0] d);
    begin
      @(posedge clk); rb_addr <= a;
      @(posedge clk); #1 d = rb_data;
    end
  endtask

  // Stimulus generators
  integer t = 0;
  always @(posedge clk) if (!rst) t <= t + 1;
  always @(posedge clk) begin
    pps_gps <= !rst && (t % GPS_PERIOD) < GPS_WIDTH && t >= 50;
    pps_ext <= !rst && ((t + 333) % EXT_PERIOD) < EXT_WIDTH;
  end
  // io_b: UART-like activity, toggles every 13 clk. io_a: idle high.
  always @(posedge clk) if (!rst && t % 13 == 0) io_b <= ~io_b;

  reg [63:0] r;
  initial begin
    repeat (5) @(posedge clk);
    rst = 0;

    // Defaults
    peek(0, r); check("magic", r[63:32], 32'h4B374F50);
    check("version", r[31:0], 32'h00010007);
    check("clkdiv default (38400 @100MHz)", clkdiv_override, 2604);
    check("rx_sel default", uart_rx_sel, 0);
    check("uhd_uart_en default", uhd_uart_en, 0);
    peek(10, r); check("autocfg status readback", r[3:0], 4'b0110);
    peek(12, r); check("osc snap readback", r, 64'h0001_2345_6789_ABCD);
    peek(13, r); check("osc last period", r[31:0], 100000001);
    check("tx_en default", gps_tx_en, 0);

    // Run ~5.3 GPS periods
    repeat (5300) @(posedge clk);
    peek(1, r); check("gps edges", r[63:32], 6); check("ext edges", r[31:0], 3);  // t = 1167, 2667, 4167
    peek(2, r); check("gps period", r[63:32], GPS_PERIOD); check("ext period", r[31:0], EXT_PERIOD);
    peek(4, r); check("gps width", r[63:32], GPS_WIDTH); check("ext width", r[31:0], EXT_WIDTH);
    peek(7, r); check("gps valid (6 steady edges)", r[4], 1); check("ext not yet valid (3 edges)", r[5], 0);
    // The stimulus' first GPS pulse starts at t=50, so the first period is
    // 950, not 1000: one bad edge from the start, nothing missed.
    peek(11, r); check("gps missed none", r[63:48], 0); check("gps bad = 1 (short first period)", r[47:32], 1);
    check("ext missed/bad none", r[31:0], 0);
    peek(3, r);
    if (r[63:32] > GPS_PERIOD) begin $display("FAIL gps age %0d", r[63:32]); errors = errors + 1; end
    else $display("ok   gps age = %0d (< period)", r[63:32]);
    peek(8, r); check("io_b min run (13-clk bit time)", r[31:0], 13);
    check("io_a min run (idle, none)", r[63:32], 32'hFFFFFFFF);
    peek(5, r); check("io_a toggles (idle)", r[63:32], 0);
    if (r[31:0] < 300) begin $display("FAIL io_b toggles %0d", r[31:0]); errors = errors + 1; end
    else $display("ok   io_b toggles = %0d", r[31:0]);

    // Control write: RX from A, TX enable, host baud
    poke(0, 32'h0000_0003);
    peek(6, r); check("ctrl readback", r[31:0], 3);
    check("rx_sel", uart_rx_sel, 1); check("tx_en", gps_tx_en, 1);
    check("uhd_uart_en off", uhd_uart_en, 0);
    poke(0, 32'h0000_0008);
    peek(6, r); check("uhd_uart_en on", uhd_uart_en, 1);
    poke(0, 32'h0000_0003);
    peek(6, r);
    check("clkdiv override off", clkdiv_override, 0);

    // Pulse stopped -> age keeps growing past one period, edge count frozen
    peek(1, r); r = r[63:32];
    force pps_gps = 0;
    repeat (3000) @(posedge clk);
    begin : stopped
      reg [63:0] e;
      peek(1, e);
      check("gps edges frozen while stopped", e[63:32], r);
    end
    peek(3, r);
    if (r[63:32] < 3000 || r[63:32] == 32'hFFFFFFFF) begin
      $display("FAIL gps age while stopped %0d", r[63:32]); errors = errors + 1;
    end else $display("ok   gps age while stopped = %0d", r[63:32]);
    peek(7, r); check("gps valid dropped while stopped", r[4], 0);
    peek(11, r);
    if (r[63:48] < 2) begin $display("FAIL gps missed %0d", r[63:48]); errors = errors + 1; end
    else $display("ok   gps missed while stopped = %0d", r[63:48]);
    check("no new bad edges while stopped", r[47:32], 1);
    release pps_gps;
    // Resume: the gap and the first period after it are both irregular
    repeat (5000) @(posedge clk);
    peek(7, r); check("gps valid again after resume", r[4], 1);
    peek(11, r); check("gps bad edges: 1 + 2 around the gap", r[47:32], 3);

    // Clear
    poke(1, 1);
    peek(1, r); check("edges after clear", r, 0);
    peek(3, r); check("ages after clear", r, 64'hFFFFFFFF_FFFFFFFF);

    if (errors == 0) $display("PASS");
    else $display("FAILED with %0d errors", errors);
    $finish;
  end
endmodule
