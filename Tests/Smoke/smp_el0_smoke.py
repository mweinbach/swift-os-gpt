#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


EXPECTED = [
    "SWIFTOS:BOOT",
    "SWIFTOS:EL1",
    "SWIFTOS:BSS_OK",
    "SWIFTOS:DATA_OK",
    "SWIFTOS:FDT_OK",
    "SWIFTOS:MEMORY_READY",
    "SWIFTOS:PAGING_READY",
    "SWIFTOS:EXCEPTIONS_READY",
    "SWIFTOS:GIC_READY",
    "SWIFTOS:RAMFB_OK",
    "SWIFTOS:FRAMEBUFFER_READY",
    "SWIFTOS:SWIFT_OK",
    "SWIFTOS:TIMER_IRQ",
    "SWIFTOS:TIMER_1",
    "SWIFTOS:TIMER_2",
    "SWIFTOS:TIMER_3",
    "SWIFTOS:SMP_CPU1_ONLINE",
    "SWIFTOS:SMP_CPU2_ONLINE",
    "SWIFTOS:SMP_CPU3_ONLINE",
    "SWIFTOS:SMP_OK",
    "SWIFTOS:READY",
    "SWIFTOS:SCHEDULER_READY",
    "SWIFTOS:EL0_OK",
    "SWIFTOS:THREADS_OK",
    "SWIFTOS:PREEMPT_OK",
    "SWIFTOS:EL0_PREEMPTION_PROVEN",
]


def run_kernel(qemu: str, kernel: Path, timeout: float) -> str:
    command = [
        qemu,
        "-machine", "virt,gic-version=3",
        "-cpu", "cortex-a72",
        "-accel", "tcg",
        "-smp", "4",
        "-m", "512M",
        "-device", "ramfb,id=ramfb0",
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
        text=False,
        bufsize=0,
    )
    transcript = bytearray()
    selector = selectors.DefaultSelector()
    deadline = time.monotonic() + timeout
    try:
        assert process.stdout is not None
        selector.register(process.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            if not selector.select(timeout=max(0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            transcript.extend(chunk)
            if (b"SWIFTOS:EL0_PREEMPTION_PROVEN" in transcript
                    or b"SWIFTOS:PANIC" in transcript):
                break
    finally:
        selector.close()
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
    return transcript.decode("utf-8", errors="replace").replace("\r", "")


def validate(transcript: str) -> None:
    if "SWIFTOS:PANIC" in transcript:
        raise AssertionError(f"kernel panic:\n{transcript}")
    position = -1
    for marker in EXPECTED:
        position = transcript.find(marker, position + 1)
        if position < 0:
            raise AssertionError(f"missing ordered marker {marker}:\n{transcript}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    arguments = parser.parse_args()
    transcript = run_kernel(
        os.environ.get("QEMU", "qemu-system-aarch64"),
        arguments.kernel.resolve(),
        arguments.timeout,
    )
    try:
        validate(transcript)
    except AssertionError as error:
        print(f"SMP/EL0 smoke failed: {error}", file=sys.stderr)
        return 1
    print("SMP/EL0 smoke: 4 CPUs, isolated Swift threads, and preemption passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
