// Keep the T80n microcode out of block ROM. Its clock-to-out starts every
// half-cycle data-in path in the core, and in block ROM those paths miss
// 28 MHz by up to 4 ns. Built from logic, the unmodified core closes timing.
INS "core/cpu_mod/z80n" syn_romstyle=logic;
