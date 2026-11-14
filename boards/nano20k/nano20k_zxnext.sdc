// Tang Nano 20K Next shell: clocks and the paths that are not timed.

create_clock -name clock_27 -period 37.037 [get_ports {clock_27}]

// machine/memory rPLL: 84.375 MHz SDRAM clock and its divide-by-3 28.125 MHz
// machine clock (three memory cycles per machine cycle); CLKDIVs make 14 and
// 7 MHz from the machine clock. Gowin's clock guide (UG286) has CLKOUTD3 rise
// on a falling edge of CLKOUT, so the machine clock is declared half a memory
// cycle (5.926 ns) after it. Until 2026-11-12 both were declared rising at
// zero, which analysed every crossing between them 5.9 ns out.
create_clock -name memory_clock -period 11.852 [get_pins {machine_pll/CLKOUT}]
create_clock -name clock_28 -period 35.556 -waveform {5.926 23.704} [get_pins {machine_pll/CLKOUTD3}]
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


// The BL616's FPGA-Companion SPI clock (about 20 MHz; 25 MHz allowed here), the
// clock of nexttang_companion_keyboard's SPI side. It crosses to the machine
// only through that module's toggle synchroniser.
create_clock -name companion_sclk -period 40 [get_ports {companion_sclk}]
set_clock_groups -asynchronous -group [get_clocks {companion_sclk}] -group [get_clocks {clock_27 serial_clock pixel_clock memory_clock clock_28 clock_14 clock_7}]

// ---- Pins (2026-11-12). Until now only the clocks were constrained, so "timing
// met" said nothing about the SDRAM or SD card pins.
//
// SDRAM (in the package): the clock leaves through sdram_clock_out (an ODDR
// giving memory_clock inverted), so the SDRAM samples commands, address, DQM
// and write data on memory_clock's falling edge, half a memory cycle after the
// I/O-cell registers launch them. The figures are a 166 MHz SDR part's (tIS
// 1.5 ns setup, tIH 0.8 ns hold); the die's own datasheet is not published.
// Write data is driven a cycle before WRITE (TRCD-2), so this single-cycle check
// is conservative for DQ. The read capture is a multicycle path measured on the
// board instead (bringup/nexttang_nano20k_sdram_eye.v, stress/README.md).
create_generated_clock -name sdram_clk_pin -source [get_pins {machine_pll/CLKOUT}] -invert [get_ports {O_sdram_clk}]
// The tool takes that clock as ideal at the pin, but it leaves the same way as
// the command registers do: 2.27 ns of clock route to the I/O cell, the ODDR,
// then 3.68 ns through the output buffer (6.19 ns in total for a command
// register in the first constrained build). 6.0 ns is declared, a little
// under, which errs strict on setup and stays far from the hold limit.
set_clock_latency -source 6.0 [get_clocks {sdram_clk_pin}]
set_output_delay -clock sdram_clk_pin -max 1.5 [get_ports {O_sdram_cke O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] IO_sdram_dq[*]}]
set_output_delay -clock sdram_clk_pin -min -0.8 [get_ports {O_sdram_cke O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] IO_sdram_dq[*]}]
// dq_out is loaded at step TRCD-2 and WRITE goes out at step TRCD-1, so the
// SDRAM samples the data one memory cycle later than the default check
// assumes. dq_out drives four pins per bit ({4{op_data}}), so it cannot sit in
// the I/O cells and needs that cycle (first build: -4.7 ns single-cycle).
set_multicycle_path -from [get_regs {sdram/dq_out*}] -to [get_ports {IO_sdram_dq[*]}] -setup -end 2
set_multicycle_path -from [get_regs {sdram/dq_out*}] -to [get_ports {IO_sdram_dq[*]}] -hold -end 1

// Requests from the machine side (ports A and C): a_op_*/c_op_* change on the
// same machine edge as their toggle; the memory side registers the toggle on
// its next edge and only uses the request on the edge after that, and the
// request is held until it is done. So these paths have two memory cycles from
// the machine edge (17.78 ns), not the 5.93 ns the default check gives. They
// were met in single-cycle builds; with the address registers in I/O cells
// (2026-11-12) one placement missed by 1.2 ns.
set_multicycle_path -from [get_regs {sdram/a_op_* sdram/c_op_*}] -to [get_clocks {memory_clock}] -setup -end 2
set_multicycle_path -from [get_regs {sdram/a_op_* sdram/c_op_*}] -to [get_clocks {memory_clock}] -hold -end 1

// SD card (SPI). SCK and MOSI leave from I/O-cell registers on clock_28's
// rising edge. First constrained build (2026-11-12): SCK reaches its pin 6.19
// ns after clock_28 rises. With the official sampling point (a falling edge)
// MISO had to be back 17.78 ns after that edge, less the pin's 3.7 ns into the
// fabric, which left the card 7.4 ns once the board is allowed for, against
// the SD spec's 14 (at 28 MHz CPU speed, SCK 14 MHz). Since 2026-11-13 the
// core's SPI master samples MISO on the rising edge after (spi_master
// g_miso_late, SPI_MISO_LATE in the top), a whole clock_28 period after the
// edge that moved SCK: the input delay is SCK's way out (6.19) + the board
// (0.5) + a spec card's 14 ns = 20.69 ns against that edge, captured one
// period later, so no multicycle. Min 0: the card holds MISO until after the
// next SCK fall, a period later still. SCK, MOSI and CS keep zero output
// delays: the report gives their own share (they leave from I/O registers).
set_output_delay -clock clock_28 -max 0 [get_ports {sd_clk sd_mosi sd_cs}]
set_output_delay -clock clock_28 -min 0 [get_ports {sd_clk sd_mosi sd_cs}]
set_input_delay -clock clock_28 -max 20.69 [get_ports {sd_miso}]
set_input_delay -clock clock_28 -min 0 [get_ports {sd_miso}]

// Any report_timing line replaces the default worst-path tables, so those come
// first (scripts/check_timing.py takes the worst slack from the first setup
// and hold reports); then the pin paths even when they pass, for their margins.
report_timing -setup -max_paths 25
report_timing -hold -max_paths 25
report_timing -setup -to [get_ports {O_sdram_cs_n O_sdram_ras_n O_sdram_addr[0] IO_sdram_dq[0]}] -max_paths 4
report_timing -hold -to [get_ports {O_sdram_cs_n O_sdram_ras_n O_sdram_addr[0] IO_sdram_dq[0]}] -max_paths 4
report_timing -setup -to [get_ports {sd_clk sd_mosi sd_cs}] -max_paths 3
report_timing -setup -from [get_ports {sd_miso}] -max_paths 2
