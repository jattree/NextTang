// Tang Nano 20K bring-up: the 27 MHz crystal. The rPLL outputs (135 MHz
// serial, 81 MHz SDRAM) and the CLKDIV pixel clock are derived from it.
create_clock -name clock_27 -period 37.037 [get_ports {clock_27}]
