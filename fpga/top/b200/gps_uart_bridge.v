//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Host-controlled UART to the GPS module, independent of UHD's cvita_uart.
// Lets stock UHD send raw bytes (e.g. UBX config/poll) and read replies
// through gnss_pps_telemetry's user registers.
//
// ctrl_clk side (radio_clk): byte pushes in, received bytes out.
// uart_clk side (bus_clk):   UART TX/RX at clkdiv uart_clk cycles per bit.

module gps_uart_bridge (
  // Register side
  input        ctrl_clk,
  input        ctrl_rst,
  input  [7:0] tx_byte,
  input        tx_byte_valid,   // one-cycle push; dropped if the FIFO is full
  output [7:0] rx_byte,
  output       rx_byte_valid,   // one-cycle pulse per received byte

  // UART side
  input        uart_clk,
  input        uart_rst,
  input [15:0] clkdiv,
  input        rxd,
  output       txd
);

  //--------------------------------------------------------------------------
  // TX: ctrl_clk -> uart_clk -> simple_uart_tx
  //--------------------------------------------------------------------------
  wire [7:0] tx_b;
  wire       tx_b_valid, tx_full;

  axi_fifo_2clk #(.WIDTH(8), .SIZE(6)) tx_cdc (
    .reset(ctrl_rst),
    .i_aclk(ctrl_clk), .i_tdata(tx_byte), .i_tvalid(tx_byte_valid), .i_tready(),
    .o_aclk(uart_clk), .o_tdata(tx_b), .o_tvalid(tx_b_valid), .o_tready(~tx_full));

  simple_uart_tx #(.SIZE(6)) uart_tx (
    .clk(uart_clk), .rst(uart_rst),
    .fifo_in(tx_b), .fifo_write(tx_b_valid & ~tx_full), .fifo_level(), .fifo_full(tx_full),
    .clkdiv(clkdiv), .baudclk(), .tx(txd));

  //--------------------------------------------------------------------------
  // RX: simple_uart_rx -> uart_clk -> ctrl_clk
  //--------------------------------------------------------------------------
  wire [7:0] rx_b;
  wire       rx_empty, rx_cdc_ready;
  wire       rx_take = ~rx_empty & rx_cdc_ready;

  simple_uart_rx #(.SIZE(6)) uart_rx (
    .clk(uart_clk), .rst(uart_rst),
    .fifo_out(rx_b), .fifo_read(rx_take), .fifo_level(), .fifo_empty(rx_empty),
    .clkdiv(clkdiv), .rx(rxd));

  axi_fifo_2clk #(.WIDTH(8), .SIZE(6)) rx_cdc (
    .reset(uart_rst),
    .i_aclk(uart_clk), .i_tdata(rx_b), .i_tvalid(rx_take), .i_tready(rx_cdc_ready),
    .o_aclk(ctrl_clk), .o_tdata(rx_byte), .o_tvalid(rx_byte_valid), .o_tready(1'b1));

endmodule
