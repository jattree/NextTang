#!/usr/bin/env python3
"""Check that a phase-shifted PLL output is where the SDC says it is.

Gowin's PLL takes an output's phase as a count of VCO periods, a coarse whole
number plus eighths, so the same setting means a different angle whenever the
output divider changes. The SDC states the waveform separately, in
nanoseconds, and the timing analysis believes it. Nothing ties the two
together. In August 2026 the machine PLL's divider moved from 27 to 25 while
clock_28_n kept the 13 + 4/8 that had been 180 degrees, so the hardware ran it
at 194 degrees, 1.43 ns behind the waveform every timing report was built on,
until October.

This reads the PLL's defparams and the SDC's create_clock lines and fails if a
shifted output's first rising edge, measured from clock_28's, differs from the
waveform by more than a picosecond-scale tolerance.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DEFPARAM = re.compile(r"defparam\s+pll\.(\w+)\s*=\s*\"?(\w+)\"?\s*;")
WAVEFORM = (
    r"^\s*create_clock\s+-name\s+{name}\s+-period\s+([\d.]+)"
    r"(?:\s+-waveform\s+\{{([\d.]+)\s+[\d.]+\}})?"
)
TOLERANCE_NS = 0.01

# The machine PLL's phase-shifted outputs and the SDC clocks they drive.
SHIFTED_OUTPUTS = (("clock_28_n", 3),)


def clock_rise(text: str, name: str) -> tuple[float, float]:
    """Period and first rising edge of a create_clock in the SDC."""
    match = re.search(WAVEFORM.format(name=name), text, re.M)
    if not match:
        raise LookupError(f"no create_clock for {name}")
    return float(match.group(1)), float(match.group(2) or 0.0)


def phase_problems(sdc_text: str, pll_text: str) -> list[str]:
    params = dict(DEFPARAM.findall(pll_text))
    period, _ = clock_rise(sdc_text, "clock_28")
    reference_divider = int(params["ODIV0_SEL"])
    vco_ns = period / reference_divider
    problems = []
    for name, output in SHIFTED_OUTPUTS:
        divider = int(params[f"ODIV{output}_SEL"])
        if divider != reference_divider:
            problems.append(f"CLKOUT{output} divides by {divider}, CLKOUT0 by {reference_divider}")
            continue
        delay = (int(params[f"CLKOUT{output}_PE_COARSE"])
                 + int(params[f"CLKOUT{output}_PE_FINE"]) / 8) * vco_ns
        _, rise = clock_rise(sdc_text, name)
        if abs(delay - rise) > TOLERANCE_NS:
            problems.append(
                f"{name}: PLL CLKOUT{output} rises {delay:.3f} ns after clock_28, "
                f"the SDC says {rise:.3f} ns"
            )
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("sdc", type=Path, help="timing constraints used for the build")
    parser.add_argument("pll", type=Path, help="machine PLL source")
    args = parser.parse_args(argv)
    try:
        problems = phase_problems(args.sdc.read_text(), args.pll.read_text())
    except (LookupError, OSError, KeyError, ValueError) as error:
        print(f"pll phase check: FAIL, {error}", file=sys.stderr)
        return 1
    if problems:
        for problem in problems:
            print(f"pll phase check: FAIL, {problem}", file=sys.stderr)
        return 1
    print("pll phase check: pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
