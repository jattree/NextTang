import struct
import tempfile
import unittest
from pathlib import Path

from tools.rzx import (
    Creator, Frame, RawBlock, Recording, Rzx, RzxError, Snapshot, main, parse, serialise,
)


def hand_built() -> bytes:
    """An uncompressed RZX laid out field by field from the 0.13 specification."""
    creator = b"\x10" + struct.pack("<I", 29) + b"Fuse".ljust(20, b"\0") + struct.pack("<HH", 1, 6)
    snap_data = b"\x01\x02\x03"
    snapshot = b"\x30" + struct.pack("<I", 17 + 3) + struct.pack("<I", 0) + b"Z80\0" + struct.pack("<I", 3) + snap_data
    frames = (struct.pack("<HH", 100, 2) + b"\xbf\xfe"     # two IN reads
              + struct.pack("<HH", 120, 0xFFFF)            # same reads again
              + struct.pack("<HH", 90, 0))                 # no reads
    recording = b"\x80" + struct.pack("<I", 18 + len(frames)) + struct.pack("<IBII", 3, 0, 42, 0) + frames
    return b"RZX!" + bytes([0, 13]) + struct.pack("<I", 0) + creator + snapshot + recording


class RzxTests(unittest.TestCase):
    def test_parses_a_hand_built_file(self) -> None:
        rzx = parse(hand_built())
        self.assertEqual((rzx.major, rzx.minor, rzx.flags), (0, 13, 0))
        creator, snapshot, recording = rzx.blocks
        self.assertEqual((creator.name, creator.major, creator.minor), ("Fuse", 1, 6))
        self.assertEqual((snapshot.extension, snapshot.data, snapshot.compress), ("Z80", b"\x01\x02\x03", False))
        self.assertEqual(recording.tstates, 42)
        self.assertEqual(recording.frames, [Frame(100, b"\xbf\xfe"), Frame(120, b"\xbf\xfe"), Frame(90, b"")])

    def test_uncompressed_round_trip_is_byte_exact(self) -> None:
        self.assertEqual(serialise(parse(hand_built())), hand_built())

    def test_compressed_round_trip(self) -> None:
        frames = [Frame(1000 + i, bytes([i & 0xFF, 0x1F])) for i in range(300)] + [Frame(5, b"\x1f")] * 4
        rzx = Rzx([Creator("NextTang", 0, 1, b"x"), Snapshot("SZX", bytes(range(256)) * 64),
                   Recording(69888, frames), RawBlock(0x99, b"future")])
        data = serialise(rzx)
        back = parse(data)
        self.assertEqual(back, rzx)
        self.assertTrue(len(data) < 256 * 64)  # the snapshot really was compressed

    def test_repeat_marker_is_written_for_identical_frames(self) -> None:
        rzx = Rzx([Recording(0, [Frame(10, b"\xff"), Frame(11, b"\xff")], compress=False)])
        body = serialise(rzx)[10 + 18:]
        self.assertEqual(body, struct.pack("<HH", 10, 1) + b"\xff" + struct.pack("<HH", 11, 0xFFFF))

    def test_external_snapshot_descriptor(self) -> None:
        rzx = Rzx([Snapshot("Z80", external_name="game.z80", external_checksum=0x1234, compress=False)])
        back = parse(serialise(rzx))
        self.assertEqual(back.snapshots[0].external_name, "game.z80")
        self.assertEqual(back.snapshots[0].external_checksum, 0x1234)

    def test_rejects_damage(self) -> None:
        good = hand_built()
        with self.assertRaisesRegex(RzxError, "signature"):
            parse(b"RZY!" + good[4:])
        with self.assertRaisesRegex(RzxError, "bad length"):
            parse(good[:-1])
        protected = bytearray(good)
        protected[good.index(b"\x80") + 14] = 1  # recording flags: protected
        with self.assertRaisesRegex(RzxError, "protected"):
            parse(bytes(protected))
        wrong_count = bytearray(good)
        wrong_count[good.index(b"\x80") + 5] = 4  # NF = 4, only 3 frames present
        with self.assertRaisesRegex(RzxError, "frame 3"):
            parse(bytes(wrong_count))
        bad_zlib = Rzx([Recording(0, [Frame(1, b"")])])
        data = bytearray(serialise(bad_zlib))
        data[-2] ^= 0xFF
        with self.assertRaisesRegex(RzxError, "zlib"):
            parse(bytes(data))

    def test_refuses_values_that_do_not_fit(self) -> None:
        with self.assertRaisesRegex(RzxError, "WORD"):
            serialise(Rzx([Recording(0, [Frame(0x10000, b"")])]))
        with self.assertRaisesRegex(RzxError, "19"):
            serialise(Rzx([Creator("x" * 20)]))

    def test_cli_info_frames_and_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "t.rzx"
            path.write_bytes(hand_built())
            self.assertEqual(main(["info", str(path)]), 0)
            self.assertEqual(main(["frames", str(path), "--count", "2"]), 0)
            out = Path(tmp) / "s.z80"
            self.assertEqual(main(["snapshot", str(path), str(out)]), 0)
            self.assertEqual(out.read_bytes(), b"\x01\x02\x03")
            self.assertEqual(main(["snapshot", str(path), str(out), "--index", "1"]), 1)
            (Path(tmp) / "bad.rzx").write_bytes(b"nope")
            self.assertEqual(main(["info", str(Path(tmp) / "bad.rzx")]), 1)


if __name__ == "__main__":
    unittest.main()
