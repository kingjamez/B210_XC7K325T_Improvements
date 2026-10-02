//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// GNSS / PPS telemetry and GPS UART configuration for the K7 B210 clone.
//
// Lives on radio 0's user settings bus (radio_legacy USER_SETTINGS == 2), so
// stock UHD reaches it with the "enable_user_regs" device arg:
//
//   auto regs = usrp->get_user_settings_iface(0);
//   regs->poke32(addr * 4, value);   // write register <addr>
//   regs->peek64(addr * 8)           // read readback <addr> (byte offset)
//
// All tick counts are in radio_clk cycles (radio_clk == master clock rate).
//
// Write registers
//   0  CTRL   [0]     uart_rx_sel     0 = GPS UART RX from gps_io_b (B14, default)
//                                     1 = GPS UART RX from gps_io_a (A14)
//             [1]     gps_tx_en       1 = drive UART TX onto the other gps_io pin.
//                                     Default 0 (both pins inputs) so a wrong
//                                     pin guess can never cause contention.
//             [2]     bridge_tx       1 = TX pin driven by the host UART bridge
//                                     (gps_uart_bridge) instead of UHD's
//                                     cvita_uart. Only matters with gps_tx_en.
//             [3]     uhd_uart_en     1 = feed the selected RX pin to UHD's
//                                     cvita_uart (GPSDO path). Default 0: its RX
//                                     sees an idle line. Once UHD's GPSDO probe
//                                     arms cvita_uart it sends one response
//                                     packet per received byte until reset; if
//                                     UHD found no GPSDO nobody reads them and
//                                     UHD's control path breaks at the next
//                                     open. Only enable when UHD will accept the
//                                     module as a GPSDO. The bridge always reads
//                                     the selected pin. gps_autoconfig opens this
//                                     path by itself when the module ACKs.
//             [4]     osc_sel_ext     osc_monitor reference: 0 = GPS PPS (default),
//                                     1 = SMA PPS
//             [31:16] clkdiv_override bus_clk cycles per UART bit, 0 = use UHD's
//                                     value (115200), or 38400 once gps_autoconfig
//                                     is ACKed. Default 2604 = 38400 baud at
//                                     100 MHz: measured on this board's module
//                                     (the datasheet says 9600). Readback 8
//                                     measures the actual rate on each pin.
//   1  CLEAR  any write clears all counters (and the RX ring)
//   2  TXBYTE [7:0] byte pushed to the bridge UART TX FIFO (64 deep)
//
// Readback registers (64-bit)
//   0  {"K7OP", major[15:0], minor[15:0]}
//   1  {gps_pps_edges,  ext_pps_edges}    rising edges since clear
//   2  {gps_pps_period, ext_pps_period}   ticks between the last two rising edges
//   3  {gps_pps_age,    ext_pps_age}      ticks since last rising edge (saturates)
//   4  {gps_pps_width,  ext_pps_width}    high time of the last pulse, in ticks
//   5  {io_a_toggles,   io_b_toggles}     both-edge counts on A14 / B14
//   6  {32'h0, CTRL}
//   7  {58'h0, ext_valid, gps_valid, pps_ext, pps_gps, io_b, io_a}
//                                     live levels; *_valid = PPS health (see
//                                     pulse_stats: consistent period, not overdue;
//                                     set from the 4th edge, drops 1.5 periods
//                                     after a missing edge)
//   8  {io_a_min_run, io_b_min_run}   shortest stable level on A14 / B14, in
//                                     ticks (runs < MIN_RUN ignored as glitches).
//                                     On a UART line this is one bit time, so
//                                     baud = master_clock / min_run.
//   9  {32'h0, rx_total}              bytes received by the bridge since clear
//  10  {60'h0, autocfg_status}        gps_autoconfig {nak, ack, sent, skipped}
//                                     (one shot after FPGA load, bus_clk)
//  11  {gps_missed, gps_bad, ext_missed, ext_bad}  16 bits each, since clear:
//                                     missing pulses, and edges whose period
//                                     differs >0.1% from the previous one
//  12  {good_edges[15:0], tick_sum[47:0]}  osc_monitor: bus_clk (100 MHz =
//                                     VCTCXO x 2.5) cycles summed over good PPS
//                                     periods. Read twice: error = dsum /
//                                     (dedges * 1e8) - 1 (both wrap)
//  13  {32'h0, last_period}           last good period in bus_clk cycles
//   16..47  RX ring: 256 bytes, readback 16+i = bytes 8i..8i+7, byte 8i in
//           bits [7:0]. Byte n is at ring[n % 256] (n = 0 .. rx_total-1).

module gnss_pps_telemetry #(
  parameter [15:0] DEFAULT_CLKDIV = 16'd2604,
  parameter [31:0] MIN_RUN        = 32'd8
) (
  input             clk,
  input             rst,

  // User settings bus (from radio_legacy USER_SETTINGS == 2)
  input             set_stb,
  input      [7:0]  set_addr,
  input      [31:0] set_data,
  input      [7:0]  rb_addr,
  output reg [63:0] rb_data,

  // Raw asynchronous inputs
  input             pps_gps,
  input             pps_ext,
  input             io_a,
  input             io_b,

  // GPS UART configuration (clk domain, quasi-static)
  output            uart_rx_sel,
  output            gps_tx_en,
  output     [15:0] clkdiv_override,
  output            bridge_tx,
  output            uhd_uart_en,
  input       [3:0] autocfg_status,   // gps_autoconfig, bus_clk domain, sticky
  output            osc_sel_ext,      // osc_monitor reference select
  input      [63:0] osc_snap,         // osc_monitor, already in clk domain
  input      [31:0] osc_last,

  // Host UART bridge (gps_uart_bridge, clk domain side)
  output reg  [7:0] tx_byte,
  output reg        tx_byte_valid,
  input       [7:0] rx_byte,
  input             rx_byte_valid
);

  localparam [15:0] VERSION_MAJOR = 16'd1;
  localparam [15:0] VERSION_MINOR = 16'd6;

  //--------------------------------------------------------------------------
  // Settings
  //--------------------------------------------------------------------------
  wire [31:0] ctrl;
  setting_reg #(.my_addr(8'd0), .awidth(8), .width(32),
                .at_reset({DEFAULT_CLKDIV, 16'h0000})) sr_ctrl (
    .clk(clk), .rst(rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
    .out(ctrl), .changed());

  wire clear_stb;
  setting_reg #(.my_addr(8'd1), .awidth(8), .width(1)) sr_clear (
    .clk(clk), .rst(rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
    .out(), .changed(clear_stb));

  assign uart_rx_sel     = ctrl[0];
  assign gps_tx_en       = ctrl[1];
  assign clkdiv_override = ctrl[31:16];
  assign bridge_tx       = ctrl[2];
  assign uhd_uart_en     = ctrl[3];
  assign osc_sel_ext     = ctrl[4];

  //--------------------------------------------------------------------------
  // Host UART bridge: TX byte pushes, RX ring buffer
  //--------------------------------------------------------------------------
  always @(posedge clk) begin
    tx_byte_valid <= set_stb && (set_addr == 8'd2) && !rst;
    tx_byte       <= set_data[7:0];
  end

  reg  [7:0]  ring [0:255];
  reg  [31:0] rx_total;
  always @(posedge clk) begin
    if (rst | clear_stb)
      rx_total <= 32'd0;
    else if (rx_byte_valid) begin
      ring[rx_total[7:0]] <= rx_byte;
      rx_total <= rx_total + 32'd1;
    end
  end

  wire [4:0] ring_word = rb_addr[4:0] - 5'd16;  // valid for rb_addr 16..47
  wire [7:0] ring_base = {ring_word, 3'b000};
  wire [63:0] ring_rb = {ring[ring_base + 8'd7], ring[ring_base + 8'd6],
                         ring[ring_base + 8'd5], ring[ring_base + 8'd4],
                         ring[ring_base + 8'd3], ring[ring_base + 8'd2],
                         ring[ring_base + 8'd1], ring[ring_base]};

  //--------------------------------------------------------------------------
  // Input synchronizers
  //--------------------------------------------------------------------------
  wire pps_gps_s, pps_ext_s, io_a_s, io_b_s;
  synchronizer #(.WIDTH(4), .STAGES(2)) sync_in (
    .clk(clk), .rst(1'b0),
    .in({pps_ext, pps_gps, io_b, io_a}),
    .out({pps_ext_s, pps_gps_s, io_b_s, io_a_s}));

  //--------------------------------------------------------------------------
  // Pulse statistics
  //--------------------------------------------------------------------------
  wire [31:0] gps_edges, gps_period, gps_age, gps_width;
  wire [31:0] ext_edges, ext_period, ext_age, ext_width;
  wire        gps_valid, ext_valid;
  wire [15:0] gps_missed, gps_bad, ext_missed, ext_bad;

  pulse_stats stats_gps (
    .clk(clk), .rst(rst | clear_stb), .in(pps_gps_s),
    .edges(gps_edges), .period(gps_period), .age(gps_age), .width(gps_width),
    .valid(gps_valid), .missed(gps_missed), .bad(gps_bad));

  pulse_stats stats_ext (
    .clk(clk), .rst(rst | clear_stb), .in(pps_ext_s),
    .edges(ext_edges), .period(ext_period), .age(ext_age), .width(ext_width),
    .valid(ext_valid), .missed(ext_missed), .bad(ext_bad));

  //--------------------------------------------------------------------------
  // Toggle counters for pin identification
  //--------------------------------------------------------------------------
  reg        io_a_d, io_b_d;
  reg [31:0] io_a_toggles, io_b_toggles;
  always @(posedge clk) begin
    io_a_d <= io_a_s;
    io_b_d <= io_b_s;
    if (rst | clear_stb) begin
      io_a_toggles <= 32'd0;
      io_b_toggles <= 32'd0;
    end else begin
      if ((io_a_s ^ io_a_d) && io_a_toggles != 32'hFFFFFFFF) io_a_toggles <= io_a_toggles + 32'd1;
      if ((io_b_s ^ io_b_d) && io_b_toggles != 32'hFFFFFFFF) io_b_toggles <= io_b_toggles + 32'd1;
    end
  end

  //--------------------------------------------------------------------------
  // Shortest run between toggles (bit-time / baud detection)
  //--------------------------------------------------------------------------
  wire [31:0] io_a_min_run, io_b_min_run;
  min_run_length #(.MIN_RUN(MIN_RUN)) min_run_a (
    .clk(clk), .rst(rst | clear_stb), .in(io_a_s), .min_run(io_a_min_run));
  min_run_length #(.MIN_RUN(MIN_RUN)) min_run_b (
    .clk(clk), .rst(rst | clear_stb), .in(io_b_s), .min_run(io_b_min_run));

  //--------------------------------------------------------------------------
  // Readback
  //--------------------------------------------------------------------------
  // gps_autoconfig status: bus_clk domain, changes once per FPGA load
  (* ASYNC_REG = "TRUE" *) reg [3:0] autocfg_m = 4'd0, autocfg_s = 4'd0;
  always @(posedge clk) begin
    autocfg_m <= autocfg_status;
    autocfg_s <= autocfg_m;
  end

  always @* begin
    case (rb_addr)
      8'd0:    rb_data = {32'h4B374F50, VERSION_MAJOR, VERSION_MINOR};
      8'd1:    rb_data = {gps_edges,  ext_edges};
      8'd2:    rb_data = {gps_period, ext_period};
      8'd3:    rb_data = {gps_age,    ext_age};
      8'd4:    rb_data = {gps_width,  ext_width};
      8'd5:    rb_data = {io_a_toggles, io_b_toggles};
      8'd6:    rb_data = {32'h0, ctrl};
      8'd7:    rb_data = {58'h0, ext_valid, gps_valid, pps_ext_s, pps_gps_s, io_b_s, io_a_s};
      8'd8:    rb_data = {io_a_min_run, io_b_min_run};
      8'd9:    rb_data = {32'h0, rx_total};
      8'd10:   rb_data = {60'h0, autocfg_s};
      8'd11:   rb_data = {gps_missed, gps_bad, ext_missed, ext_bad};
      8'd12:   rb_data = osc_snap;
      8'd13:   rb_data = {32'h0, osc_last};
      default: rb_data = (rb_addr >= 8'd16 && rb_addr <= 8'd47) ? ring_rb : 64'h0;
    endcase
  end

endmodule


// Rising-edge count, edge-to-edge period, age and last high time of a
// synchronized 1-bit input. All counters saturate.
// Health (relative, since the clock rate is the runtime master clock):
//   valid  : the last two periods agree within 1/1024 (~0.1%) and the next
//            edge is not overdue (age < 1.5 x period)
//   missed : +1 for every period that passes without an edge, starting
//            1.5 periods after the last one
//   bad    : +1 for every edge whose period differs from the previous one by
//            more than 1/1024 (double edges, glitches, a source switch)
module pulse_stats (
  input             clk,
  input             rst,
  input             in,
  output reg [31:0] edges,
  output reg [31:0] period,
  output reg [31:0] age,
  output reg [31:0] width,
  output reg        valid,
  output reg [15:0] missed,
  output reg [15:0] bad
);
  reg        in_d;
  reg [31:0] high_cnt;
  reg        seen;
  reg        good_prev;           // previous edge's period was consistent
  reg [32:0] deadline;            // age at which the next edge is overdue
  wire [31:0] new_period = age + 32'd1;
  wire [31:0] diff = (new_period > period) ? new_period - period : period - new_period;
  wire        consistent = (period != 32'd0) && (diff <= (period >> 10));

  wire rise = in & ~in_d;
  wire fall = ~in & in_d;

  always @(posedge clk) begin
    in_d <= in;
    if (rst) begin
      edges    <= 32'd0;
      period   <= 32'd0;
      age      <= 32'hFFFFFFFF;
      width    <= 32'd0;
      high_cnt <= 32'd0;
      seen     <= 1'b0;
      valid    <= 1'b0;
      missed   <= 16'd0;
      bad      <= 16'd0;
      good_prev <= 1'b0;
      deadline <= 33'h1FFFFFFFF;
    end else begin
      if (rise) begin
        if (edges != 32'hFFFFFFFF) edges <= edges + 32'd1;
        if (seen) begin
          period    <= new_period;
          deadline  <= {1'b0, new_period} + (new_period >> 1);
          good_prev <= consistent;
          valid     <= consistent && good_prev;
          if (period != 32'd0 && !consistent && bad != 16'hFFFF) bad <= bad + 16'd1;
        end
        seen     <= 1'b1;
        age      <= 32'd0;
        high_cnt <= 32'd1;
      end else begin
        if (age != 32'hFFFFFFFF) age <= age + 32'd1;
        if (in && high_cnt != 32'hFFFFFFFF) high_cnt <= high_cnt + 32'd1;
        if ({1'b0, age} == deadline) begin
          valid     <= 1'b0;
          good_prev <= 1'b0;
          if (missed != 16'hFFFF) missed <= missed + 16'd1;
          deadline  <= deadline + period;     // one count per missing pulse
        end
      end
      if (fall) width <= high_cnt;
    end
  end
endmodule


// Shortest time a synchronized input stays at one level between two toggles.
// The first run after reset is skipped (its start is unknown). Reads
// 32'hFFFFFFFF until a complete run of at least MIN_RUN ticks is seen.
module min_run_length #(
  parameter [31:0] MIN_RUN = 32'd8
) (
  input             clk,
  input             rst,
  input             in,
  output reg [31:0] min_run
);
  reg        in_d;
  reg        started;
  reg [31:0] run;

  always @(posedge clk) begin
    in_d <= in;
    if (rst) begin
      min_run <= 32'hFFFFFFFF;
      started <= 1'b0;
      run     <= 32'd0;
    end else if (in ^ in_d) begin
      if (started && run >= MIN_RUN && run < min_run) min_run <= run;
      started <= 1'b1;
      run     <= 32'd1;
    end else if (run != 32'hFFFFFFFF) begin
      run <= run + 32'd1;
    end
  end
endmodule
