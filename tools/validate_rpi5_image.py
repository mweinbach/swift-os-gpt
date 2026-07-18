#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import re
import struct
import subprocess
import sys


def output(*command: str) -> str:
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)


def fail(message: str) -> int:
    print(f"Pi 5 image contract: {message}", file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: validate_rpi5_image.py KERNEL.ELF KERNEL8.IMG", file=sys.stderr)
        return 2

    kernel = Path(sys.argv[1])
    image = Path(sys.argv[2])
    nm = os.environ.get("LLVM_NM", "llvm-nm")
    objdump = os.environ.get("LLVM_OBJDUMP", "llvm-objdump")

    identity = output("file", str(kernel))
    if "ELF 64-bit LSB executable, ARM aarch64" not in identity:
        return fail(f"unexpected ELF: {identity.strip()}")

    headers = output(objdump, "-f", str(kernel))
    entry = re.search(r"start address:\s*0x([0-9a-fA-F]+)", headers)
    if not entry or int(entry.group(1), 16) != 0x80000:
        return fail("ELF entry is not the Image header at 0x80000")

    undefined = output(nm, "-u", str(kernel)).strip()
    if undefined:
        return fail(f"undefined symbols:\n{undefined}")

    symbols = output(nm, "-n", str(kernel))
    start = re.search(r"^([0-9a-fA-F]+)\s+\S\s+_start$", symbols, re.MULTILINE)
    if not start or int(start.group(1), 16) != 0x81000:
        return fail("reset body is not page-aligned at 0x81000")

    descriptor_contract = {
        "RPI5_BCM_HIGH_MMIO_L1_DESCRIPTOR": 0x0060001040000401,
        "RPI5_RP1_MMIO_L1_DESCRIPTOR": 0x0060001F00000401,
    }
    for name, expected in descriptor_contract.items():
        match = re.search(
            rf"^([0-9a-fA-F]+)\s+\S\s+{name}$",
            symbols,
            re.MULTILINE,
        )
        if not match or int(match.group(1), 16) != expected:
            return fail(f"{name} does not preserve its identity output address")

    data = image.read_bytes()
    if len(data) < 64:
        return fail("raw image is shorter than its 64-byte header")
    text_offset, image_size, flags = struct.unpack_from("<QQQ", data, 8)
    if data[56:60] != b"ARM\x64":
        return fail("AArch64 Image magic is missing")
    if text_offset != 0x80000:
        return fail(f"text_offset is 0x{text_offset:x}, expected 0x80000")
    if image_size < len(data):
        return fail("declared memory image is smaller than the raw file")
    if flags & 0xF != 0x2:
        return fail(f"flags 0x{flags:x} do not select little-endian 4 KiB pages")

    print(identity.strip())
    print(
        "Pi 5 image contract: entry=0x80000, reset=0x81000, "
        f"raw={len(data)} bytes, memory={image_size} bytes, 4 KiB pages"
    )
    print("hardware execution: UNVERIFIED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
