//
// Copyright 2026 K7 B210 Open contributors
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Measures the board oscillator against a PPS (GPS or SMA) in bus_clk.
//
// bus_clk is the 40 MHz VCTCXO x 2.5 (MMCM), always running and independent
// of UHD's master clock rate, so a perfect oscillator gives exactly
// NOMINAL = 100,000,000 bus_clk cycles between PPS edges. Periods outside
// +-TOL cycles of NOMINAL (missing or extra pulses) are not counted.
//
// Output (bus_clk, updated once per good edge): {good_edges[15:0],
// tick_sum[47:0]}, the number of good periods and the sum of their lengths.
// The host reads it twice and takes the difference: error over that interval
// = (dsum / (dedges * NOMINAL) - 1). Both wrap (handle modulo 2^16 / 2^48).
// last_period is the most recent good period (cycles).
//
// The radio_clk copies for the telemetry readbacks are transferred with a
// toggle handshake: the bus_clk snapshot only changes once per second.

module osc_monitor #(
  parameter [31:0] NOMINAL = 32'd100_000_000,
  parameter [31:0] TOL     = 32'd20_000          // +-200 ppm
) (
  input             clk,          // bus_clk
  input             pps_gps,      // raw pads
  input             pps_ext,
  // radio_clk side
  input             rclk,
  input             sel_ext,      // rclk domain, quasi-static: 1 = SMA PPS
  output reg [63:0] snap_r = 64'd0,   // {good_edges[15:0], tick_sum[47:0]}
  output reg [31:0] last_period_r = 32'd0
);

  // select + synchronize (sel is quasi-static)
  (* ASYNC_REG = "TRUE" *) reg [1:0] sel_s = 2'b00;
  (* ASYNC_REG = "TRUE" *) reg [2:0] pps_s = 3'b000;
  always @(posedge clk) begin
    sel_s <= {sel_s[0], sel_ext};
    pps_s <= {pps_s[1:0], sel_s[1] ? pps_ext : pps_gps};
  end
  wire rise = pps_s[1] & ~pps_s[2];

  reg [31:0] cnt = 32'd0;
  reg        seen = 1'b0;
  reg [15:0] edges = 16'd0;
  reg [47:0] sum = 48'd0;
  reg [31:0] last = 32'd0;
  reg        tgl = 1'b0;

  wire [31:0] period = cnt + 32'd1;
  wire        good = (period >= NOMINAL - TOL) && (period <= NOMINAL + TOL);

  always @(posedge clk) begin
    if (rise) begin
      cnt  <= 32'd0;
      seen <= 1'b1;
      if (seen && good) begin
        edges <= edges + 1'b1;
        sum   <= sum + period;
        last  <= period;
        tgl   <= ~tgl;
      end
    end else if (cnt != 32'hFFFFFFFF) begin
      cnt <= cnt + 32'd1;
    end
  end

  // ---- to radio_clk: copy once the toggle has been seen (data stable) ----
  (* ASYNC_REG = "TRUE" *) reg [2:0] tgl_r = 3'b000;
  always @(posedge rclk) begin
    tgl_r <= {tgl_r[1:0], tgl};
    if (tgl_r[2] != tgl_r[1]) begin
      snap_r        <= {edges, sum};
      last_period_r <= last;
    end
  end

endmodule
