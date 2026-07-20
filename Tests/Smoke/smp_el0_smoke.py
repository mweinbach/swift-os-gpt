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


EXPECTED_BEFORE_SMP = [
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
]

EXPECTED_AFTER_SMP = [
    "SWIFTOS:SMP_WORK_OK",
    "SWIFTOS:SMP_OK",
    "SWIFTOS:READY",
    "SWIFTOS:SCHEDULER_READY",
    "SWIFTOS:EL0_OK",
    "SWIFTOS:THREADS_OK",
    "SWIFTOS:PREEMPT_OK",
    "SWIFTOS:EL0_PREEMPTION_PROVEN",
]


def run_kernel(
    qemu: str,
    kernel: Path,
    timeout: float,
    virtualization: bool,
    cpu: str,
    processor_count: int,
) -> str:
    machine = "virt,gic-version=3"
    if virtualization:
        machine += ",virtualization=on"
    command = [
        qemu,
        "-machine", machine,
        "-cpu", cpu,
        "-accel", "tcg",
        "-smp", str(processor_count),
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


def validate(transcript: str, processor_count: int) -> None:
    if "SWIFTOS:PANIC" in transcript:
        raise AssertionError(f"kernel panic:\n{transcript}")
    position = -1
    expected = (
        EXPECTED_BEFORE_SMP
        + [
            f"SWIFTOS:SMP_CPU{processor_id}_ONLINE"
            for processor_id in range(1, processor_count)
        ]
        + [
            marker
            for processor_id in range(1, processor_count)
            for marker in (
                f"SWIFTOS:SMP_CPU{processor_id}_TASK1_OK",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK1_CHECKSUM=0x",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK2_OK",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK2_CHECKSUM=0x",
                f"SWIFTOS:SMP_CPU{processor_id}_STACK=0x",
            )
        ]
        + EXPECTED_AFTER_SMP
    )
    for marker in expected:
        position = transcript.find(marker, position + 1)
        if position < 0:
            raise AssertionError(f"missing ordered marker {marker}:\n{transcript}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--virtualization", action="store_true")
    parser.add_argument("--cpu", default="cortex-a72")
    parser.add_argument("--cpus", type=int, default=4)
    arguments = parser.parse_args()
    if arguments.cpus < 2 or arguments.cpus > 4:
        parser.error("--cpus must be between 2 and 4")
    transcript = run_kernel(
        os.environ.get("QEMU", "qemu-system-aarch64"),
        arguments.kernel.resolve(),
        arguments.timeout,
        arguments.virtualization,
        arguments.cpu,
        arguments.cpus,
    )
    try:
        validate(transcript, arguments.cpus)
    except AssertionError as error:
        print(f"SMP/EL0 smoke failed: {error}", file=sys.stderr)
        return 1
    entry = "EL2 handoff" if arguments.virtualization else "EL1 entry"
    print(
        "SMP/EL0 smoke: "
        f"{arguments.cpus} {arguments.cpu} CPUs, isolated Swift threads, "
        f"and preemption passed ({entry})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
