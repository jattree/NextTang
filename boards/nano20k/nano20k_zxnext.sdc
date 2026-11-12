// Tang Nano 20K Next shell: clocks and the paths that are not timed.

create_clock -name clock_27 -period 37.037 [get_ports {clock_27}]

// machine/memory rPLL: 84.375 MHz SDRAM clock and its divide-by-3 28.125 MHz
// machine clock, both rising at time zero (three memory cycles per machine
// cycle); CLKDIVs make 14 and 7 MHz from the machine clock.
create_clock -name memory_clock -period 11.852 [get_pins {machine_pll/CLKOUT}]
create_clock -name clock_28 -period 35.556 [get_pins {machine_pll/CLKOUTD3}]
create_generated_clock -name clock_14 -source [get_pins {machine_pll/CLKOUTD3}] -divide_by 2 [get_pins {divide_14/CLKOUT}]
create_generated_clock -name clock_7 -source [get_pins {machine_pll/CLKOUTD3}] -divide_by 4 [get_pins {divide_7/CLKOUT}]

// video rPLL: 135 MHz serial clock, CLKDIV /5 27 MHz pixel clock.
create_clock -name serial_clock -period 7.407 [get_pins {video_pll/CLKOUT}]
create_generated_clock -name pixel_clock -source [get_pins {video_pll/CLKOUT}] -divide_by 5 [get_pins {divide_pixel/CLKOUT}]

// The two PLLs are independent: hdmi_frame crosses between them through its
// line buffer, and the reset synchronisers take the rest.
set_clock_groups -asynchronous -group [get_clocks {serial_clock pixel_clock}] -group [get_clocks {memory_clock clock_28 clock_14 clock_7}]
set_clock_groups -asynchronous -group [get_clocks {clock_27}] -group [get_clocks {serial_clock pixel_clock memory_clock clock_28 clock_14 clock_7}]

// The status line's snapshot of CPU and machine signals is display only: a
// torn sample garbles one status line, nothing else. (The Console false-paths
// the status UART's flag synchronisers the same way.)
set_false_path -to [get_regs {machine/status_uart/shift_message*}]
set_false_path -to [get_regs {machine/status_uart/flags_meta*}]

