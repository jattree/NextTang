# NextTang SD card layout

NextTang preserves the official System/Next games hierarchy so one FAT32 card
can remain useful in both environments. The common NextTang Loader will search:

```text
/games/Classic48/    48K .tap and supported .tzx files
/games/Classic128/   128K .tap and supported .tzx files
/games/Spec256/      NextTang Spec256 packs
/games/Next/         self-contained .NEX files (future Next core)
```

Checksum-valid VFAT long filenames are part of the loader contract. The first
hardware checkpoint catalogs files directly in the selected machine folder;
recursive browsing is future work. Other official folders—including
`/machines/next`, `/nextzxos`, `/dot`, `/sys` and `/tmp`—belong to System/Next
and are left untouched.

ROMs are user-supplied assets and are never bundled by NextTang. The proposed
lookup locations are:

```text
/machines/nexttang/roms/48.rom
/machines/nexttang/roms/128-0.rom
/machines/nexttang/roms/128-1.rom
```

NextTang core bitstreams are distributable project outputs, not ROMs. TangCore
continues to own its existing core directory and `.bin` packaging; the loader
inside a running Spectrum core does not reconfigure the FPGA.

Current evidence boundary: the read-only SDHC/FAT32/LFN stack, fragmented FAT
walking, shared menu and backpressured TAP/TZX stream pass simulation. Separate
48K and 128K exact-C images place, route and pass setup/hold timing. The 48K
image has mounted the physical card, cataloged `/games/Classic48`, streamed
`FINDERS KEEPERS.TZX` through the ROM loader, reached gameplay and returned to
the still-resident loader menu. The 128K image has streamed ordinary-speed
Spellbound into multi-room gameplay across its local-SRAM/DDR3 bank split; a
Three Weeks in Paradise turbo-loader remains incompatible. A timing-clean
local-memory Spec256 image has cataloged `/games/Spec256`, streamed and accepted
one exact Jetpac pack and reached enhanced gameplay. These are bounded hardware
results; TAP, other games, the combined Spec256/DDR3 profile and broad card/file
compatibility remain unverified.
SNA/Z80 files are hidden until atomic snapshot restore exists.
