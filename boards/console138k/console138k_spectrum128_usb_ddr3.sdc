# Spectrum 128K combines the proven ULA/DDR clocks with the direct USB host.
# Gowin requires each command on one physical line.

create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
create_clock -name serial_clock -period 2.6891 [get_nets {serial_clock}]
create_clock -name pixel_clock -period 13.4454 [get_pins {video_pll/pll/CLKOUT1}]
create_clock -name clock_28 -period 35.714 [get_pins {machine_pll/pll/CLKOUT0}]
create_generated_clock -name clock_14 -source [get_pins {machine_pll/pll/CLKOUT0}] -divide_by 2 [get_pins {machine_pll/divider_14/CLKOUT}]
create_generated_clock -name clock_7 -source [get_pins {machine_pll/pll/CLKOUT0}] -divide_by 4 [get_pins {machine_pll/divider_7/CLKOUT}]
create_generated_clock -name cpu_clock -source [get_pins {machine_pll/divider_7/CLKOUT}] -divide_by 2 [get_pins {cpu_clock_divided_s0/Q}]
create_clock -name memory_clock -period 2.500 [get_nets {memory_clock}]
create_clock -name controller_clock -period 10.000 [get_pins {ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
create_clock -name usb_clock -period 16.667 [get_pins {usb_pll/pll/CLKOUT0}]

set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {serial_clock pixel_clock}] -group [get_clocks {clock_28 clock_14 clock_7 cpu_clock}] -group [get_clocks {memory_clock}] -group [get_clocks {controller_clock}] -group [get_clocks {usb_clock}]

set_false_path -to [get_regs {scaler/acknowledge_meta*}]
set_false_path -to [get_regs {scaler/read_bank_meta*}]
set_false_path -to [get_regs {scaler/publish_meta*}]
set_false_path -to [get_regs {scaler/published_bank_meta*}]
set_false_path -from [get_regs {pixel_reset_shift*}]
set_false_path -from [get_regs {cpu_reset_shift*}]
set_false_path -from [get_regs {cpu/Reset_s*}]
set_false_path -to [get_regs {keyboard_keys_meta*}]
set_false_path -to [get_regs {usb_keyboard_keys_meta*}]
