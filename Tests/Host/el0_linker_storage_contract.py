#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys


USER_STACK_COUNT = 5
USER_STACK_SIZE = 64 * 1024
CONTEXT_FRAME_SIZE = 832
CONTEXT_SLOT_COUNT = USER_STACK_COUNT + 1


def fail(image: Path, message: str) -> int:
    print(f"EL0 linker storage contract ({image}): {message}", file=sys.stderr)
    return 1


def symbols_for(image: Path) -> dict[str, int]:
    nm = os.environ.get("LLVM_NM", "llvm-nm")
    output = subprocess.check_output(
        [nm, "-n", str(image)],
        text=True,
        stderr=subprocess.STDOUT,
    )
    symbols: dict[str, int] = {}
    for line in output.splitlines():
        match = re.match(r"^([0-9a-fA-F]+)\s+\S\s+(\S+)$", line)
        if match:
            symbols[match.group(2)] = int(match.group(1), 16)
    return symbols


def validate(image: Path) -> int:
    try:
        symbols = symbols_for(image)
    except (OSError, subprocess.CalledProcessError) as error:
        return fail(image, f"could not inspect symbols: {error}")

    required = (
        "__user_stacks_start",
        "__user_stack0_physical",
        "__user_stack0_physical_end",
        "__user_stack1_physical",
        "__user_stack1_physical_end",
        "__user_stacks_end",
        "__thread_contexts_start",
        "__thread_context_frames_end",
        "__thread_contexts_end",
    )
    missing = [name for name in required if name not in symbols]
    if missing:
        return fail(image, f"missing symbols: {', '.join(missing)}")

    stacks_start = symbols["__user_stacks_start"]
    stack0 = symbols["__user_stack0_physical"]
    stack0_end = symbols["__user_stack0_physical_end"]
    stack1 = symbols["__user_stack1_physical"]
    stack1_end = symbols["__user_stack1_physical_end"]
    stacks_end = symbols["__user_stacks_end"]
    if stacks_start != stack0:
        return fail(image, "stack zero does not begin the indexed stack span")
    if stack0_end != stack1:
        return fail(image, "stack zero and stack one are not contiguous")
    if stack0_end - stack0 != USER_STACK_SIZE:
        return fail(image, "stack zero is not exactly 64 KiB")
    if stack1_end - stack1 != USER_STACK_SIZE:
        return fail(image, "stack one does not establish the same stride")
    if stacks_end - stacks_start != USER_STACK_COUNT * USER_STACK_SIZE:
        return fail(image, "indexed stack span does not contain five stacks")
    if stacks_start & 0xFFF or stacks_end & 0xFFF:
        return fail(image, "indexed stack span is not page aligned")

    contexts_start = symbols["__thread_contexts_start"]
    frames_end = symbols["__thread_context_frames_end"]
    contexts_end = symbols["__thread_contexts_end"]
    if stacks_end != contexts_start:
        return fail(image, "indexed stacks are not adjacent to context storage")
    required_context_bytes = CONTEXT_SLOT_COUNT * CONTEXT_FRAME_SIZE
    if frames_end - contexts_start != required_context_bytes:
        return fail(image, "context span does not contain five frames plus scratch")
    if contexts_end - contexts_start < required_context_bytes:
        return fail(image, "aligned context section truncates a frame")
    if contexts_start & 0xFFF or contexts_end & 0xFFF:
        return fail(image, "context section is not page aligned")
    for index in range(CONTEXT_SLOT_COUNT):
        if (contexts_start + index * CONTEXT_FRAME_SIZE) & 0xF:
            return fail(image, f"context slot {index} is not 16-byte aligned")

    print(
        f"EL0 linker storage contract ({image}): "
        f"{USER_STACK_COUNT} stacks, {USER_STACK_COUNT} contexts, "
        "one launch scratch: passed"
    )
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: el0_linker_storage_contract.py KERNEL.ELF [KERNEL.ELF ...]",
            file=sys.stderr,
        )
        return 2
    for argument in sys.argv[1:]:
        result = validate(Path(argument))
        if result != 0:
            return result
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
