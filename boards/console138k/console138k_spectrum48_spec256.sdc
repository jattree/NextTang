# Direct 720p Spec256 target. The 14 MHz ULA and frame buffer are deliberately
# absent; graphical RAM crosses only through its independent pixel-clock port.

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

# Direct USB-A gamepad/keyboard host. Normalized controls cross into the
# machine domain through explicit two-stage scalar synchronizers.
create_clock -name usb_clock -period 16.667 [get_pins {usb_pll/pll/CLKOUT0}]
set_clock_groups -asynchronous -group [get_clocks {usb_clock}] -group [get_clocks {sys_clk serial_clock pixel_clock clock_28 clock_7 cpu_clock}]
set_false_path -to [get_regs {usb_keyboard_keys_meta*}]
set_false_path -to [get_regs {usb_kempston_meta*}]

# BL616 keyboard synchroniser first stages, unconstrained by construction.
set_false_path -to [get_regs {keyboard_scancode_meta*}]
set_false_path -to [get_regs {keyboard_debug_meta*}]
