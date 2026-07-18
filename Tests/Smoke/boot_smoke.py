#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


EXPECTED = [
    "SWIFTOS:BOOT",
    "SWIFTOS:EL1",
    "SWIFTOS:BSS_OK",
    "SWIFTOS:DATA_OK",
    "SWIFTOS:SWIFT_OK",
    "SWIFTOS:TIMER_1",
    "SWIFTOS:TIMER_2",
    "SWIFTOS:TIMER_3",
    "SWIFTOS:READY",
]


def boot_once(qemu: str, kernel: Path, timeout: float) -> str:
    command = [
        qemu,
        "-machine", "virt,gic-version=3",
        "-cpu", "cortex-a72",
        "-accel", "tcg",
        "-smp", "1",
        "-m", "512M",
        "-display", "none",
        "-monitor", "none",
        "-serial", "stdio",
        "-no-reboot",
        "-kernel", str(kernel),
    ]
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    deadline = time.monotonic() + timeout
    chunks: list[str] = []
    try:
        assert process.stdout is not None
        while time.monotonic() < deadline:
            line = process.stdout.readline()
            if line:
                chunks.append(line)
                if "SWIFTOS:READY" in line:
                    break
                continue
            if process.poll() is not None:
                break
        else:
            chunks.append("<smoke timeout>\n")
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)

    return "".join(chunks).replace("\r", "")


def validate(transcript: str) -> None:
    if "SWIFTOS:PANIC" in transcript:
        raise AssertionError(f"kernel panic:\n{transcript}")

    position = -1
    for marker in EXPECTED:
        next_position = transcript.find(marker, position + 1)
        if next_position < 0:
            raise AssertionError(f"missing ordered marker {marker}:\n{transcript}")
        position = next_position


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--boots", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=5.0)
    arguments = parser.parse_args()

    qemu = os.environ.get("QEMU", "qemu-system-aarch64")
    for index in range(arguments.boots):
        transcript = boot_once(qemu, arguments.kernel.resolve(), arguments.timeout)
        try:
            validate(transcript)
        except AssertionError as error:
            print(f"boot {index + 1}/{arguments.boots} failed: {error}", file=sys.stderr)
            return 1
        print(f"boot {index + 1}/{arguments.boots}: ordered serial contract passed")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

