#!/usr/bin/env bash
# Simulate the BAR2 completer, the DMA writer and the TX mux together with a
# root-complex model that parses every TLP, and the SerDes re-init with a DRP
# model and a synthetic write list (Icarus Verilog). No vendor tools.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
out=$(mktemp -d)
iverilog -g2005 -o "$out/tb_dma.vvp" "$here/../rtl/nt_dma_writer.v" "$here/../rtl/nt_bar_completer.v" \
    "$here/../rtl/nt_tl_tx_mux.v" "$here/tb_dma.v"
vvp "$out/tb_dma.vvp" | tee "$out/tb_dma.log" | tail -3
grep -q '^PASS: DMA writer simulation' "$out/tb_dma.log"
python3 "$here/../tools/csr_rom.py" "$here/reinit_test.csr" > "$out/nt_serdes_reinit_rom.vh"
iverilog -g2005 -I "$out" -o "$out/tb_reinit.vvp" "$here/../rtl/nt_serdes_reinit.v" "$here/tb_reinit.v"
vvp "$out/tb_reinit.vvp" | tee "$out/tb_reinit.log" | tail -3
grep -q '^PASS: SerDes re-init simulation' "$out/tb_reinit.log"
