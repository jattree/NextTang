# Gowin rejects backslash line continuations in this file. Every command is on
# one physical line.

create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
create_clock -name serial_clock -period 2.6891 [get_nets {serial_clock}]
create_clock -name pixel_clock -period 13.4454 [get_pins {video_pll/pll/CLKOUT1}]

create_clock -name clock_28 -period 35.714 [get_pins {machine_pll/pll/CLKOUT0}]
create_generated_clock -name clock_14 -source [get_pins {machine_pll/pll/CLKOUT0}] -divide_by 2 [get_pins {machine_pll/divider_14/CLKOUT}]
create_generated_clock -name clock_7 -source [get_pins {machine_pll/pll/CLKOUT0}] -divide_by 4 [get_pins {machine_pll/divider_7/CLKOUT}]
create_generated_clock -name cpu_clock -source [get_pins {machine_pll/divider_7/CLKOUT}] -divide_by 2 [get_pins {cpu_clock_divided_s0/Q}]

# The processor and the video output share only screen memory, which the
# display reads through a port of its own, and the border, which crosses on a
# synchroniser. Neither carries a timing requirement between the domains.
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {serial_clock pixel_clock}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clock_28 clock_14 clock_7 cpu_clock}]
set_clock_groups -asynchronous -group [get_clocks {serial_clock pixel_clock}] -group [get_clocks {clock_28 clock_14 clock_7 cpu_clock}]

# The first stage of the border synchroniser is the crossing itself.
set_false_path -to [get_regs {border_meta*}]

# Reset distribution. Both reset shifters and the CPU's own synchronised reset
# fan out to asynchronous clear and preset pins, which the timing engine treats
# as data paths needing a half-period. Reset is released once at power-up while
# nothing is running, so these carry no timing requirement.
set_false_path -from [get_regs {pixel_reset_shift*}]
set_false_path -from [get_regs {cpu_reset_shift*}]
set_false_path -from [get_regs {cpu/Reset_s*}]
