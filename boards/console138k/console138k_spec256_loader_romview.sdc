# Graphical ROM lane diagnostic. Identical to console138k_spec256_loader.sdc
# except that the two keyboard-synchroniser false paths are absent.
#
# NEXTTANG_SPEC256_ROM_LANE_VIEW holds cpu_reset asserted, so nothing consumes
# `keys` and synthesis prunes keyboard_keys_meta* and usb_keyboard_keys_meta*.
# Constraining registers that no longer exist is a hard TA2003 error, so those
# two lines are dropped here rather than weakened in the shared file. Every
# clock definition, clock group and reset false path is unchanged, so the
# diagnostic is placed and timed on the same terms as the target it stands in
# for.
create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
create_clock -name serial_clock -period 2.6891 [get_nets {serial_clock}]
create_clock -name pixel_clock -period 13.4454 [get_pins {video_pll/pll/CLKOUT1}]
create_clock -name clock_28 -period 35.714 [get_pins {machine_pll/pll/CLKOUT0}]
create_generated_clock -name clock_7 -source [get_pins {machine_pll/pll/CLKOUT0}] -divide_by 4 [get_pins {machine_pll/divider_7/CLKOUT}]
create_generated_clock -name cpu_clock -source [get_pins {machine_pll/divider_7/CLKOUT}] -divide_by 2 [get_pins {cpu_clock_divided_s0/Q}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {serial_clock pixel_clock}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clock_28 clock_7 cpu_clock}]
set_clock_groups -asynchronous -group [get_clocks {serial_clock pixel_clock}] -group [get_clocks {clock_28 clock_7 cpu_clock}]
set_false_path -from [get_regs {pixel_reset_shift*}]
set_false_path -from [get_regs {cpu_reset_shift*}]
create_clock -name usb_clock -period 16.667 [get_pins {usb_pll/pll/CLKOUT0}]
set_clock_groups -asynchronous -group [get_clocks {usb_clock}] -group [get_clocks {sys_clk serial_clock pixel_clock clock_28 clock_7 cpu_clock}]
