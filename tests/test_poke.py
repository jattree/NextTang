import json
import tempfile
import unittest
from pathlib import Path

from tools.poke import MACHINES, TARGETS, Poke, build_image, main, parse_image


class PokeImageTests(unittest.TestCase):
    def test_round_trip_mixed_128k_targets(self) -> None:
        pokes = (
            Poke(TARGETS["logical"], 0, 0x8000, 42),
            Poke(TARGETS["bank"], 6, 0x1234, 99),
        )
        parsed = parse_image(build_image(MACHINES["128k"], pokes))
        self.assertEqual(parsed.machine, MACHINES["128k"])
        self.assertEqual(parsed.pokes, pokes)

    def test_rejects_rom_and_cross_machine_targets(self) -> None:
        with self.assertRaisesRegex(ValueError, "logical"):
            build_image(MACHINES["48k"], (Poke(0, 0, 0x3FFF, 1),))
        with self.assertRaisesRegex(ValueError, "physical-bank"):
            build_image(MACHINES["48k"], (Poke(1, 2, 0x1000, 1),))
        with self.assertRaisesRegex(ValueError, "graphics"):
            build_image(MACHINES["128k"], (Poke(2, 1, 0x8000, 1),))

    def test_crc_and_reserved_bytes_are_enforced(self) -> None:
        image = bytearray(build_image(MACHINES["spec256"], (
            Poke(TARGETS["graphics-all"], 0, 0x4000, 255),
        )))
        image[-1] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC"):
            parse_image(bytes(image))

    def test_cli_accepts_hex_json_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "trainer.json"
            output = root / "trainer.pok"
            source.write_text(json.dumps({
                "machine": "48k",
                "pokes": [{"address": "0x8000", "value": "0xff"}],
            }), encoding="utf-8")
            import sys
            old_argv = sys.argv
            try:
                sys.argv = ["poke.py", str(source), str(output)]
                self.assertEqual(main(), 0)
            finally:
                sys.argv = old_argv
            self.assertEqual(parse_image(output.read_bytes()).pokes[0].value, 255)


if __name__ == "__main__":
    unittest.main()
