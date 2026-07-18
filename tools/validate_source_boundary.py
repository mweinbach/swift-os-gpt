#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
GUEST_ROOTS = [ROOT / "Kernel", ROOT / "Userland"]
ALLOWED_MODULES = {"_Volatile"}
IMPORT = re.compile(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)


def main() -> int:
    violations: list[str] = []
    checked = 0
    for guest_root in GUEST_ROOTS:
        if not guest_root.exists():
            continue
        for source in sorted(guest_root.rglob("*.swift")):
            checked += 1
            text = source.read_text(encoding="utf-8")
            for module in IMPORT.findall(text):
                if module not in ALLOWED_MODULES:
                    relative = source.relative_to(ROOT)
                    violations.append(f"{relative}: guest import is not allowlisted: {module}")

    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1

    print(f"source boundary: {checked} guest Swift files, imports are allowlisted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
