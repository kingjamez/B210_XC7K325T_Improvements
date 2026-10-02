//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// One-shot u-blox MAX-M10S configuration after every FPGA load, so stock UHD
// detects the module as a generic NMEA GPSDO at open.
//
// The module has no flash and no backup supply, so it comes up with default
// NMEA ($GN talker, NMEA 4.11), which UHD's gps_ctrl rejects. UHD probes for a
// GPSDO only once per FPGA load, early in the open (before radio_clk runs),
// so this lives in bus_clk.
//
// Sequence (once per FPGA load; tie rst low in the design, initial values
// apply at configuration. UHD's per-open resets must not restart it):
//   1. OBSERVE  proceed once at least MIN_OBSERVE cycles have passed, the RX
//               pad (module TXD) has toggled MIN_RX_TOGGLES times (a burst of
//               NMEA), and the TX pad has stayed high with no toggles since
//               the start. The module has a single UART TX, so a burst on RX
//               while TX stays idle shows TX is not a module output. No burst
//               within OBSERVE_CYCLES, or any activity/low level on the TX pad
//               -> SKIPPED, and the TX pad is never driven (contention).
//   2. SEND     drive the TX pad, send FRAME (UBX-CFG-VALSET, RAM layer),
//               release the pad.
//   3. WAIT_ACK watch RX for UBX-ACK-ACK / ACK-NAK for class 06 id 8A.
//               Neither within ACK_TIMEOUT -> back to OBSERVE (pins are
//               re-checked) and retry, up to MAX_TRIES. A frame corrupted by
//               a clock disturbance (e.g. UHD's GPIF reset right after the
//               FPGA load) is silently dropped by the module, hence the retry.
//
// FRAME (48 bytes) sets, per the u-blox M10 SPG 5.10 interface description
// (UBX-21035062 R02, protocol 34.10), also built by tools/gnss_status --ubx-config:
//   CFG-NMEA-MAINTALKERID 0x20930031 = 1 (GP), CFG-NMEA-PROTVER 0x20930001 = 21,
//   CFG-MSGOUT-NMEA_ID_{GSV,GSA,VTG,GLL}_UART1 = 0, CFG-RATE-MEAS 0x30210001 = 500 ms
//
// status = {nak, ack, sent, skipped}. b200_core opens UHD's GPSDO UART only
// on ack.

module gps_autoconfig #(
  parameter [15:0] CLKDIV         = 16'd2604,          // bus_clk cycles per bit: 38400 @ 100 MHz
  parameter [31:0] MIN_OBSERVE    = 32'd5_000_000,     // 50 ms
  parameter [31:0] OBSERVE_CYCLES = 32'd200_000_000,   // 2 s: a cold module bursts at 1 Hz
  parameter [15:0] MIN_RX_TOGGLES = 16'd100,
  parameter [31:0] ACK_TIMEOUT    = 32'd100_000_000,   // 1 s
  parameter [3:0]  MAX_TRIES      = 4'd8
) (
  input            clk,
  input            rst,
  input            rx_in,      // raw pad: module TXD
  input            tx_pin_in,  // raw pad we would drive (module RXD)
  output reg       tx_oe,
  output reg       txd,
  output     [3:0] status
);

  localparam NBYTES = 48;

  function [7:0] frame_byte(input [5:0] i);
    case (i)
      6'd0:  frame_byte = 8'hB5; 6'd1:  frame_byte = 8'h62; 6'd2:  frame_byte = 8'h06; 6'd3:  frame_byte = 8'h8A;
      6'd4:  frame_byte = 8'h28; 6'd5:  frame_byte = 8'h00; 6'd6:  frame_byte = 8'h00; 6'd7:  frame_byte = 8'h01;
      6'd8:  frame_byte = 8'h00; 6'd9:  frame_byte = 8'h00;
      6'd10: frame_byte = 8'h31; 6'd11: frame_byte = 8'h00; 6'd12: frame_byte = 8'h93; 6'd13: frame_byte = 8'h20; 6'd14: frame_byte = 8'h01;
      6'd15: frame_byte = 8'h01; 6'd16: frame_byte = 8'h00; 6'd17: frame_byte = 8'h93; 6'd18: frame_byte = 8'h20; 6'd19: frame_byte = 8'h15;
      6'd20: frame_byte = 8'hC5; 6'd21: frame_byte = 8'h00; 6'd22: frame_byte = 8'h91; 6'd23: frame_byte = 8'h20; 6'd24: frame_byte = 8'h00;
      6'd25: frame_byte = 8'hC0; 6'd26: frame_byte = 8'h00; 6'd27: frame_byte = 8'h91; 6'd28: frame_byte = 8'h20; 6'd29: frame_byte = 8'h00;
      6'd30: frame_byte = 8'hB1; 6'd31: frame_byte = 8'h00; 6'd32: frame_byte = 8'h91; 6'd33: frame_byte = 8'h20; 6'd34: frame_byte = 8'h00;
      6'd35: frame_byte = 8'hCA; 6'd36: frame_byte = 8'h00; 6'd37: frame_byte = 8'h91; 6'd38: frame_byte = 8'h20; 6'd39: frame_byte = 8'h00;
      6'd40: frame_byte = 8'h01; 6'd41: frame_byte = 8'h00; 6'd42: frame_byte = 8'h21; 6'd43: frame_byte = 8'h30;
      6'd44: frame_byte = 8'hF4; 6'd45: frame_byte = 8'h01;
      6'd46: frame_byte = 8'h72; 6'd47: frame_byte = 8'hB9;
      default: frame_byte = 8'hFF;
    endcase
  endfunction

  // Pad synchronizers
  (* ASYNC_REG = "TRUE" *) reg [1:0] rx_s  = 2'b11;
  (* ASYNC_REG = "TRUE" *) reg [1:0] txp_s = 2'b11;
  reg rx_q = 1'b1, txp_q = 1'b1;
  always @(posedge clk) begin
    rx_s  <= {rx_s[0], rx_in};
    txp_s <= {txp_s[0], tx_pin_in};
    rx_q  <= rx_s[1];
    txp_q <= txp_s[1];
  end
  wire rx  = rx_s[1];
  wire txp = txp_s[1];

  localparam S_OBSERVE = 3'd0, S_SKIPPED = 3'd1, S_LEAD = 3'd2, S_SEND = 3'd3,
             S_TAIL = 3'd4, S_WAIT_ACK = 3'd5, S_DONE = 3'd6;

  reg [2:0]  state = S_OBSERVE;
  reg [31:0] timer = 0;
  reg [15:0] rx_toggles = 0;
  reg        txp_bad = 1'b0;
  reg        skipped = 1'b0, sent = 1'b0, ack = 1'b0, nak = 1'b0;
  reg [3:0]  tries = 4'd0;
  assign status = {nak, ack, sent, skipped};

  // TX shifter: 10 bits per byte (start, 8 data LSB first, stop)
  reg [5:0]  byte_idx = 0;
  reg [3:0]  bit_idx  = 0;
  reg [9:0]  shreg    = 10'h3FF;
  reg [15:0] baud     = 0;

  // RX byte receiver + last-8-bytes window for ACK/NAK matching
  reg [15:0] rbaud = 0;
  reg [3:0]  rbit  = 0;
  reg [7:0]  rshift = 0;
  reg        rbusy = 1'b0;
  reg [63:0] win = 0;
  reg        rbyte_stb = 1'b0;

  always @(posedge clk) begin
    rbyte_stb <= 1'b0;
    if (rst) begin
      rbusy <= 1'b0;
    end else if (!rbusy) begin
      if (rx_q && !rx) begin            // falling edge: start bit
        rbusy <= 1'b1;
        rbaud <= CLKDIV >> 1;           // sample mid-bit
        rbit  <= 4'd0;
      end
    end else if (rbaud != 0) begin
      rbaud <= rbaud - 1'b1;
    end else begin
      rbaud <= CLKDIV - 1'b1;
      rbit  <= rbit + 1'b1;
      if (rbit == 4'd0) begin
        if (rx) rbusy <= 1'b0;          // false start
      end else if (rbit <= 4'd8) begin
        rshift <= {rx, rshift[7:1]};
      end else begin                    // stop bit
        rbusy <= 1'b0;
        if (rx) begin
          win <= {win[55:0], rshift};
          rbyte_stb <= 1'b1;
        end
      end
    end
  end

  // B5 62 05 xx 02 00 06 8A, oldest byte in win[63:56]
  wire win_ack = (win == 64'hB5_62_05_01_02_00_06_8A);
  wire win_nak = (win == 64'hB5_62_05_00_02_00_06_8A);

  always @(posedge clk) begin
    if (rst) begin
      state <= S_OBSERVE;
      timer <= 0;
      rx_toggles <= 0;
      txp_bad <= 1'b0;
      {skipped, sent, ack, nak} <= 4'b0;
      tries <= 4'd0;
      tx_oe <= 1'b0;
      txd   <= 1'b1;
    end else begin
      case (state)
        S_OBSERVE: begin
          timer <= timer + 1'b1;
          if (rx != rx_q && rx_toggles != 16'hFFFF) rx_toggles <= rx_toggles + 1'b1;
          if (txp != txp_q || !txp) txp_bad <= 1'b1;
          if (txp_bad) begin
            skipped <= 1'b1;
            state <= S_SKIPPED;
          end else if (timer >= MIN_OBSERVE && rx_toggles >= MIN_RX_TOGGLES) begin
            timer <= 0;
            tx_oe <= 1'b1;              // drive idle-high first
            txd   <= 1'b1;
            tries <= tries + 1'b1;
            state <= S_LEAD;
          end else if (timer == OBSERVE_CYCLES - 1) begin
            skipped <= 1'b1;
            state <= S_SKIPPED;
          end
        end

        S_LEAD: begin                   // 10 idle bit times before the frame
          timer <= timer + 1'b1;
          if (timer == {CLKDIV, 3'b0} + {CLKDIV, 1'b0}) begin
            byte_idx <= 0;
            bit_idx  <= 0;
            baud     <= 0;
            shreg    <= {1'b1, frame_byte(6'd0), 1'b0};
            state    <= S_SEND;
          end
        end

        S_SEND: begin
          if (baud != 0) begin
            baud <= baud - 1'b1;
          end else begin
            baud  <= CLKDIV - 1'b1;
            txd   <= shreg[0];
            shreg <= {1'b1, shreg[9:1]};
            if (bit_idx == 4'd9) begin
              bit_idx <= 0;
              if (byte_idx == NBYTES - 1) begin
                timer <= 0;
                state <= S_TAIL;
              end else begin
                byte_idx <= byte_idx + 1'b1;
                shreg    <= {1'b1, frame_byte(byte_idx + 1'b1), 1'b0};
              end
            end else begin
              bit_idx <= bit_idx + 1'b1;
            end
          end
        end

        S_TAIL: begin                   // let the last stop bit finish, then release
          timer <= timer + 1'b1;
          if (timer == {CLKDIV, 1'b0}) begin
            tx_oe <= 1'b0;
            txd   <= 1'b1;
            sent  <= 1'b1;
            timer <= 0;
            state <= S_WAIT_ACK;
          end
        end

        S_WAIT_ACK: begin
          timer <= timer + 1'b1;
          if (rbyte_stb && win_ack) begin ack <= 1'b1; state <= S_DONE; end
          else if (rbyte_stb && win_nak) begin nak <= 1'b1; state <= S_DONE; end
          else if (timer == ACK_TIMEOUT - 1) begin
            timer <= 0;
            if (tries < MAX_TRIES) begin
              rx_toggles <= 0;          // fresh pin check before driving again
              state <= S_OBSERVE;
            end else
              state <= S_DONE;
          end
        end

        default: ;                      // S_SKIPPED, S_DONE: stay until reset
      endcase
    end
  end

endmodule
