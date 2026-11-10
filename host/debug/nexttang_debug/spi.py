"""A Raspberry Pi's own SPI link to the official Pi debug slave.

For boards that wire the core's Pi debug slave to a Pi's GPIO 8 to 11 (the
Nano 20K with a Pi Zero, nexttang_next_machine PI_SPI_PINS), run on the Pi:
one command is one transfer with chip select held, mode 0, MSB first, as
rtl/debug/nexttang_pi_spi_master.vhd drives the same slave from the FPGA.

Standard library only: the transfer is the Linux spidev ioctl
(SPI_IOC_MESSAGE), so the Pi needs no spidev Python package. Keep the clock
modest (default 500 kHz): the slave samples SCLK through synchronisers on the
28 MHz machine clock, and a main-memory byte must be ready before the next
edge.
"""

from __future__ import annotations

import ctypes
import fcntl
import os
import struct

SPI_IOC_MAGIC = ord("k")


def _iow(number: int, size: int) -> int:
    """Linux _IOW(SPI_IOC_MAGIC, number, size)."""
    return (1 << 30) | (size << 16) | (SPI_IOC_MAGIC << 8) | number


SPI_IOC_WR_MODE = _iow(1, 1)
SPI_IOC_WR_BITS_PER_WORD = _iow(3, 1)
SPI_IOC_WR_MAX_SPEED_HZ = _iow(4, 4)
TRANSFER_SIZE = 32   # struct spi_ioc_transfer


def spi_ioc_message(count: int) -> int:
    return _iow(0, TRANSFER_SIZE * count)


def pack_transfer(tx_address: int, rx_address: int, length: int, speed_hz: int) -> bytes:
    """struct spi_ioc_transfer: tx_buf, rx_buf (u64), len, speed_hz (u32),
    delay_usecs (u16), bits_per_word, cs_change, tx_nbits, rx_nbits,
    word_delay_usecs, pad (u8)."""
    return struct.pack("<QQIIHBBBBBB", tx_address, rx_address, length, speed_hz, 0, 8, 0, 0, 0, 0, 0)


class SpiLink:
    def __init__(self, device: str = "/dev/spidev0.0", speed_hz: int = 500_000) -> None:
        self.speed_hz = speed_hz
        self.fd = os.open(device, os.O_RDWR)
        fcntl.ioctl(self.fd, SPI_IOC_WR_MODE, struct.pack("B", 0))
        fcntl.ioctl(self.fd, SPI_IOC_WR_BITS_PER_WORD, struct.pack("B", 8))
        fcntl.ioctl(self.fd, SPI_IOC_WR_MAX_SPEED_HZ, struct.pack("<I", speed_hz))

    def close(self) -> None:
        os.close(self.fd)

    def __enter__(self) -> "SpiLink":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def exchange(self, sent: bytes) -> bytes:
        if not 1 <= len(sent) <= 4096:
            raise ValueError("a transfer is 1 to 4096 bytes")
        tx = ctypes.create_string_buffer(bytes(sent), len(sent))
        rx = ctypes.create_string_buffer(len(sent))
        transfer = bytearray(pack_transfer(ctypes.addressof(tx), ctypes.addressof(rx), len(sent), self.speed_hz))
        fcntl.ioctl(self.fd, spi_ioc_message(1), transfer)
        return rx.raw
