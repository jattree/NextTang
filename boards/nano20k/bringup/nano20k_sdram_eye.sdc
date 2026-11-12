// Tang Nano 20K SDRAM eye scan: the crystal and the 84.375 MHz memory clock.
create_clock -name clock_27 -period 37.037 [get_ports {clock_27}]
create_clock -name memory_clock -period 11.852 [get_pins {pll/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {clock_27}] -group [get_clocks {memory_clock}]
