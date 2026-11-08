// Keep the T80n microcode out of block ROM. Its clock-to-out starts every
// half-cycle data-in path in the core, and in block ROM those paths miss
// 28 MHz by up to 4 ns. Built from logic, the unmodified core closes timing.
// The official core picks its CPU in a generate block (g_option bits 1:0);
// NextTang builds the debug-interface CPU, whose wrapper instance is "cpu".
// The core is instance "core" inside the shared machine, instance "machine".
INS "machine/core/gen_cpu_10.cpu_mod/cpu/z80n" syn_romstyle=logic;
