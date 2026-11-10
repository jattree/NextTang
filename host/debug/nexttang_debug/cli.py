"""nexttang-debug: talk to the official Pi debug slave inside NextTang's core.

    nexttang-debug status
    nexttang-debug pause | resume | step [COUNT]
    nexttang-debug regs
    nexttang-debug set PC 8000
    nexttang-debug peek 8000 64          (Z80 address, through the MMU; banks
                                          5 and 7 need the CPU paused)
    nexttang-debug peek --sram 40000 64  (2 MB main-memory address)
    nexttang-debug poke 8000 3E 01 C9
    nexttang-debug nextreg 07 [VALUE]
    nexttang-debug reset [--hard]

Numbers are hexadecimal. The link is the Console's debug UART (the FT232R by
default); the core must carry the debugger (CORE_OPTION in the board top).
"""

from __future__ import annotations

import argparse
import sys

from .protocol import (SYSTEM_HARD_RESET, SYSTEM_SOFT_RESET, DebugError, PiDebug, Z80Memory)
from .uart import UartLink

DEFAULT_PORT = "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A5069RR4-if00-port0"


def hex_int(text: str) -> int:
    return int(text, 16)


def hexdump(address: int, data: bytes) -> str:
    lines = []
    for start in range(0, len(data), 16):
        row = data[start:start + 16]
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        lines.append(f"{address + start:06X}  {row.hex(' ').upper():<47}  {text}")
    return "\n".join(lines)


def show_status(debug: PiDebug) -> str:
    status = debug.status()
    state = ("running", "stopping", "paused", "stepping")[status.bus]
    flags = [state]
    if status.halted:
        flags.append("in HALT")
    if status.dma_active:
        flags.append("DMA active")
    if status.error:
        flags.append("ERROR")
    return f"status {status.raw:02X}: " + ", ".join(flags)


def show_registers(debug: PiDebug) -> str:
    regs = debug.registers()
    first = "  ".join(f"{name} {regs[name]:04X}" for name in ("PC", "SP", "AF", "BC", "DE", "HL", "IX", "IY"))
    second = "  ".join(f"{name} {regs[name]:04X}" for name in ("AF'", "BC'", "DE'", "HL'"))
    third = f"I {regs['I']:02X}  R {regs['R']:02X}  IM {regs['IM']}  IFF1 {regs['IFF1']}  IFF2 {regs['IFF2']}  HALT {regs['HALT']}"
    return "\n".join((first, second, third))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="nexttang-debug", description=__doc__.split("\n\n")[0])
    parser.add_argument("--port", default=DEFAULT_PORT, help="serial device of the debug UART")
    parser.add_argument("--baud", type=int, default=115200)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("version")
    commands.add_parser("pause")
    commands.add_parser("resume")
    step = commands.add_parser("step")
    step.add_argument("count", nargs="?", type=int, default=1)
    commands.add_parser("regs")
    set_reg = commands.add_parser("set")
    set_reg.add_argument("register")
    set_reg.add_argument("value", type=hex_int)
    peek = commands.add_parser("peek")
    peek.add_argument("--sram", action="store_true", help="ADDRESS is a 2 MB main-memory address")
    peek.add_argument("address", type=hex_int)
    peek.add_argument("length", type=hex_int, nargs="?", default=0x40)
    poke = commands.add_parser("poke")
    poke.add_argument("--sram", action="store_true", help="ADDRESS is a 2 MB main-memory address")
    poke.add_argument("address", type=hex_int)
    poke.add_argument("data", type=hex_int, nargs="+")
    nextreg = commands.add_parser("nextreg")
    nextreg.add_argument("register", type=hex_int)
    nextreg.add_argument("value", type=hex_int, nargs="?")
    reset = commands.add_parser("reset")
    reset.add_argument("--hard", action="store_true")
    args = parser.parse_args(argv)

    try:
        with UartLink(args.port, args.baud) as link:
            debug = PiDebug(link)
            if args.command == "status":
                print(show_status(debug))
            elif args.command == "version":
                version = debug.version()
                print(f"Pi debug interface version {version.version}: " + ", ".join(version.names))
            elif args.command == "pause":
                debug.pause()
                print(show_registers(debug))
            elif args.command == "resume":
                debug.resume()
                print(show_status(debug))
            elif args.command == "step":
                for _ in range(args.count):
                    debug.step()
                print(show_registers(debug))
            elif args.command == "regs":
                if not debug.status().paused:
                    raise DebugError("pause the CPU first: registers are read while it is stopped")
                print(show_registers(debug))
            elif args.command == "set":
                debug.set_register(args.register, args.value)
                print(show_registers(debug))
            elif args.command == "peek":
                if args.sram:
                    data = debug.read_memory(args.address, args.length)
                else:
                    data = Z80Memory(debug).read(args.address, args.length)
                print(hexdump(args.address, data))
            elif args.command == "poke":
                data = bytes(value & 0xFF for value in args.data)
                if args.sram:
                    debug.write_memory(args.address, data)
                else:
                    Z80Memory(debug).write(args.address, data)
            elif args.command == "nextreg":
                if args.value is None:
                    print(f"NextREG {args.register:02X} = {debug.nextreg(args.register):02X}")
                else:
                    debug.set_nextreg(args.register, args.value)
            elif args.command == "reset":
                debug.system(SYSTEM_HARD_RESET if args.hard else SYSTEM_SOFT_RESET)
    except (DebugError, OSError) as error:
        print(f"nexttang-debug: {error}", file=sys.stderr)
        return 1
    return 0
