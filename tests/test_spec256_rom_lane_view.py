"""The graphical ROM lane diagnostic must observe, and only observe.

The frozen-plane capture validated the loaded graphical planes and the physical
display path, because the display reads the planes. It could say nothing about
the eight graphical ROM lanes: `port_b_address(14'b0), port_b_data()` ties their
second port off in every ordinary build, so no capture has ever seen them. They
are read by all eight lanes on every ROM call and every interrupt vector, which
makes them the last loaded artifact with no hardware evidence.

`NEXTTANG_SPEC256_ROM_LANE_VIEW` routes that second port to the display and
holds every CPU, so the same capture method that validated the planes can be
pointed at the lanes.

A diagnostic that alters the thing it measures is worthless, so these tests pin
the two properties that matter: the ordinary targets are untouched by the
define, and the diagnostic differs from the target it stands in for by exactly
that one define.
"""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BOARDS = REPO_ROOT / "boards" / "console138k"
TOP = BOARDS / "nexttang_console138k_spectrum48.v"
LOADER = BOARDS / "nexttang_console138k_spec256_loader.v"
ROMVIEW = BOARDS / "nexttang_console138k_spec256_loader_romview.v"
DRIVER = BOARDS / "build_spectrum48.sh"


def defines(wrapper: Path) -> list[str]:
    return re.findall(r"^`define (\S+)", wrapper.read_text(), re.M)


def print_sources(profile: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(DRIVER), "--profile", profile, "--print-sources"],
        capture_output=True, text=True,
    )


class RomLaneViewWrapperTest(unittest.TestCase):
    def test_differs_from_the_ordinary_loader_by_one_define(self) -> None:
        """Anything else that differs would make the capture uncomparable."""
        loader = [d for d in defines(LOADER) if d != "NEXTTANG_SPECTRUM48_TOP"]
        romview = [d for d in defines(ROMVIEW) if d != "NEXTTANG_SPECTRUM48_TOP"]
        self.assertEqual(
            set(romview) - set(loader), {"NEXTTANG_SPEC256_ROM_LANE_VIEW"}
        )
        self.assertEqual(set(loader) - set(romview), set())

    def test_no_shipping_target_enables_the_view(self) -> None:
        """The define must never reach a target anyone builds for use."""
        for wrapper in sorted(BOARDS.glob("nexttang_console138k_*.v")):
            if wrapper == ROMVIEW:
                continue
            with self.subTest(wrapper=wrapper.name):
                self.assertNotIn("NEXTTANG_SPEC256_ROM_LANE_VIEW", defines(wrapper))

    def test_view_is_not_combined_with_ddr3(self) -> None:
        """Under DDR3 lane 0 is distributed RAM with no second port, so the
        display would read an undriven byte. The top level documents this;
        make it impossible to ship by accident."""
        declared = defines(ROMVIEW)
        self.assertIn("NEXTTANG_SPEC256_ROM_LANE_VIEW", declared)
        self.assertNotIn("NEXTTANG_SPECTRUM48_USE_DDR3", declared)


class RomLaneViewProfileTest(unittest.TestCase):
    def test_profile_resolves_and_selects_its_own_top(self) -> None:
        done = print_sources("spec256-loader-romview")
        self.assertEqual(done.returncode, 0, done.stderr)
        lines = done.stdout.split()
        self.assertEqual(lines[0], "nexttang_console138k_spec256_loader_romview")
        self.assertIn(str(ROMVIEW), lines)
        self.assertNotIn(str(LOADER), lines)

    def test_source_list_matches_the_ordinary_loader_but_for_the_top(self) -> None:
        """Same platform, same storage stack, same palette. If the two lists
        ever diverge further, the diagnostic stops measuring the target."""
        loader = print_sources("spec256-loader").stdout.split()[1:]
        romview = print_sources("spec256-loader-romview").stdout.split()[1:]
        self.assertEqual(len(loader), len(romview))
        self.assertEqual(set(loader) - set(romview), {str(LOADER)})
        self.assertEqual(set(romview) - set(loader), {str(ROMVIEW)})

    def test_profile_is_advertised_so_the_lint_gate_covers_it(self) -> None:
        usage = subprocess.run(
            ["bash", str(DRIVER), "--help"], capture_output=True, text=True,
        ).stdout
        match = re.search(r"--profile ([a-z0-9|-]+)", usage)
        assert match
        self.assertIn("spec256-loader-romview", match.group(1).split("|"))


class TopLevelWiringTest(unittest.TestCase):
    def test_planes_drive_the_plane_wire_not_the_display_wire(self) -> None:
        """All eight plane memories must feed spec256_plane_display_data, so
        the display source is selected in exactly one place."""
        source = TOP.read_text()
        self.assertEqual(
            source.count(".port_b_data(spec256_plane_display_data["), 8
        )
        self.assertEqual(source.count(".port_b_data(spec256_display_data["), 0)

    def test_view_holds_every_cpu(self) -> None:
        """A running CPU rewrites the planes and would make frames differ; the
        whole point is a static capture."""
        source = TOP.read_text()
        self.assertIn("`elsif NEXTTANG_SPEC256_ROM_LANE_VIEW", source)
        held = re.search(
            r"`elsif NEXTTANG_SPEC256_ROM_LANE_VIEW\n(?:\s*//.*\n)*"
            r"\s*wire cpu_reset = 1'b1;", source)
        self.assertIsNotNone(
            held, "the view must hold cpu_reset asserted unconditionally")

    def test_ordinary_builds_keep_the_second_port_tied_off(self) -> None:
        """The non-diagnostic macro must still tie port B off, or every
        ordinary build pays for a port it does not use."""
        source = TOP.read_text()
        self.assertIn(
            ".port_b_clock(cpu_clock), .port_b_address(14'b0), .port_b_data());",
            source,
        )


class ReferenceRendererTest(unittest.TestCase):
    """The reference must read the pack the way the hardware reads the lanes.

    A reference that disagrees with the hardware's address mapping would make a
    correct capture look wrong, which is worse than having no reference.
    """

    @staticmethod
    def synthetic_pack() -> bytes:
        """A pack whose ROM lanes encode their own lane index and address."""
        from tools.spec256 import rom_lane_view as view
        payload = bytearray(view.PALETTE_OFFSET + view.PALETTE_BYTES)
        for lane in range(view.LANE_COUNT):
            base = view.GRAPHICS_ROM_OFFSET + lane * view.LANE_BYTES
            for address in range(view.LANE_BYTES):
                # Bit `lane` of every byte is set only where address bit 0 is,
                # so a pixel's assembled index is 0xFF on odd addresses and
                # 0x00 on even ones -- a pattern that shifts visibly if any
                # lane is offset, zeroed or swapped.
                payload[base + address] = 0xFF if address & 1 else 0x00
        for index in range(256):
            offset = view.PALETTE_OFFSET + index * 3
            payload[offset:offset + 3] = bytes((index, index, index))
        return b"NTSP" + bytes(view.HEADER_BYTES - 4) + bytes(payload)

    def test_rejects_a_pack_without_the_magic(self) -> None:
        from tools.spec256 import rom_lane_view as view
        import tempfile
        with tempfile.TemporaryDirectory() as work:
            bad = Path(work) / "bad.ntsp"
            bad.write_bytes(bytes(view.HEADER_BYTES + view.PALETTE_OFFSET
                                  + view.PALETTE_BYTES))
            with self.assertRaises(SystemExit):
                view.read_pack(bad)

    def test_uses_the_hardware_address_mapping(self) -> None:
        from tools.spec256 import rom_lane_view as view
        from tools.spec256.render import spectrum_screen_offset
        import tempfile
        with tempfile.TemporaryDirectory() as work:
            pack = Path(work) / "synthetic.ntsp"
            pack.write_bytes(self.synthetic_pack())
            payload = view.read_pack(pack)
            indices = view.render(view.rom_lanes(payload), 0, payload)

        # The synthetic pack's background section is all zero, so background
        # substitution is a no-op here and the assembled index is visible
        # directly. Every pixel of a byte shares that byte's address, so the
        # index must follow the Spectrum screen layout, not a linear scan.
        for line, column in ((0, 0), (1, 0), (8, 3), (64, 31), (191, 31)):
            address = spectrum_screen_offset(line, column)
            expected = 0xFF if address & 1 else 0x00
            for pixel in range(8):
                with self.subTest(line=line, column=column, pixel=pixel):
                    self.assertEqual(
                        indices[line * 256 + column * 8 + pixel], expected)

    def test_half_selects_the_upper_window(self) -> None:
        """The two halves must address different bytes, or one build's capture
        would be indistinguishable from the other's."""
        from tools.spec256 import rom_lane_view as view
        import tempfile
        payload_bytes = bytearray(self.synthetic_pack())
        # Make the upper half differ from the lower for one lane.
        base = (view.HEADER_BYTES + view.GRAPHICS_ROM_OFFSET
                + view.HALF_BYTES)
        for address in range(view.HALF_BYTES):
            payload_bytes[base + address] ^= 0xFF
        with tempfile.TemporaryDirectory() as work:
            pack = Path(work) / "halves.ntsp"
            pack.write_bytes(bytes(payload_bytes))
            payload = view.read_pack(pack)
            lanes = view.rom_lanes(payload)
            lower = view.render(lanes, 0, payload)
            upper = view.render(lanes, 1, payload)
        self.assertNotEqual(lower, upper)


if __name__ == "__main__":
    unittest.main()
