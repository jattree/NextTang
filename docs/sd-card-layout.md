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
48K and 128K exact-C images place, route and pass setup/hold timing. Neither
image nor a physical card read has been hardware-tested. SNA/Z80 files are
hidden until atomic snapshot restore exists; Spec256 pack dispatch remains
separate work.
