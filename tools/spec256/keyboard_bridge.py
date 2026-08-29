#!/usr/bin/env python3
"""Play a running Spec256 game with a keyboard attached to this machine.

The FPGA already accepts framed Spectrum-matrix and Kempston states over the
FT232RL, and that path is hardware-verified.  What was missing was anything to
drive it, which left the machine playable only by scripted key presses.  This
reads a real keyboard through evdev and streams those frames, so a keyboard on
the host plays a game on the board.

It is deliberately not the BL616 route.  That one needs a keyboard on the
Console's own USB and a UART on V14, and is blocked on questions the vendor has
not answered.  This needs neither.

The port is opened once and held.  `send_input` reopens per frame, which is
fine for a scripted probe and far too slow to play through.
"""

from __future__ import annotations

import argparse
import os
import select
import struct
import sys
import termios
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.spec256.gamepack import SPECTRUM_KEY_INDICES

UART_BAUD = 230400

# struct input_event: two longs of timestamp, then type, code, value.
EVENT = struct.Struct("llHHi")
EV_KEY = 0x01

# Linux keycodes to Spectrum matrix names.  Letters and digits map directly;
# the rest follow the layout a Spectrum player expects rather than the one the
# original hardware had, because there is no point reproducing the absence of
# a comma key.
KEYCODES = {
    30: "A", 48: "B", 46: "C", 32: "D", 18: "E", 33: "F", 34: "G", 35: "H",
    23: "I", 36: "J", 37: "K", 38: "L", 50: "M", 49: "N", 24: "O", 25: "P",
    16: "Q", 19: "R", 31: "S", 20: "T", 22: "U", 47: "V", 17: "W", 45: "X",
    21: "Y", 44: "Z",
    2: "1", 3: "2", 4: "3", 5: "4", 6: "5",
    7: "6", 8: "7", 9: "8", 10: "9", 11: "0",
    28: "ENTER", 57: "SPACE",
    42: "CAPS SHIFT", 54: "SYMBOL SHIFT",   # both shift keys
    29: "SYMBOL SHIFT", 97: "SYMBOL SHIFT",  # both control keys
    14: ("CAPS SHIFT", "0"),                 # Spectrum backspace chord
}

# Arrow keys and the usual fire buttons drive the Kempston joystick, which is
# what most games actually want.
KEMPSTON = {106: "right", 105: "left", 108: "down", 103: "up",
            56: "fire", 100: "fire"}
KEMPSTON_BITS = {"right": 1 << 0, "left": 1 << 1, "down": 1 << 2,
                 "up": 1 << 3, "fire": 1 << 4}


def _key_names(code: int) -> tuple[str, ...]:
    mapped = KEYCODES[code]
    return mapped if isinstance(mapped, tuple) else (mapped,)


def _key_frame(name: str, pressed: bool) -> bytes:
    return bytes((ord("K"), SPECTRUM_KEY_INDICES[name], int(pressed)))


class InputState:
    """Own physical-key lifetimes and emit only effective state changes."""

    def __init__(self) -> None:
        self._pressed_codes: set[int] = set()
        self._key_references: dict[str, int] = {}
        self._joystick_references: dict[str, int] = {}
        self._key_order: list[str] = []
        self.joystick = 0

    @property
    def held(self) -> tuple[str, ...]:
        return tuple(self._key_order)

    def handle(self, code: int, value: int) -> list[bytes]:
        """Apply one evdev key transition and return UART frames to send."""
        if value == 2 or value not in (0, 1):
            return []
        pressed = value == 1
        known = code in KEYCODES or code in KEMPSTON
        if not known:
            return []
        if pressed == (code in self._pressed_codes):
            return []

        if pressed:
            self._pressed_codes.add(code)
        else:
            self._pressed_codes.discard(code)

        frames: list[bytes] = []
        if code in KEMPSTON:
            control = KEMPSTON[code]
            old_count = self._joystick_references.get(control, 0)
            new_count = old_count + (1 if pressed else -1)
            if new_count > 0:
                self._joystick_references[control] = new_count
            else:
                self._joystick_references.pop(control, None)
            if (old_count == 0) != (new_count == 0):
                bit = KEMPSTON_BITS[control]
                self.joystick = (self.joystick | bit) if pressed else (
                    self.joystick & ~bit)
                frames.append(bytes((ord("J"), self.joystick)))

        if code in KEYCODES:
            names = _key_names(code)
            if not pressed:
                names = tuple(reversed(names))
            for name in names:
                old_count = self._key_references.get(name, 0)
                new_count = old_count + (1 if pressed else -1)
                if new_count > 0:
                    self._key_references[name] = new_count
                else:
                    self._key_references.pop(name, None)
                if old_count == 0 and pressed:
                    self._key_order.append(name)
                    frames.append(_key_frame(name, True))
                elif new_count == 0 and not pressed:
                    self._key_order.remove(name)
                    frames.append(_key_frame(name, False))
        return frames

    def release_all(self) -> list[bytes]:
        """Return the machine to neutral even after an interrupted bridge."""
        frames = [_key_frame(name, False) for name in reversed(self._key_order)]
        frames.append(bytes((ord("J"), 0)))
        self._pressed_codes.clear()
        self._key_references.clear()
        self._joystick_references.clear()
        self._key_order.clear()
        self.joystick = 0
        return frames


def configure_serial(descriptor: int, baud: int) -> None:
    speed = getattr(termios, f"B{baud}")
    attributes = termios.tcgetattr(descriptor)
    attributes[0] = 0
    attributes[1] = 0
    attributes[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
    attributes[3] = 0
    attributes[4] = speed
    attributes[5] = speed
    attributes[6][termios.VMIN] = 0
    attributes[6][termios.VTIME] = 1
    termios.tcsetattr(descriptor, termios.TCSANOW, attributes)


def find_keyboard(explicit: str | None) -> str:
    """Return an evdev node, preferring a USB keyboard over the built-in one."""
    if explicit:
        return explicit
    devices = Path("/proc/bus/input/devices").read_text(errors="replace")
    candidates = []
    for block in devices.split("\n\n"):
        if "kbd" not in block:
            continue
        handlers = [w for line in block.splitlines() if line.startswith("H:")
                    for w in line.split() if w.startswith("event")]
        if not handlers:
            continue
        name = next((line.split('"')[1] for line in block.splitlines()
                     if line.startswith("N: Name=")), "")
        bus_usb = "Bus=0003" in block
        # Skip lid switches and power buttons, which also claim kbd.
        if any(w in name.lower() for w in ("power", "sleep", "video", "lid")):
            continue
        candidates.append((bus_usb, f"/dev/input/{handlers[0]}", name))
    if not candidates:
        raise SystemExit("no keyboard found in /proc/bus/input/devices")
    candidates.sort(key=lambda c: not c[0])
    for _, node, name in candidates:
        if os.access(node, os.R_OK):
            print(f"keyboard: {name} ({node})")
            return node
    _, node, name = candidates[0]
    raise SystemExit(
        f"found {name} at {node} but cannot read it.\n"
        f"  sudo chgrp plugdev {node} && sudo chmod g+r {node}\n"
        f"or add yourself to the input group for a permanent fix.")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="bridge a host keyboard to a running Spec256 game")
    parser.add_argument("--port", default="/dev/ttyUSB2")
    parser.add_argument("--device", help="evdev node; autodetected otherwise")
    parser.add_argument("--quiet", action="store_true")
    arguments = parser.parse_args()

    node = find_keyboard(arguments.device)
    keyboard = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
    serial = os.open(arguments.port, os.O_RDWR | os.O_NOCTTY)
    configure_serial(serial, UART_BAUD)
    print(f"bridging to {arguments.port}. ESC quits and releases everything.")

    input_state = InputState()
    try:
        while True:
            ready, _, _ = select.select([keyboard], [], [], 0.5)
            if not ready:
                continue
            data = os.read(keyboard, EVENT.size * 64)
            for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _, _, etype, code, value = EVENT.unpack_from(data, offset)
                if etype != EV_KEY:
                    continue
                if code == 1:                        # ESC
                    raise KeyboardInterrupt
                frames = input_state.handle(code, value)
                for frame in frames:
                    os.write(serial, frame)
                if frames and not arguments.quiet:
                    print(f"  joystick {input_state.joystick:05b}  "
                          f"held={list(input_state.held) or '-'}", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        # Never leave a key or a direction latched on the machine.
        for frame in input_state.release_all():
            os.write(serial, frame)
        termios.tcdrain(serial)
        os.close(serial)
        os.close(keyboard)
        print("\nreleased everything")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
