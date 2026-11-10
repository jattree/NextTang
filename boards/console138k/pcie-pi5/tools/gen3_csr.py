#!/usr/bin/env python3
"""Make a Gen3 (8 GT/s) x1 serdes.csr for the Console 138K PCIe design.

usage: gen3_csr.py path/to/pcie_gen3_x1.csr > src/serdes/serdes.csr

The template is GOWIN's, shipped with the IDE (1.9.12.03:
ipcore/SERDES_IP/IPlib/PCIE/csrDoc/pcie_gen3_x1.csr), and stays out of Git.
Sipeed's TangMega-138K pcie_gen2(5G) and pcie_gen3(8G) demos differ only in
serdes.csr, and Sipeed's Gen3 file is GOWIN's pcie_gen3_x4.csr with the edits
below. This applies the same edits to the x1 template. Run on the x4 template,
it reproduces Sipeed's Gen3 file exactly (before their later removal of the
dead early 0x808760 write, which leaves the final value unchanged).

Then run csr_rom.py on the result for the boot-register replay, and build as
for Gen2 (place option 1, route option 1).
"""
import sys

PREFIX = [
    'upar_write_driver(0xb00000,0x00FFAA55)',
    'upar_write_driver(0x808760,0x0001D010)',
    'upar_write_driver(0x808764,0x00005010)',
    'upar_write_driver(0x908760,0x00015010)',
    'upar_write_driver(0x908764,0x00005010)',
    'upar_write_driver(0x808984,0x00000000)',
]
SUBSTITUTIONS = [
    ('upar_write_driver(0xc00008,0x00000000)', 'upar_write_driver(0xc00008,0x00000003)'),
    ('upar_write_driver(0x808104,0x00022203)', 'upar_write_driver(0x808104,0x00022233)'),
    ('upar_write_driver(0x808000,0x00062203)', 'upar_write_driver(0x808000,0x00062233)'),
]
LAST = 'upar_write_driver(0xb00030,0x003f3f0f)'
SUFFIX = [
    'upar_write_driver(0xb000c8,0x110022C2)',
    'upar_write_driver(0xb000cc,0x05800000)',
    'upar_wirte_driver(0xb00048,0xFFF00004)',
    'upar_wirte_driver(0xb0004c,0x00000000)',
    'upar_wirte_driver(0xb00050,0xFFF00004)',
    'upar_wirte_driver(0xb00054,0x00000000)',
    'upar_wirte_driver(0xb00058,0xFFF00004)',
    'upar_wirte_driver(0xb0005c,0x00000000)',
    'upar_wirte_driver(0xb001d8,0x00000005)',
]


def main(argv):
    if len(argv) != 1:
        sys.exit(__doc__)
    with open(argv[0], encoding='utf-8') as f:
        lines = [ln.strip() for ln in f.read().replace('\r', '').split('\n') if ln.strip()]
    for old, new in SUBSTITUTIONS:
        hits = [i for i, ln in enumerate(lines) if ln == old]
        if len(hits) != 1:
            sys.exit('%s: expected one "%s", found %d' % (argv[0], old, len(hits)))
        lines[hits[0]] = new
    if not lines or lines[-1] != LAST:
        sys.exit('%s: last line is not %s' % (argv[0], LAST))
    sys.stdout.write('\n'.join(PREFIX + lines[:-1] + SUFFIX) + '\n')


if __name__ == '__main__':
    main(sys.argv[1:])
