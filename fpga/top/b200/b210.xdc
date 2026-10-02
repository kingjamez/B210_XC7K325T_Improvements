set_property -dict {PACKAGE_PIN G11 IOSTANDARD LVCMOS33} [get_ports PPS_IN_EXT]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33} [get_ports PPS_IN_INT]

set_property -dict {PACKAGE_PIN AA17 IOSTANDARD LVDS} [get_ports codec_main_clk_p]
set_property -dict {PACKAGE_PIN AA18 IOSTANDARD LVDS} [get_ports codec_main_clk_n]

set_property -dict {PACKAGE_PIN A8 IOSTANDARD LVCMOS33} [get_ports pll_ce]
set_property -dict {PACKAGE_PIN C9 IOSTANDARD LVCMOS33} [get_ports pll_mosi]
set_property -dict {PACKAGE_PIN A9 IOSTANDARD LVCMOS33} [get_ports pll_sclk]
set_property -dict {PACKAGE_PIN D9 IOSTANDARD LVCMOS33} [get_ports ref_sel]
set_property -dict {PACKAGE_PIN D8 IOSTANDARD LVCMOS33} [get_ports pll_lock]

# GPS UART pads (u-blox MAX-M10S). Direction is chosen at runtime; see gnss_pps_telemetry.v
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33 PULLUP true} [get_ports gps_io_a]
set_property -dict {PACKAGE_PIN B14 IOSTANDARD LVCMOS33 PULLUP true} [get_ports gps_io_b]

# #### FX3 Lines ##############################################################
# GPIF Data lines
set_property -dict {PACKAGE_PIN U6 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[0]}]
set_property -dict {PACKAGE_PIN AA3 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[1]}]
set_property -dict {PACKAGE_PIN V6 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[2]}]
set_property -dict {PACKAGE_PIN U5 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[3]}]
set_property -dict {PACKAGE_PIN V3 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[4]}]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[5]}]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[6]}]
set_property -dict {PACKAGE_PIN W4 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[7]}]
set_property -dict {PACKAGE_PIN W6 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[8]}]
set_property -dict {PACKAGE_PIN W1 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[9]}]
set_property -dict {PACKAGE_PIN Y6 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[10]}]
set_property -dict {PACKAGE_PIN AB2 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[11]}]
set_property -dict {PACKAGE_PIN AA5 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[12]}]
set_property -dict {PACKAGE_PIN Y3 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[13]}]
set_property -dict {PACKAGE_PIN AC1 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[14]}]
set_property -dict {PACKAGE_PIN AA2 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[15]}]
set_property -dict {PACKAGE_PIN AE6 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[16]}]
set_property -dict {PACKAGE_PIN AD5 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[17]}]
set_property -dict {PACKAGE_PIN AD6 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[18]}]
set_property -dict {PACKAGE_PIN AC6 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[19]}]
set_property -dict {PACKAGE_PIN AE5 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[20]}]
set_property -dict {PACKAGE_PIN AF3 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[21]}]
set_property -dict {PACKAGE_PIN AE3 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[22]}]
set_property -dict {PACKAGE_PIN AF2 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[23]}]
set_property -dict {PACKAGE_PIN W3 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[24]}]
set_property -dict {PACKAGE_PIN AF4 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[25]}]
set_property -dict {PACKAGE_PIN AD4 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[26]}]
set_property -dict {PACKAGE_PIN AF5 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[27]}]
set_property -dict {PACKAGE_PIN Y1 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[28]}]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[29]}]
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[30]}]
set_property -dict {PACKAGE_PIN V1 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {GPIF_D[31]}]

set_property -dict {PACKAGE_PIN AD1 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports IFCLK]
set_property -dict {PACKAGE_PIN AB5 IOSTANDARD LVCMOS18} [get_ports FX3_EXTINT]

# FX3 CTRL
set_property -dict {PACKAGE_PIN AA4 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL0]
set_property -dict {PACKAGE_PIN AE2 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL1]
set_property -dict {PACKAGE_PIN AE1 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL2]
set_property -dict {PACKAGE_PIN AC2 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL3]
set_property -dict {PACKAGE_PIN AB6 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL4]
set_property -dict {PACKAGE_PIN Y2 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL5]
set_property -dict {PACKAGE_PIN AD3 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL6]
set_property -dict {PACKAGE_PIN Y5 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL7]
set_property -dict {PACKAGE_PIN AC3 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL8]
set_property -dict {PACKAGE_PIN AB1 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL9]
set_property -dict {PACKAGE_PIN AC4 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL11]
set_property -dict {PACKAGE_PIN AB4 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports GPIF_CTL12]

#debug uart
set_property -dict {PACKAGE_PIN AD11 IOSTANDARD LVCMOS18} [get_ports FPGA_RXD0]
set_property -dict {PACKAGE_PIN AE11 IOSTANDARD LVCMOS18} [get_ports FPGA_TXD0]
#GPIO

set_property -dict {PACKAGE_PIN AA13 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {fp_gpio[0]}]
set_property -dict {PACKAGE_PIN AC13 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {fp_gpio[1]}]
set_property -dict {PACKAGE_PIN AB12 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {fp_gpio[2]}]
set_property -dict {PACKAGE_PIN AD13 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {fp_gpio[3]}]
set_property -dict {PACKAGE_PIN AE12 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {fp_gpio[4]}]
set_property -dict {PACKAGE_PIN AC12 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {fp_gpio[5]}]
set_property -dict {PACKAGE_PIN AA12 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {fp_gpio[6]}]
set_property -dict {PACKAGE_PIN AF12 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {fp_gpio[7]}]

# LED
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports LED_TXRX1_RX]
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS33} [get_ports LED_TXRX1_TX]
set_property -dict {PACKAGE_PIN E13 IOSTANDARD LVCMOS33} [get_ports LED_RX1]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports LED_RX2]
set_property -dict {PACKAGE_PIN H13 IOSTANDARD LVCMOS33} [get_ports LED_TXRX2_RX]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports LED_TXRX2_TX]

set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports LED_STATUS]
set_property -dict {PACKAGE_PIN F9 IOSTANDARD LVCMOS33} [get_ports LED_CLK_G]
set_property -dict {PACKAGE_PIN F8 IOSTANDARD LVCMOS33} [get_ports LED_CLK_R]

# CAT
set_property -dict {PACKAGE_PIN F23 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports codec_reset]
set_property -dict {PACKAGE_PIN E23 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports codec_en_agc]
set_property -dict {PACKAGE_PIN E22 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports codec_enable]
set_property -dict {PACKAGE_PIN G24 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports codec_txrx]
set_property -dict {PACKAGE_PIN E21 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports codec_sync]
set_property -dict {PACKAGE_PIN F22 IOSTANDARD LVCMOS18 SLEW SLOW PULLTYPE PULLUP } [get_ports cat_ce]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports cat_sclk]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports cat_mosi]
set_property -dict {PACKAGE_PIN G22 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports cat_miso]
set_property -dict {PACKAGE_PIN F24 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports cat_clkout_fpga]

# Control Lines
set_property -dict {PACKAGE_PIN C22 IOSTANDARD LVCMOS18} [get_ports {codec_ctrl_out[0]}]
set_property -dict {PACKAGE_PIN C26 IOSTANDARD LVCMOS18} [get_ports {codec_ctrl_out[1]}]
set_property -dict {PACKAGE_PIN C24 IOSTANDARD LVCMOS18} [get_ports {codec_ctrl_out[2]}]
set_property -dict {PACKAGE_PIN D21 IOSTANDARD LVCMOS18} [get_ports {codec_ctrl_out[3]}]
set_property -dict {PACKAGE_PIN C23 IOSTANDARD LVCMOS18} [get_ports {codec_ctrl_out[4]}]
set_property -dict {PACKAGE_PIN D24 IOSTANDARD LVCMOS18} [get_ports {codec_ctrl_out[5]}]
set_property -dict {PACKAGE_PIN D26 IOSTANDARD LVCMOS18} [get_ports {codec_ctrl_out[6]}]
set_property -dict {PACKAGE_PIN D23 IOSTANDARD LVCMOS18} [get_ports {codec_ctrl_out[7]}]

set_property -dict {PACKAGE_PIN A24 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {codec_ctrl_in[0]}]
set_property -dict {PACKAGE_PIN B21 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {codec_ctrl_in[1]}]
set_property -dict {PACKAGE_PIN C21 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {codec_ctrl_in[2]}]
set_property -dict {PACKAGE_PIN A23 IOSTANDARD LVCMOS18 SLEW SLOW} [get_ports {codec_ctrl_in[3]}]

# Tx Bus P0
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[0]}]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[1]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[2]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[3]}]
set_property -dict {PACKAGE_PIN AA15 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[4]}]
set_property -dict {PACKAGE_PIN AA14 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[5]}]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[6]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[7]}]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[8]}]
set_property -dict {PACKAGE_PIN Y15 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[9]}]
set_property -dict {PACKAGE_PIN AB20 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[10]}]
set_property -dict {PACKAGE_PIN AB19 IOSTANDARD LVCMOS18} [get_ports {tx_codec_d[11]}]

# RX Bus P1
set_property -dict {PACKAGE_PIN AF20 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[0]}]
set_property -dict {PACKAGE_PIN AF19 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[1]}]
set_property -dict {PACKAGE_PIN AE20 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[2]}]
set_property -dict {PACKAGE_PIN AD20 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[3]}]
set_property -dict {PACKAGE_PIN AE16 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[4]}]
set_property -dict {PACKAGE_PIN AD16 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[5]}]
set_property -dict {PACKAGE_PIN AB15 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[6]}]
set_property -dict {PACKAGE_PIN AB14 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[7]}]
set_property -dict {PACKAGE_PIN AD14 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[8]}]
set_property -dict {PACKAGE_PIN AC14 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[9]}]
set_property -dict {PACKAGE_PIN AD19 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[10]}]
set_property -dict {PACKAGE_PIN AC19 IOSTANDARD LVCMOS18} [get_ports {rx_codec_d[11]}]

# Frame syncs
set_property -dict {PACKAGE_PIN AB16 IOSTANDARD LVCMOS18} [get_ports codec_data_clk_p]
set_property -dict {PACKAGE_PIN AA19 IOSTANDARD LVCMOS18} [get_ports rx_frame_p]
set_property -dict {PACKAGE_PIN AB17 IOSTANDARD LVCMOS18} [get_ports tx_frame_p]
set_property -dict {PACKAGE_PIN AC18 IOSTANDARD LVCMOS18} [get_ports codec_fb_clk_p]

## RF Hardware Control
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports SFDX1_RX]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33} [get_ports SFDX1_TX]
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS33} [get_ports SFDX2_RX]
set_property -dict {PACKAGE_PIN H11 IOSTANDARD LVCMOS33} [get_ports SFDX2_TX]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports SRX1_RX]
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports SRX1_TX]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33} [get_ports SRX2_RX]
set_property -dict {PACKAGE_PIN G10 IOSTANDARD LVCMOS33} [get_ports SRX2_TX]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports tx_bandsel_a]
set_property -dict {PACKAGE_PIN G12 IOSTANDARD LVCMOS33} [get_ports tx_bandsel_b]
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports rx_bandsel_a]
set_property -dict {PACKAGE_PIN F12 IOSTANDARD LVCMOS33} [get_ports rx_bandsel_b]
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports rx_bandsel_c]

set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33} [get_ports tx_enable1]
set_property -dict {PACKAGE_PIN J10 IOSTANDARD LVCMOS33} [get_ports tx_enable2]


# IFCLK is 100 MHz GPIF clock
create_clock -period 10.000 -name IFCLK [get_ports IFCLK]
create_clock -period 16.276 -name codec_data_clk_p [get_ports codec_data_clk_p]



set_false_path -from [get_clocks -of_objects [get_pins gen_clks/inst/mmcm_adv_inst/CLKOUT1]] -to [get_clocks codec_data_clk_p]
set_false_path -from [get_clocks -of_objects [get_pins gen_clks/inst/mmcm_adv_inst/CLKOUT1]] -to [get_clocks -of_objects [get_pins b200_io_i0/BUFR_inst/O]]
set_false_path -from [get_clocks codec_data_clk_p] -to [get_clocks -of_objects [get_pins gen_clks/inst/mmcm_adv_inst/CLKOUT1]]
set_false_path -from [get_clocks -of_objects [get_pins b200_io_i0/BUFR_inst/O]] -to [get_clocks -of_objects [get_pins gen_clks/inst/mmcm_adv_inst/CLKOUT1]]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]