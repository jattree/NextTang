// Tang Nano 20K Next shell: synthesis constraints.
//
// Build the Z80's microcode decoder as logic. Left to itself, Gowin folds the
// instruction register into a pROMX9 block ROM, whose slow output put the
// core's half-cycle paths (to the DMA and the SD SPI master) over 7 ns past
// 28 MHz on the GW2AR-18 (first build, 2026-11-11), and it costs a block RAM
// the Nano does not have to spare. Board-specific, so the Console's mapping
// is unchanged.
INS "machine/core/gen_cpu_10.cpu_mod/cpu/z80n" syn_romstyle=logic;
