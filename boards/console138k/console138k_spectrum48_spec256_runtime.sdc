# Direct 720p Spec256 runtime-loader target.  Its game-pack UART and FPGA USB
# host are separate asynchronous platform-input domains.

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
set_false_path -to [get_regs {game_pack_uart/receive_meta*}]

# The BL616 link receives at 2 Mbaud, which needs the 28 MHz domain: 3.5 MHz
# gives 1.75 clocks per bit and decodes nothing. Its key vector therefore
# crosses into the CPU domain on two flops, and the first stage of that
# synchroniser is unconstrained by construction. The diagnostic-only scancode
# and debug synchronisers are swept from this runtime profile.
set_false_path -to [get_regs {keyboard_keys_meta*}]

# Direct USB host and its 40-bit first-stage matrix synchronizer.
create_clock -name usb_clock -period 16.667 [get_pins {usb_pll/pll/CLKOUT0}]
set_clock_groups -asynchronous -group [get_clocks {usb_clock}] -group [get_clocks {sys_clk serial_clock pixel_clock clock_28 clock_7 cpu_clock}]
set_false_path -to [get_regs {usb_keyboard_keys_meta*}]
