# Gowin rejects backslash line continuations in this file. Every command is on
# one physical line.

create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]

# Video PLL: 1125 MHz VCO, 375 MHz serial clock, 75 MHz pixel clock.
create_clock -name serial_clock -period 2.6667 [get_nets {serial_clock}]
create_clock -name pixel_clock -period 13.3333 [get_pins {video_pll/pll/CLKOUT1}]

# Machine clocks, all from one VCO and therefore phase related. The DCS can
# select 28 MHz, so the CPU clock is timed at its fastest speed. The core works
# on both edges of 28 MHz and of the CPU clock; those half-cycle paths are real
# and carry no exceptions.
create_clock -name clock_28 -period 35.714 [get_pins {clock_tree/machine_pll/pll/CLKOUT0}]
create_clock -name clock_28_n -period 35.714 -waveform {17.857 35.714} [get_pins {clock_tree/machine_pll/pll/CLKOUT3}]
# 14 and 7 MHz are PLL outputs, declared as clocks generated from 28 MHz at
# their own PLL pins, so the analysis follows all three from the PLL to every
# register. Taken from CLKDIVs they were declared at the divider pins, where
# Gowin starts a generated clock at zero; the divider's real delay was never
# seen, and a 28 to 14 MHz crossing in the core's Layer 2 pipeline failed hold
# unreported (raw/console138k-zxnext-own-game-full-speed-2026-10-27.md).
create_generated_clock -name clock_14 -source [get_pins {clock_tree/machine_pll/pll/CLKOUT0}] -divide_by 2 [get_pins {clock_tree/machine_pll/pll/CLKOUT1}]
create_generated_clock -name clock_7 -source [get_pins {clock_tree/machine_pll/pll/CLKOUT0}] -divide_by 4 [get_pins {clock_tree/machine_pll/pll/CLKOUT2}]
# There is no CPU clock. The core's CPU runs on clock_28 with clock enables
# (rtl/clock/nexttang_zxnext_cpu_enables.vhd), so every CPU path is a clock_28
# path, timed at 28 MHz with the half-cycle paths between its two edges. A CPU
# clock made in fabric and selected through a DCS was never analysed: Gowin
# starts a generated clock at zero at its own pin and does not propagate a
# clock through a DCS, and its real delay of 2 to 5 ns broke hold on the CPU's
# I/O read-back (raw/zxnext-clock-model-gap-2026-10-27.md).

# DDR3: Sipeed's generated controller runs its memory interface at 400 MHz and
# its user side at 100 MHz. Neither has a timed path to any other clock; the
# CPU memory service crosses into the controller domain through the CDC bridge.
create_clock -name memory_clock -period 2.500 [get_nets {memory_clock}]
create_clock -name controller_clock -period 10.000 [get_pins {ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {memory_clock}] -group [get_clocks {sys_clk serial_clock pixel_clock clock_28 clock_28_n clock_14 clock_7 controller_clock}]
set_clock_groups -asynchronous -group [get_clocks {controller_clock}] -group [get_clocks {sys_clk serial_clock pixel_clock clock_28 clock_28_n clock_14 clock_7}]

# The USB hosts run on their own 60 MHz PLL. Key and joystick state reaches
# the machine domain only through two-flop synchronisers.
create_clock -name usb_clock -period 16.667 [get_pins {usb_pll/pll/CLKOUT0}]
set_clock_groups -asynchronous -group [get_clocks {usb_clock}] -group [get_clocks {sys_clk serial_clock pixel_clock clock_28 clock_28_n clock_14 clock_7 memory_clock controller_clock}]
set_false_path -to [get_regs {keys_meta*}]
set_false_path -to [get_regs {kempston_meta*}]

# The frame buffer's toggle handshakes are the only boundary between the 50 Hz
# machine raster and 720p60. Each control signal is synchronised twice; bank
# identifiers are held stable by their toggle until acknowledged.
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {serial_clock pixel_clock}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clock_28 clock_28_n clock_14 clock_7}]
set_clock_groups -asynchronous -group [get_clocks {serial_clock pixel_clock}] -group [get_clocks {clock_28 clock_28_n clock_14 clock_7}]

set_false_path -to [get_regs {scaler/acknowledge_meta*}]
set_false_path -to [get_regs {scaler/read_bank_meta*}]
set_false_path -to [get_regs {scaler/publish_meta*}]
set_false_path -to [get_regs {scaler/published_bank_meta*}]
# The DDR3 frame store's line toggles cross into the controller domain the
# same way; each line's bank and number are held still for a source line or
# two output lines and read only after the toggle has crossed.
set_false_path -to [get_regs {scaler/line_done_meta*}]
set_false_path -to [get_regs {scaler/fetch_meta*}]
set_false_path -to [get_regs {status_uart/flags_meta*}]

# The ULA samples the NextREG 0x26/0x27 scroll registers on falling 7 MHz edges
# that coincide with the 28 MHz edges that update them. clock_7 comes from a
# CLKDIV and reaches its registers later than clock_28 does. scroll_x bit 2
# feeds px with no logic between, so under the placement setup needs, that
# path missed hold by 12 to 27 ps. Neither router option nor added hold
# uncertainty made the router add delay.
#
# The registers change only on a CPU NextREG write, which holds its value for
# many 28 MHz cycles, and the ULA resamples them every eight pixels. A
# violation can make one write take effect one 7 MHz edge early, or disturb
# one 8-pixel cell for one frame. Setup on these paths has more than 35 ns of
# slack, so this removes only the hold check. Every other path in the core
# stays timed.
set_false_path -from [get_regs {core/nr_26_ula_scrollx* core/nr_27_ula_scrolly*}] -to [get_regs {core/ula_mod/px* core/ula_mod/py*}] -hold

# Reset release happens once while nothing is running.
set_false_path -from [get_regs {pixel_reset_shift*}]
set_false_path -from [get_regs {clock_tree/reset_release/*}]

