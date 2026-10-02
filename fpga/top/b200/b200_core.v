//
// Copyright 2013 Ettus Research LLC
// Copyright 2017 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//


/***********************************************************
 * B200 Core Guts
 **********************************************************/
module b200_core
#(
    parameter R0_CTRL_SID = 8'h10,
    parameter R1_CTRL_SID = 8'h20,
    parameter U0_CTRL_SID = 8'h30,
    parameter L0_CTRL_SID = 8'h40,
    parameter R0_DATA_SID = 8'h50,
    parameter R1_DATA_SID = 8'h60,
    parameter DEMUX_SID_MASK = 8'hf0,
    parameter EXTRA_BUFF_SIZE = 0,
    parameter RADIO_FIFO_SIZE = 11,
    parameter SAMPLE_FIFO_SIZE = 11
)
(
    ////////////////////////////////////////////////////////////////////
    // bus interfaces
    ////////////////////////////////////////////////////////////////////
    input 	  bus_clk,
    input 	  bus_rst,

    input [63:0]  tx_tdata, input tx_tlast, input tx_tvalid, output tx_tready,
    output [63:0] rx_tdata, output rx_tlast, output rx_tvalid, input rx_tready,
    input [63:0]  ctrl_tdata, input ctrl_tlast, input ctrl_tvalid, output ctrl_tready,
    output [63:0] resp_tdata, output resp_tlast, output resp_tvalid, input resp_tready,

    ////////////////////////////////////////////////////////////////////
    // radio interfaces
    ////////////////////////////////////////////////////////////////////
    input 	  radio_clk,
    input 	  radio_rst,

    input [31:0]  rx0, input [31:0] rx1,
    output [31:0] tx0, output [31:0] tx1,
    output [7:0] fe0_gpio_out, output [7:0] fe1_gpio_out,
    input [9:0] fp_gpio_in, output [9:0] fp_gpio_out, output [9:0] fp_gpio_ddr,
    input 	  pps_int, input pps_ext,

    ////////////////////////////////////////////////////////////////////
    // gps uart / pins (raw pads; direction chosen at runtime, see gnss_pps_telemetry)
    ////////////////////////////////////////////////////////////////////
    input gps_a_in, output gps_a_out, output gps_a_oe,
    input gps_b_in, output gps_b_out, output gps_b_oe,

    ////////////////////////////////////////////////////////////////////
    // core interfaces
    ////////////////////////////////////////////////////////////////////
    output [7:0]  sen, output sclk, output mosi, input miso,
    input [31:0]  rb_misc,
    output [31:0] misc_outs,
    ////////////////////////////////////////////////////////////////////
    // debug UART
    ////////////////////////////////////////////////////////////////////
    output debug_txd, input debug_rxd,
    input debug_scl, input debug_sda,

    ////////////////////////////////////////////////////////////////////
    // fe lock signals
    ////////////////////////////////////////////////////////////////////
    input [1:0] lock_signals,

    ////////////////////////////////////////////////////////////////////
    // debug signals
    ////////////////////////////////////////////////////////////////////
    output [63:0] debug,

    output pps
);
    localparam SR_CORE_SPI       = 8'd8;
    localparam SR_CORE_MISC      = 8'd16;
    localparam SR_CORE_COMPAT    = 8'd24;
    localparam SR_CORE_READBACK  = 8'd32;
    localparam SR_CORE_GPSDO_ST  = 8'd40;
    localparam SR_CORE_SYNC      = 8'd48;
    localparam COMPAT_MAJOR      = 16'h0010;
    localparam COMPAT_MINOR      = 16'h0000;

    reg [1:0] lock_state;
    reg [1:0] lock_state_r;

    always @(posedge bus_clk)
      if (bus_rst)
        {lock_state_r, lock_state} <= 4'h0;
      else
        {lock_state_r, lock_state} <= {lock_state, lock_signals};


    /*******************************************************************
     * PPS Timing stuff
     ******************************************************************/

    // Generate an internal PPS signal
    wire int_pps;
    // PIPELINE("OUT"): an unregistered compare output glitches when the count
    // crosses the duty-cycle threshold, and the radio_clk sampler can take the
    // glitch as an extra edge ~250 ms after the real one.
    pps_generator #(.CLK_FREQ(100000000), .PIPELINE("OUT")) pps_gen
    (.clk(bus_clk), .reset(1'b0), .pps(int_pps));

    // Flop PPS signals into radio clock domain
    reg [1:0] 	 gpsdo_pps_del, ext_pps_del, int_pps_del;
    always @(posedge radio_clk) ext_pps_del[1:0] <= {ext_pps_del[0], pps_ext};
    always @(posedge radio_clk) gpsdo_pps_del[1:0] <= {gpsdo_pps_del[0], pps_int};
    always @(posedge radio_clk) int_pps_del[1:0] <= {int_pps_del[0], int_pps};

    // PPS mux
    wire [1:0] pps_select;
    assign pps =  (pps_select == 2'b00)? gpsdo_pps_del[1] :
                (pps_select == 2'b01)? ext_pps_del[1] :
                (pps_select == 2'b10)? int_pps_del[1] :
                1'b0;

    /*******************************************************************
     * Response mux Routing logic
     ******************************************************************/
    wire [63:0] r0_resp_tdata; wire r0_resp_tlast, r0_resp_tvalid, r0_resp_tready;
    wire [63:0] r1_resp_tdata; wire r1_resp_tlast, r1_resp_tvalid, r1_resp_tready;
    wire [63:0] u0_resp_tdata; wire u0_resp_tlast, u0_resp_tvalid, u0_resp_tready;
    wire [63:0] l0_resp_tdata; wire l0_resp_tlast, l0_resp_tvalid, l0_resp_tready;

    axi_mux4 #(.WIDTH(64), .BUFFER(1)) mux_for_resp
     (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
      .i0_tdata(r0_resp_tdata), .i0_tlast(r0_resp_tlast), .i0_tvalid(r0_resp_tvalid), .i0_tready(r0_resp_tready),
      .i1_tdata(r1_resp_tdata), .i1_tlast(r1_resp_tlast), .i1_tvalid(r1_resp_tvalid), .i1_tready(r1_resp_tready),
      .i2_tdata(u0_resp_tdata), .i2_tlast(u0_resp_tlast), .i2_tvalid(u0_resp_tvalid), .i2_tready(u0_resp_tready),
      .i3_tdata(l0_resp_tdata), .i3_tlast(l0_resp_tlast), .i3_tvalid(l0_resp_tvalid), .i3_tready(l0_resp_tready),
      .o_tdata(resp_tdata), .o_tlast(resp_tlast), .o_tvalid(resp_tvalid), .o_tready(resp_tready));

    /*******************************************************************
     * Control demux Routing logic
     ******************************************************************/
    wire [63:0] r0_ctrl_tdata; wire r0_ctrl_tlast, r0_ctrl_tvalid, r0_ctrl_tready;
    wire [63:0] r1_ctrl_tdata; wire r1_ctrl_tlast, r1_ctrl_tvalid, r1_ctrl_tready;
    wire [63:0] u0_ctrl_tdata; wire u0_ctrl_tlast, u0_ctrl_tvalid, u0_ctrl_tready;
    wire [63:0] l0_ctrl_tdata; wire l0_ctrl_tlast, l0_ctrl_tvalid, l0_ctrl_tready;

    wire [63:0] ctrl_hdr;
    wire [1:0] ctrl_dst =
        ((ctrl_hdr[7:0] & DEMUX_SID_MASK) == R0_CTRL_SID)? 0 : (
        ((ctrl_hdr[7:0] & DEMUX_SID_MASK) == R1_CTRL_SID)? 1 : (
        ((ctrl_hdr[7:0] & DEMUX_SID_MASK) == U0_CTRL_SID)? 2 : (
        ((ctrl_hdr[7:0] & DEMUX_SID_MASK) == L0_CTRL_SID)? 3 : (
    3))));
    axi_demux4 #(.ACTIVE_CHAN(4'b1111), .WIDTH(64), .BUFFER(1)) demux_for_ctrl
     (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
      .header(ctrl_hdr), .dest(ctrl_dst),
      .i_tdata(ctrl_tdata), .i_tlast(ctrl_tlast), .i_tvalid(ctrl_tvalid), .i_tready(ctrl_tready),
      .o0_tdata(r0_ctrl_tdata), .o0_tlast(r0_ctrl_tlast), .o0_tvalid(r0_ctrl_tvalid), .o0_tready(r0_ctrl_tready),
      .o1_tdata(r1_ctrl_tdata), .o1_tlast(r1_ctrl_tlast), .o1_tvalid(r1_ctrl_tvalid), .o1_tready(r1_ctrl_tready),
      .o2_tdata(u0_ctrl_tdata), .o2_tlast(u0_ctrl_tlast), .o2_tvalid(u0_ctrl_tvalid), .o2_tready(u0_ctrl_tready),
      .o3_tdata(l0_ctrl_tdata), .o3_tlast(l0_ctrl_tlast), .o3_tvalid(l0_ctrl_tvalid), .o3_tready(l0_ctrl_tready));

    /*******************************************************************
     * UART
     ******************************************************************/
    wire [63:0] u0i_ctrl_tdata; wire u0i_ctrl_tlast, u0i_ctrl_tvalid, u0i_ctrl_tready;

    axi_fifo #(.WIDTH(65), .SIZE(5)) uart_timing_fifo
    (
        .clk(bus_clk), .reset(bus_rst), .clear(1'b0),
        .i_tdata({u0_ctrl_tlast, u0_ctrl_tdata}), .i_tvalid(u0_ctrl_tvalid), .i_tready(u0_ctrl_tready), .space(),
        .o_tdata({u0i_ctrl_tlast, u0i_ctrl_tdata}), .o_tvalid(u0i_ctrl_tvalid), .o_tready(u0i_ctrl_tready), .occupied()
    );

    // GPS UART pin routing. Controls come from gnss_pps_telemetry (radio_clk
    // domain) and are quasi-static, so a plain synchronizer is enough.
    wire        gps_uart_rx_sel_r, gps_tx_en_r, gps_bridge_tx_r, gps_uhd_uart_en_r;
    wire [15:0] gps_clkdiv_override_r;
    wire        gps_uart_rx_sel, gps_tx_en, gps_bridge_tx, gps_uhd_uart_en;
    wire [15:0] gps_clkdiv_override;
    synchronizer #(.WIDTH(20), .STAGES(2)) gps_ctrl_sync
     (.clk(bus_clk), .rst(1'b0),
      .in({gps_uhd_uart_en_r, gps_bridge_tx_r, gps_clkdiv_override_r, gps_tx_en_r, gps_uart_rx_sel_r}),
      .out({gps_uhd_uart_en, gps_bridge_tx, gps_clkdiv_override, gps_tx_en, gps_uart_rx_sel}));

    // One-shot u-blox configuration after FPGA load (module RXD on A14, TXD on
    // B14, measured). Runs in bus_clk because UHD probes for a GPSDO before
    // radio_clk runs. Never drives A14 unless it was quiet and high for 1 s.
    wire       gps_ac_oe, gps_ac_txd;
    wire [3:0] gps_ac_status;   // {nak, ack, sent, skipped}
    wire       gps_ac_ack = gps_ac_status[2];
    // rst tied low: runs once per FPGA load. UHD's per-open resets must not
    // restart it (the module keeps the config until the board powers off).
    gps_autoconfig gps_autoconfig
     (.clk(bus_clk), .rst(1'b0), .rx_in(gps_b_in), .tx_pin_in(gps_a_in),
      .tx_oe(gps_ac_oe), .txd(gps_ac_txd), .status(gps_ac_status));

    // UART bit time: CTRL override if set; else 38400 once autoconfig is ACKed
    // (CTRL reads 0 until radio_clk runs); else UHD's own value (115200).
    wire [15:0] gps_uart_clkdiv = (gps_clkdiv_override != 16'd0) ? gps_clkdiv_override :
                                  gps_ac_ack ? 16'd2604 : 16'd0;

    wire gps_uart_txd;       // from UHD's cvita_uart
    wire gps_bridge_txd;     // from the host UART bridge
    wire gps_uart_rxd = gps_uart_rx_sel ? gps_a_in : gps_b_in;
    wire gps_txd_mux  = gps_bridge_tx ? gps_bridge_txd : gps_uart_txd;
    assign gps_a_out = gps_ac_oe ? gps_ac_txd : gps_txd_mux;
    assign gps_b_out = gps_txd_mux;
    assign gps_a_oe  = gps_ac_oe | (gps_tx_en & ~gps_uart_rx_sel);  // RX on B -> TX on A
    assign gps_b_oe  = gps_tx_en &  gps_uart_rx_sel;                // RX on A -> TX on B

    // UHD's GPSDO UART sees an idle line unless CTRL[3] is set or the module
    // ACKed the autoconfig ($GP NMEA that UHD accepts and keeps reading). See
    // CTRL[3] in gnss_pps_telemetry.v for why it must not be open otherwise.
    //  - UHD may probe (and arm cvita_uart) before the ACK. On the ACK, reset
    //    cvita_uart so the gate never opens onto an armed UART nobody reads.
    //  - After the ACK, hide a stale "no GPSDO" (0x83) so the next open probes
    //    again. If UHD writes 0x83 after the gate has been open for longer
    //    than a whole probe (650 ms; we use 1.5 s) it rejected the module:
    //    close the gate and stop hiding until the next FPGA load. A 0x83 from
    //    a probe that the ACK landed in the middle of is not a rejection.
    reg  gps_ac_ack_d = 1'b0, gps_uhd_rejected = 1'b0;
    reg  [27:0] gps_gate_age = 28'd0;
    reg  gps_gate_mature = 1'b0;
    wire [7:0] gpsdo_st;          // UHD's SR_CORE_GPSDO_ST (sr_gpsdo_st below)
    wire gpsdo_st_changed;
    wire gps_uhd_gate = gps_ac_ack & ~gps_uhd_rejected;
    always @(posedge bus_clk) begin
        gps_ac_ack_d <= gps_ac_ack;
        if (!gps_uhd_gate) begin
            gps_gate_age    <= 28'd0;
            gps_gate_mature <= 1'b0;
        end else if (gps_gate_age == 28'd150_000_000) begin
            gps_gate_mature <= 1'b1;
        end else begin
            gps_gate_age <= gps_gate_age + 1'b1;
        end
        if (gpsdo_st_changed && gpsdo_st == 8'h83 && gps_gate_mature) gps_uhd_rejected <= 1'b1;
    end
    wire gps_uart_rearm = gps_ac_ack & ~gps_ac_ack_d;
    wire [7:0] gpsdo_st_rb = (gps_uhd_gate && gpsdo_st == 8'h83) ? 8'h00 : gpsdo_st;
    wire gps_uhd_rx_open = gps_uhd_uart_en | gps_uhd_gate;

    cvita_uart #(.SIZE(7)) uart
    (
        .clk(bus_clk), .rst(bus_rst | gps_uart_rearm), .rxd(gps_uhd_rx_open ? gps_uart_rxd : 1'b1), .txd(gps_uart_txd),
        .clkdiv_override(gps_uart_clkdiv),
        .i_tdata(u0i_ctrl_tdata), .i_tlast(u0i_ctrl_tlast), .i_tvalid(u0i_ctrl_tvalid), .i_tready(u0i_ctrl_tready),
        .o_tdata(u0_resp_tdata), .o_tlast(u0_resp_tlast), .o_tvalid(u0_resp_tvalid), .o_tready(u0_resp_tready)
    );

    /*******************************************************************
     * Misc controls
     ******************************************************************/
    wire 	set_stb;
    wire [7:0] 	set_addr;
    wire [31:0] 	set_data;

    wire spi_ready;
    wire [31:0] spi_readback;

    wire [7:0] radio_st;

    wire [1:0] rb_addr;
    reg [63:0] rb_data;

    wire [63:0] l0i_ctrl_tdata; wire l0i_ctrl_tlast, l0i_ctrl_tvalid, l0i_ctrl_tready;

    wire time_sync, time_sync_r;

    axi_fifo #(.WIDTH(65), .SIZE(5)) radio_ctrl_proc_timing_fifo
    (
        .clk(bus_clk), .reset(bus_rst), .clear(1'b0),
        .i_tdata({l0_ctrl_tlast, l0_ctrl_tdata}), .i_tvalid(l0_ctrl_tvalid), .i_tready(l0_ctrl_tready), .space(),
        .o_tdata({l0i_ctrl_tlast, l0i_ctrl_tdata}), .o_tvalid(l0i_ctrl_tvalid), .o_tready(l0i_ctrl_tready), .occupied()
    );

    radio_ctrl_proc radio_ctrl_proc
     (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
      .ctrl_tdata(l0i_ctrl_tdata), .ctrl_tlast(l0i_ctrl_tlast), .ctrl_tvalid(l0i_ctrl_tvalid), .ctrl_tready(l0i_ctrl_tready),
      .resp_tdata(l0_resp_tdata), .resp_tlast(l0_resp_tlast), .resp_tvalid(l0_resp_tvalid), .resp_tready(l0_resp_tready),
      .vita_time(64'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .ready(spi_ready), .readback(rb_data),
      .debug());

    setting_reg #(.my_addr(SR_CORE_MISC), .awidth(8), .width(32), .at_reset(8'h0)) sr_misc
     (.clk(bus_clk), .rst(bus_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
      .out(misc_outs), .changed());

    setting_reg #(.my_addr(SR_CORE_READBACK), .awidth(8), .width(2)) sr_rdback
     (.clk(bus_clk), .rst(bus_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
      .out(rb_addr), .changed());

    setting_reg #(.my_addr(SR_CORE_GPSDO_ST), .awidth(8), .width(8)) sr_gpsdo_st
     (.clk(bus_clk), .rst(1'b0/*keep*/), .strobe(set_stb), .addr(set_addr), .in(set_data),
      .out(gpsdo_st), .changed(gpsdo_st_changed));

    setting_reg #(.my_addr(SR_CORE_SYNC), .awidth(8), .width(3)) sr_sync
     (.clk(bus_clk), .rst(bus_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
      .out({time_sync,pps_select}), .changed());

    synchronizer time_sync_synchronizer
     (.clk(radio_clk), .rst(radio_rst), .in(time_sync), .out(time_sync_r));

    simple_spi_core #(.BASE(SR_CORE_SPI), .WIDTH(8), .CLK_IDLE(0), .SEN_IDLE(8'hFF)) misc_spi
     (.clock(bus_clk), .reset(bus_rst),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .readback(spi_readback), .ready(spi_ready),
      .sen(sen), .sclk(sclk), .mosi(mosi), .miso(miso),
      .debug());

    always @*
     case(rb_addr)
       2'd0 : rb_data <= { 32'hACE0BA5E, COMPAT_MAJOR, COMPAT_MINOR };
       2'd1 : rb_data <= { 32'b0, spi_readback };
       2'd2 : rb_data <= { 16'b0, radio_st, gpsdo_st_rb, rb_misc };
       2'd3 : rb_data <= { 30'h0, lock_state_r };
       default : rb_data <= 64'd0;
     endcase // case (rb_addr)

    /*******************************************************************
     * RX Data mux Routing logic
     ******************************************************************/
    wire [63:0] r0_rx_tdata; wire r0_rx_tlast, r0_rx_tvalid, r0_rx_tready;
    wire [63:0] r1_rx_tdata; wire r1_rx_tlast, r1_rx_tvalid, r1_rx_tready;
    wire [63:0] rx_tdata_int; wire rx_tlast_int, rx_tvalid_int, rx_tready_int;

   axi_mux4 #(.WIDTH(64), .BUFFER(1)) mux_for_rx
     (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
      .i0_tdata(r0_rx_tdata), .i0_tlast(r0_rx_tlast), .i0_tvalid(r0_rx_tvalid), .i0_tready(r0_rx_tready),
      .i1_tdata(r1_rx_tdata), .i1_tlast(r1_rx_tlast), .i1_tvalid(r1_rx_tvalid), .i1_tready(r1_rx_tready),
      .i2_tdata(64'b0), .i2_tlast(1'b0), .i2_tvalid(1'b0), .i2_tready(),
      .i3_tdata(64'b0), .i3_tlast(1'b0), .i3_tvalid(1'b0), .i3_tready(),
      .o_tdata(rx_tdata_int), .o_tlast(rx_tlast_int), .o_tvalid(rx_tvalid_int), .o_tready(rx_tready_int));

    axi_fifo #(.WIDTH(65), .SIZE(EXTRA_BUFF_SIZE)) extra_rx_buff
     (.clk(bus_clk), .reset(bus_rst),.clear(1'b0),
      .i_tdata({rx_tlast_int, rx_tdata_int}), .i_tvalid(rx_tvalid_int), .i_tready(rx_tready_int),
      .o_tdata({rx_tlast, rx_tdata}), .o_tvalid(rx_tvalid), .o_tready(rx_tready));

    /*******************************************************************
     * TX Data mux Routing logic
     ******************************************************************/
    wire [63:0] r0_tx_tdata; wire r0_tx_tlast, r0_tx_tvalid, r0_tx_tready;
    wire [63:0] r1_tx_tdata; wire r1_tx_tlast, r1_tx_tvalid, r1_tx_tready;
    wire [63:0] tx_tdata_int; wire tx_tlast_int, tx_tvalid_int, tx_tready_int;

    axi_fifo #(.WIDTH(65), .SIZE(EXTRA_BUFF_SIZE)) extra_tx_buff
     (.clk(bus_clk), .reset(bus_rst),.clear(1'b0),
      .i_tdata({tx_tlast, tx_tdata}), .i_tvalid(tx_tvalid), .i_tready(tx_tready),
      .o_tdata({tx_tlast_int, tx_tdata_int}), .o_tvalid(tx_tvalid_int), .o_tready(tx_tready_int));

    wire [63:0] tx_hdr;
    wire [1:0] tx_dst =
        ((tx_hdr[7:0] & DEMUX_SID_MASK) == R0_DATA_SID)? 0 : (
        ((tx_hdr[7:0] & DEMUX_SID_MASK) == R1_DATA_SID)? 1 : (
    3));
    axi_demux4 #(.ACTIVE_CHAN(4'b0011), .WIDTH(64), .BUFFER(1)) demux_for_tx
     (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
      .header(tx_hdr), .dest(tx_dst),
      .i_tdata(tx_tdata_int), .i_tlast(tx_tlast_int), .i_tvalid(tx_tvalid_int), .i_tready(tx_tready_int),
      .o0_tdata(r0_tx_tdata), .o0_tlast(r0_tx_tlast), .o0_tvalid(r0_tx_tvalid), .o0_tready(r0_tx_tready),
      .o1_tdata(r1_tx_tdata), .o1_tlast(r1_tx_tlast), .o1_tvalid(r1_tx_tvalid), .o1_tready(r1_tx_tready),
      .o2_tdata(), .o2_tlast(), .o2_tvalid(), .o2_tready(1'b1),
      .o3_tdata(), .o3_tlast(), .o3_tvalid(), .o3_tready(1'b1));

    /*******************************************************************
     * Radio 0
     ******************************************************************/
   wire [63:0] radio0_debug;
   wire [31:0] fe0_gpio_out32;
   wire        droop_dis;           // telemetry CTRL[5]: CIC droop compensation off
   wire [1:0]  wb_profile;          // telemetry CTRL[7:6]: wideband filter profile
   wire        r0_user_set_stb;
   wire [7:0]  r0_user_set_addr, r0_user_rb_addr;
   wire [31:0] r0_user_set_data;
   wire [63:0] r0_user_rb_data, r0_tel_rb_data, r0_adc_rb_data;
   wire [7:0]  gps_bridge_tx_byte, gps_bridge_rx_byte;
   wire        gps_bridge_tx_valid, gps_bridge_rx_valid;
   assign fe0_gpio_out = fe0_gpio_out32[7:0];

   radio_legacy #(
      .RADIO_FIFO_SIZE(RADIO_FIFO_SIZE),
      .SAMPLE_FIFO_SIZE(SAMPLE_FIFO_SIZE),
      .FP_GPIO(1),
      .NEW_HB_INTERP(1),
      .NEW_HB_DECIM(1),
      .SOURCE_FLOW_CONTROL(0),
      .USER_SETTINGS(2),
      .DEVICE("7SERIES")
   ) radio_0 (
      .radio_clk(radio_clk), .radio_rst(radio_rst),
      .rx(rx0), .tx(tx0), .pps(pps), .time_sync(time_sync_r),
      .fe_gpio_in(32'h00000000), .fe_gpio_out(fe0_gpio_out32), .fe_gpio_ddr(/* Always assumed to be outputs */),
      .fp_gpio_in(fp_gpio_in), .fp_gpio_out(fp_gpio_out), .fp_gpio_ddr(fp_gpio_ddr),
      .bus_clk(bus_clk), .bus_rst(bus_rst),
      .tx_tdata(r0_tx_tdata), .tx_tlast(r0_tx_tlast), .tx_tvalid(r0_tx_tvalid), .tx_tready(r0_tx_tready),
      .rx_tdata(r0_rx_tdata), .rx_tlast(r0_rx_tlast),  .rx_tvalid(r0_rx_tvalid), .rx_tready(r0_rx_tready),
      .ctrl_tdata(r0_ctrl_tdata), .ctrl_tlast(r0_ctrl_tlast),  .ctrl_tvalid(r0_ctrl_tvalid), .ctrl_tready(r0_ctrl_tready),
      .resp_tdata(r0_resp_tdata), .resp_tlast(r0_resp_tlast),  .resp_tvalid(r0_resp_tvalid), .resp_tready(r0_resp_tready),
      .user_set_stb(r0_user_set_stb), .user_set_addr(r0_user_set_addr), .user_set_data(r0_user_set_data),
      .user_rb_addr(r0_user_rb_addr), .user_rb_data(r0_user_rb_data),
      .ddc_droop_en(~droop_dis), .ddc_wb_profile(wb_profile),
      .debug(radio0_debug)
   );

   /*******************************************************************
    * GNSS / PPS telemetry on radio 0's user settings bus
    ******************************************************************/
   wire        osc_sel_ext;          // osc_monitor (below) <-> telemetry
   wire [63:0] osc_snap;
   wire [31:0] osc_last;
   gnss_pps_telemetry gnss_pps_telemetry (
      .clk(radio_clk), .rst(radio_rst),
      .set_stb(r0_user_set_stb), .set_addr(r0_user_set_addr), .set_data(r0_user_set_data),
      .rb_addr(r0_user_rb_addr), .rb_data(r0_tel_rb_data),
      .pps_gps(pps_int), .pps_ext(pps_ext),
      .io_a(gps_a_in), .io_b(gps_b_in),
      .uart_rx_sel(gps_uart_rx_sel_r), .gps_tx_en(gps_tx_en_r),
      .clkdiv_override(gps_clkdiv_override_r), .bridge_tx(gps_bridge_tx_r),
      .uhd_uart_en(gps_uhd_uart_en_r), .autocfg_status(gps_ac_status),
      .osc_sel_ext(osc_sel_ext), .osc_snap(osc_snap), .osc_last(osc_last),
      .droop_dis(droop_dis), .wb_profile(wb_profile),
      .tx_byte(gps_bridge_tx_byte), .tx_byte_valid(gps_bridge_tx_valid),
      .rx_byte(gps_bridge_rx_byte), .rx_byte_valid(gps_bridge_rx_valid)
   );

   /*******************************************************************
    * Oscillator vs PPS (GPS or SMA), measured in bus_clk (VCTCXO x 2.5),
    * read through the GNSS telemetry (readbacks 12, 13).
    ******************************************************************/
   osc_monitor osc_monitor (
      .clk(bus_clk), .pps_gps(pps_int), .pps_ext(pps_ext),
      .rclk(radio_clk), .sel_ext(osc_sel_ext), .snap_r(osc_snap), .last_period_r(osc_last));

   /*******************************************************************
    * ADC overload monitor (both channels, raw samples) on radio 0's user
    * settings bus, registers 64-95 (gnss_pps_telemetry owns 0-47).
    ******************************************************************/
   adc_monitor #(.BASE(8'd64)) adc_monitor (
      .clk(radio_clk), .rst(radio_rst),
      .set_stb(r0_user_set_stb), .set_addr(r0_user_set_addr), .set_data(r0_user_set_data),
      .rb_addr(r0_user_rb_addr), .rb_data(r0_adc_rb_data),
      .rx0(rx0), .rx1(rx1));

   assign r0_user_rb_data = (r0_user_rb_addr >= 8'd64 && r0_user_rb_addr < 8'd96) ? r0_adc_rb_data : r0_tel_rb_data;

   // Host UART bridge: raw bytes to/from the GPS module for stock UHD.
   // Baud: the telemetry override (the normal case for the u-blox), else
   // 115200 (868 bus_clk cycles), matching what UHD programs into cvita_uart.
   gps_uart_bridge gps_uart_bridge (
      .ctrl_clk(radio_clk), .ctrl_rst(radio_rst),
      .tx_byte(gps_bridge_tx_byte), .tx_byte_valid(gps_bridge_tx_valid),
      .rx_byte(gps_bridge_rx_byte), .rx_byte_valid(gps_bridge_rx_valid),
      .uart_clk(bus_clk), .uart_rst(bus_rst),
      .clkdiv(gps_uart_clkdiv != 16'd0 ? gps_uart_clkdiv : 16'd868),
      .rxd(gps_uart_rxd), .txd(gps_bridge_txd)
   );

    /*******************************************************************
     * Radio 1
     ******************************************************************/
`ifdef TARGET_B210 // B210 Has two radio instances.
   assign      radio_st = 8'h2;

   wire [63:0] radio1_debug;
   wire [31:0] fe1_gpio_out32;
   assign fe1_gpio_out = fe1_gpio_out32[7:0];

   radio_legacy #(
      .RADIO_FIFO_SIZE(RADIO_FIFO_SIZE),
      .SAMPLE_FIFO_SIZE(SAMPLE_FIFO_SIZE),
      .FP_GPIO(0),
      .NEW_HB_INTERP(1),
      .NEW_HB_DECIM(1),
      .SOURCE_FLOW_CONTROL(0),
      .USER_SETTINGS(0),
      .DEVICE("7SERIES")
   ) radio_1 (
      .radio_clk(radio_clk), .radio_rst(radio_rst),
      .rx(rx1), .tx(tx1), .pps(pps), .time_sync(time_sync_r),
      .fe_gpio_in(32'h00000000), .fe_gpio_out(fe1_gpio_out32), .fe_gpio_ddr(/* Always assumed to be outputs */),
      .fp_gpio_in(32'h00000000), .fp_gpio_out(), .fp_gpio_ddr(),
      .bus_clk(bus_clk), .bus_rst(bus_rst),
      .tx_tdata(r1_tx_tdata), .tx_tlast(r1_tx_tlast), .tx_tvalid(r1_tx_tvalid), .tx_tready(r1_tx_tready),
      .rx_tdata(r1_rx_tdata), .rx_tlast(r1_rx_tlast),  .rx_tvalid(r1_rx_tvalid), .rx_tready(r1_rx_tready),
      .ctrl_tdata(r1_ctrl_tdata), .ctrl_tlast(r1_ctrl_tlast),  .ctrl_tvalid(r1_ctrl_tvalid), .ctrl_tready(r1_ctrl_tready),
      .resp_tdata(r1_resp_tdata), .resp_tlast(r1_resp_tlast),  .resp_tvalid(r1_resp_tvalid), .resp_tready(r1_resp_tready),
      .user_set_stb(), .user_set_addr(), .user_set_data(),
      .user_rb_addr(), .user_rb_data(64'd0),
      .ddc_droop_en(~droop_dis), .ddc_wb_profile(wb_profile),
      .debug(radio1_debug)
   );
`else
    assign radio_st = 8'h1;

    //assign undriven outputs
    assign fe1_gpio_out = 32'b0; //Always assumed to be outputs
    assign tx1 = 32'b0;

    //unused control signals -- leave in loopback
    assign r1_resp_tdata = r1_ctrl_tdata;
    assign r1_resp_tlast = r1_ctrl_tlast;
    assign r1_resp_tvalid = r1_ctrl_tvalid;
    assign r1_ctrl_tready = r1_resp_tready;

    //unused data signals -- leave in loopback
    assign r1_rx_tdata = r1_tx_tdata;
    assign r1_rx_tlast = r1_tx_tlast;
    assign r1_rx_tvalid = r1_tx_tvalid;
    assign r1_tx_tready = r1_tx_tready;

`endif // !`ifdef TARGET_B210

   /*******************************************************************
    * Debug UART for FX3
    ******************************************************************/

   wire        debug_stb;
   wire [31:0] debug_data;
   wire [7:0]  debug_addr;
   wire [31:0] debug_serial;


   serial_to_settings serial_to_settings_i1
     (
      .clk(bus_clk),
      .reset(bus_rst),
      .scl(debug_scl),
      .sda(debug_sda),
      .set_stb(debug_stb),
      .set_addr(debug_addr),
      .set_data(debug_data),
      .debug(debug_serial)
      );

   // Nasty Hack to convert settings to wishbone crudely.
   reg    wb_stb;
   wire   wb_ack_o;

   always @(posedge bus_clk)
     wb_stb <= debug_stb ? 1 : ((wb_ack_o) ? 0 : wb_stb);

   simple_uart debug_uart
   (
      .clk_i(bus_clk),
      .rst_i(bus_rst),
      .we_i(wb_stb),
      .stb_i(wb_stb),
      .cyc_i(wb_stb),
      .ack_o(wb_ack_o),
      .adr_i(debug_addr[2:0]),
      .dat_i(debug_data[31:0]),
      .dat_o(),
      .rx_int_o(),
      .tx_int_o(),
      .tx_o(debug_txd),
      .rx_i(debug_rxd),
      .baud_o()
   );

endmodule // b200_core
