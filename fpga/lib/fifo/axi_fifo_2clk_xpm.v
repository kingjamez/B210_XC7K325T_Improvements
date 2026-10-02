//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// axi_fifo_2clk on Xilinx xpm_fifo_async, for synthesis on 7-series.
//
// Same module name, parameters and ports as Ettus' lib/sim/fifo/
// axi_fifo_2clk_sim.v, which the vendor build synthesized: it infers LUT RAM
// (~28k LUTs as RAM64M for this design). This one puts the larger FIFOs in
// block RAM. Simulation (Icarus) keeps using the sim model.
//
//   depth  = 2^max(SIZE, 5)  (XPM minimum is 16; the sim model uses >= 32)
//   memory = block RAM for SIZE >= 9, distributed RAM below
//   read   = first-word-fall-through, so the AXI-stream handshake is unchanged
//
// Reset. Callers drive `reset` from either clock domain (or an OR of both).
// XPM requires rst synchronous to wr_clk and ignores a new reset while the
// previous one is still completing (wr_rst_busy), which needs rd_clk running;
// radio_clk can stop around master clock changes. So the reset is
// synchronized into i_aclk, a request that arrives while XPM is busy is held
// until it can be applied, every XPM reset lasts >= 8 i_aclk cycles, and it
// stays asserted while the caller holds reset. i_tready / o_tvalid are low
// while XPM reports busy.

module axi_fifo_2clk #(
  parameter SYNC_STAGES = 2,
  parameter SIZE        = 10,
  parameter WIDTH       = 32,
  parameter PIPELINE    = "<UNUSED>"
) (
  input              reset,
  input              i_aclk,
  input  [WIDTH-1:0] i_tdata,
  input              i_tvalid,
  output             i_tready,
  input              o_aclk,
  output [WIDTH-1:0] o_tdata,
  output             o_tvalid,
  input              o_tready
);

  localparam FIFOSIZE = (SIZE < 5) ? 5 : SIZE;
  localparam DEPTH    = 1 << FIFOSIZE;
  localparam MEMTYPE  = (FIFOSIZE >= 9) ? "block" : "distributed";
  localparam STAGES   = (SYNC_STAGES < 2) ? 2 : (SYNC_STAGES > 8) ? 8 : SYNC_STAGES;

  // ---- reset into the write domain ----
  wire rst_w;
  xpm_cdc_sync_rst #(.DEST_SYNC_FF(4), .INIT(1)) rst_sync (
    .src_rst(reset), .dest_clk(i_aclk), .dest_rst(rst_w));

  wire       wr_rst_busy, rd_rst_busy;
  reg        fifo_rst = 1'b1;     // reset once after configuration
  reg        rst_req  = 1'b0;
  reg  [3:0] rst_cnt  = 4'd15;

  always @(posedge i_aclk) begin
    if (fifo_rst) begin
      if (rst_cnt != 4'd0)  rst_cnt  <= rst_cnt - 1'b1;
      else if (!rst_w)      fifo_rst <= 1'b0;      // held while the caller holds reset
      rst_req <= 1'b0;
    end else if ((rst_w || rst_req) && !wr_rst_busy) begin
      fifo_rst <= 1'b1;
      rst_cnt  <= 4'd7;
      rst_req  <= 1'b0;
    end else if (rst_w) begin
      rst_req  <= 1'b1;                              // XPM still busy: apply later
    end
  end

  // ---- the FIFO ----
  wire full, empty;
  assign i_tready = ~full & ~wr_rst_busy & ~fifo_rst;
  assign o_tvalid = ~empty & ~rd_rst_busy;

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE   (MEMTYPE),
    .ECC_MODE           ("no_ecc"),
    .RELATED_CLOCKS     (0),
    .FIFO_WRITE_DEPTH   (DEPTH),
    .WRITE_DATA_WIDTH   (WIDTH),
    .READ_DATA_WIDTH    (WIDTH),
    .WR_DATA_COUNT_WIDTH(1),
    .RD_DATA_COUNT_WIDTH(1),
    .FULL_RESET_VALUE   (1),
    .USE_ADV_FEATURES   ("0000"),
    .READ_MODE          ("fwft"),
    .FIFO_READ_LATENCY  (0),
    .DOUT_RESET_VALUE   ("0"),
    .CDC_SYNC_STAGES    (STAGES),
    .SIM_ASSERT_CHK     (0),
    .WAKEUP_TIME        (0)
  ) fifo (
    .sleep(1'b0), .rst(fifo_rst),
    .wr_clk(i_aclk), .wr_en(i_tvalid & i_tready), .din(i_tdata),
    .full(full), .prog_full(), .wr_data_count(), .overflow(), .wr_rst_busy(wr_rst_busy),
    .almost_full(), .wr_ack(),
    .rd_clk(o_aclk), .rd_en(o_tvalid & o_tready), .dout(o_tdata),
    .empty(empty), .prog_empty(), .rd_data_count(), .underflow(), .rd_rst_busy(rd_rst_busy),
    .almost_empty(), .data_valid(),
    .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr());

endmodule
