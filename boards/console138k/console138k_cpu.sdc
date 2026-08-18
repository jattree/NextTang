create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
create_clock -name clock_28 -period 35.714 [get_nets {clock_28}]

# T80Na drives the bus on both clock edges and ignores the core's clock enable,
# so the CPU needs a real 3.5 MHz clock rather than being stepped by an enable.
# The net is kept by name in the RTL: without that the synthesiser folds it into
# the probe bus, this constraint silently fails to attach, and every path in the
# CPU is timed eight times stricter than the design requires.
# Gowin rejects backslash line continuations in this file.
create_generated_clock -name cpu_clock -source [get_nets {clock_28}] -divide_by 8 [get_pins {cpu_clock_divider/CLKOUT}]

set_clock_groups -asynchronous -group {sys_clk} -group {clock_28}

# Reset distribution. Both the board reset and the CPU's own synchronised reset
# fan out to asynchronous clear and preset pins, which the timing engine treats
# as data paths needing a half-period. Reset is released once at power-up while
# nothing is running, so these carry no timing requirement.
set_false_path -from [get_regs {reset_shift*}]
set_false_path -from [get_regs {cpu/Reset_s*}]
