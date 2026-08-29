# Gowin rejects backslash line continuations in this file. Every command is on
# one physical line.

create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
create_clock -name serial_clock -period 2.6891 [get_nets {serial_clock}]
create_clock -name pixel_clock -period 13.4454 [get_pins {video_pll/pll/CLKOUT1}]

# The machine PLL emits these from one VCO, so they are phase related. Declaring
# them as three independent clocks leaves the tool guessing at their alignment,
# and the ULA's video read crosses them into a falling edge latch inside zxula.
create_clock -name clock_28 -period 35.714 [get_pins {machine_pll/pll/CLKOUT0}]
create_generated_clock -name clock_14 -source [get_pins {machine_pll/pll/CLKOUT0}] -divide_by 2 [get_pins {machine_pll/divider_14/CLKOUT}]
create_generated_clock -name clock_7 -source [get_pins {machine_pll/pll/CLKOUT0}] -divide_by 4 [get_pins {machine_pll/divider_7/CLKOUT}]
create_generated_clock -name cpu_clock -source [get_pins {machine_pll/divider_7/CLKOUT}] -divide_by 2 [get_pins {cpu_clock_divided_s0/Q}]

# The frame buffer and its toggle handshakes are the only boundary between the
# native 50 Hz machine raster and the 720p60 output. Each scalar control signal
# is synchronised twice before use; the bank identifiers are held stable by the
# corresponding toggle until acknowledgement.
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {serial_clock pixel_clock}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clock_28 clock_14 clock_7 cpu_clock}]
set_clock_groups -asynchronous -group [get_clocks {serial_clock pixel_clock}] -group [get_clocks {clock_28 clock_14 clock_7 cpu_clock}]

set_false_path -to [get_regs {scaler/acknowledge_meta*}]
set_false_path -to [get_regs {scaler/read_bank_meta*}]
set_false_path -to [get_regs {scaler/publish_meta*}]
set_false_path -to [get_regs {scaler/published_bank_meta*}]
set_false_path -to [get_regs {status_uart/flags_meta*}]

# Existing reset and status crossings remain unchanged from the verified 48K
# target. The ULA profile does not yet enable CPU contention.
set_false_path -from [get_regs {pixel_reset_shift*}]
set_false_path -from [get_regs {cpu_reset_shift*}]
set_false_path -from [get_regs {cpu/Reset_s*}]

# The BL616 link receives at 2 Mbaud, which needs the 28 MHz domain: 3.5 MHz
# gives 1.75 clocks per bit and decodes nothing. Its key vector, scancode and
# debug flags therefore cross into the CPU domain on two flops each, and the
# first stage of a synchroniser is unconstrained by construction.
set_false_path -to [get_regs {keyboard_keys_meta*}]
set_false_path -to [get_regs {keyboard_scancode_meta*}]
set_false_path -to [get_regs {keyboard_debug_meta*}]
