#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys


def output(*command: str) -> str:
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_elf.py KERNEL.ELF", file=sys.stderr)
        return 2

    kernel = Path(sys.argv[1])
    nm = os.environ.get("LLVM_NM", "llvm-nm")
    objdump = os.environ.get("LLVM_OBJDUMP", "llvm-objdump")

    identity = output("file", str(kernel))
    if "ELF 64-bit LSB executable, ARM aarch64" not in identity:
        print(f"unexpected kernel artifact: {identity.strip()}", file=sys.stderr)
        return 1

    headers = output(objdump, "-f", str(kernel))
    match = re.search(r"start address:\s*0x([0-9a-fA-F]+)", headers)
    if not match or int(match.group(1), 16) != 0x40080000:
        print(f"unexpected ELF entry point:\n{headers}", file=sys.stderr)
        return 1

    undefined = output(nm, "-u", str(kernel)).strip()
    if undefined:
        print(f"kernel has undefined symbols:\n{undefined}", file=sys.stderr)
        return 1

    symbols = output(nm, "-n", str(kernel))
    for required in (" _start", " swiftos_main", " __boot_stack_top"):
        if required not in symbols:
            print(f"missing required symbol:{required}", file=sys.stderr)
            return 1

    print(identity.strip())
    print("ELF contract: entry=0x40080000, no undefined symbols")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
