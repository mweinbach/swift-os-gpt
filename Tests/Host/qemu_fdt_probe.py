#!/usr/bin/env python3
from __future__ import annotations

import ctypes
from pathlib import Path
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: qemu_fdt_probe.py PROBE.DYLIB QEMU.DTB", file=sys.stderr)
        return 2

    library = ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
    validate = library.swiftos_validate_qemu_fdt
    validate.argtypes = [ctypes.c_void_p]
    validate.restype = ctypes.c_int32

    blob = Path(sys.argv[2]).read_bytes()
    storage = ctypes.create_string_buffer(blob)
    result = validate(ctypes.addressof(storage))
    if result != 0:
        print(f"QEMU FDT parser probe failed at contract {result}", file=sys.stderr)
        return 1

    print("QEMU FDT integration test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

