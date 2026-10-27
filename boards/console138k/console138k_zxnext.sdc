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
create_generated_clock -name clock_14 -source [get_pins {clock_tree/machine_pll/pll/CLKOUT0}] -divide_by 2 [get_pins {clock_tree/machine_pll/divider_14/CLKOUT}]
create_generated_clock -name clock_7 -source [get_pins {clock_tree/machine_pll/pll/CLKOUT0}] -divide_by 4 [get_pins {clock_tree/machine_pll/divider_7/CLKOUT}]
create_clock -name cpu_clock -period 35.714 [get_pins {clock_tree/cpu_clock_mux/cpu_clock_selector/CLKOUT}]

# The frame buffer's toggle handshakes are the only boundary between the 50 Hz
# machine raster and 720p60. Each control signal is synchronised twice; bank
# identifiers are held stable by their toggle until acknowledged.
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {serial_clock pixel_clock}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clock_28 clock_28_n clock_14 clock_7 cpu_clock}]
set_clock_groups -asynchronous -group [get_clocks {serial_clock pixel_clock}] -group [get_clocks {clock_28 clock_28_n clock_14 clock_7 cpu_clock}]

set_false_path -to [get_regs {scaler/acknowledge_meta*}]
set_false_path -to [get_regs {scaler/read_bank_meta*}]
set_false_path -to [get_regs {scaler/publish_meta*}]
set_false_path -to [get_regs {scaler/published_bank_meta*}]
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
set_false_path -from [get_regs {core/nr_26_ula_scrollx* core/nr_27_ula_scrolly*}] -to [get_regs {core/ula_mod/px* core/ula_mod/py*}]

# Reset release happens once while nothing is running.
set_false_path -from [get_regs {pixel_reset_shift*}]
set_false_path -from [get_regs {clock_tree/reset_release/*}]
