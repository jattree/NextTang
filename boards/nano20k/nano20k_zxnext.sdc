// Tang Nano 20K Next shell. The crystal; every PLL and CLKDIV output is
// derived from it. The machine/memory PLL and the video PLL are not related
// in phase (hdmi_frame crosses between them through its line buffer).
create_clock -name clock_27 -period 37.037 [get_ports {clock_27}]
