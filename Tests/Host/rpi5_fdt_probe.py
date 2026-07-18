#!/usr/bin/env python3
from __future__ import annotations

import ctypes
from pathlib import Path
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: rpi5_fdt_probe.py PROBE.DYLIB PI5.DTB", file=sys.stderr)
        return 2

    library = ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
    validate = library.swiftos_validate_rpi5_fdt
    validate.argtypes = [ctypes.c_void_p]
    validate.restype = ctypes.c_int32

    blob = Path(sys.argv[2]).read_bytes()
    storage = ctypes.create_string_buffer(blob)
    result = validate(ctypes.addressof(storage))
    if result != 0:
        pl011_base = library.swiftos_rpi5_pl011_base
        pl011_base.argtypes = [ctypes.c_void_p, ctypes.c_int32]
        pl011_base.restype = ctypes.c_uint64
        serials = [
            pl011_base(ctypes.addressof(storage), index)
            for index in range(16)
        ]
        serials = [address for address in serials if address != (2**64 - 1)]
        print(
            "Raspberry Pi 5 FDT parser probe failed at contract "
            f"{result}; PL011 candidates={[hex(address) for address in serials]}",
            file=sys.stderr,
        )
        return 1

    print("Raspberry Pi 5 firmware FDT integration test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
