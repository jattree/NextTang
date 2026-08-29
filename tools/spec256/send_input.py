#!/usr/bin/env python3
"""Send live Spectrum keyboard or Kempston input to the runtime core."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import termios

from tools.spec256.gamepack import SPECTRUM_KEY_INDICES
from tools.spec256.load_gamepack import UART_BAUD, configure_serial


KEMPSTON_BITS = {
    "neutral": 0,
    "right": 1 << 0,
    "left": 1 << 1,
    "down": 1 << 2,
    "up": 1 << 3,
    "fire": 1 << 4,
}


def encode_key(name: str, *, pressed: bool) -> bytes:
    canonical = name.strip().upper()
    try:
        index = SPECTRUM_KEY_INDICES[canonical]
    except KeyError as error:
        raise ValueError(f"unknown Spectrum key: {name}") from error
    return bytes((ord("K"), index, int(pressed)))


def encode_joystick(controls: tuple[str, ...]) -> bytes:
    canonical = tuple(control.strip().lower() for control in controls)
    unknown = [control for control in canonical if control not in KEMPSTON_BITS]
    if unknown:
        raise ValueError(f"unknown Kempston control: {unknown[0]}")
    if "left" in canonical and "right" in canonical:
        raise ValueError("opposing horizontal Kempston controls")
    if "up" in canonical and "down" in canonical:
        raise ValueError("opposing vertical Kempston controls")
    state = 0
    for control in canonical:
        state |= KEMPSTON_BITS[control]
    return bytes((ord("J"), state))


def send_frame(port: Path, frame: bytes) -> None:
    descriptor = os.open(port, os.O_RDWR | os.O_NOCTTY)
    try:
        configure_serial(descriptor, UART_BAUD)
        os.write(descriptor, frame)
        termios.tcdrain(descriptor)
    finally:
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True, type=Path)
    commands = parser.add_subparsers(dest="command", required=True)

    key = commands.add_parser("key")
    key.add_argument("name")
    key.add_argument("state", choices=("press", "release"))

    joystick = commands.add_parser("joystick")
    joystick.add_argument(
        "controls", nargs="*", default=("neutral",),
        help="right left down up fire; omit all controls to release",
    )

    arguments = parser.parse_args()
    try:
        if arguments.command == "key":
            frame = encode_key(arguments.name, pressed=arguments.state == "press")
        else:
            frame = encode_joystick(tuple(arguments.controls) or ("neutral",))
        send_frame(arguments.port, frame)
    except (OSError, RuntimeError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
