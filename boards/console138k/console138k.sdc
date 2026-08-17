create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
create_clock -name usr_clk -period 37.037 [get_ports {usr_clk}]
create_clock -name serial_clock -period 2.6891 [get_nets {serial_clock}]

# The board clock and the Dock's MS5351 reference are unrelated sources.
set_clock_groups -asynchronous -group {sys_clk} -group {usr_clk}

# Both crossings between the board clock and the pixel clock land on the first
# stage of a synchroniser, so they carry no timing requirement: vsync going out
# to the refresh counter, and the probe colours coming back in to be displayed.
set_false_path -to [get_regs {refresh_probe/*input_sync*}]
set_false_path -to [get_regs {probe_colour_meta*}]
