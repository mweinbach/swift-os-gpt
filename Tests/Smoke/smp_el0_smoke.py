#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
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
    "SWIFTOS:EL0_MIGRATION_PROVEN",
]


def run_kernel(
    qemu: str,
    kernel: Path,
    timeout: float,
    virtualization: bool,
    cpu: str,
    processor_count: int,
    gic_version: int,
) -> str:
    machine = f"virt,gic-version={gic_version}"
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
            if (b"SWIFTOS:EL0_MIGRATION_PROVEN" in transcript
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
                f"SWIFTOS:SMP_CPU{processor_id}_TASK1_QUANTA=0x",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK2_OK",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK2_CHECKSUM=0x",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK2_QUANTA=0x",
                f"SWIFTOS:SMP_CPU{processor_id}_STACK=0x",
                f"SWIFTOS:SMP_CPU{processor_id}_TIMER_IRQS=0x",
            )
        ]
        + EXPECTED_AFTER_SMP
    )
    for marker in expected:
        position = transcript.find(marker, position + 1)
        if position < 0:
            raise AssertionError(f"missing ordered marker {marker}:\n{transcript}")

    # EL0 processors enter the shared scheduler concurrently. Require every
    # processor's local launch, userspace-report, and timer evidence without
    # assigning an order to otherwise independent CPUs.
    for processor_id in range(processor_count):
        for suffix in ("ONLINE", "REPORT", "TIMER_IRQ"):
            marker = f"SWIFTOS:EL0_CPU{processor_id}_{suffix}"
            if marker not in transcript:
                raise AssertionError(f"missing processor marker {marker}")

    stack_addresses: set[int] = set()
    checksums: set[int] = set()
    for processor_id in range(1, processor_count):
        first_quantum_count = marker_hex(
            transcript,
            f"SWIFTOS:SMP_CPU{processor_id}_TASK1_QUANTA=",
        )
        second_quantum_count = marker_hex(
            transcript,
            f"SWIFTOS:SMP_CPU{processor_id}_TASK2_QUANTA=",
        )
        timer_interrupt_count = marker_hex(
            transcript,
            f"SWIFTOS:SMP_CPU{processor_id}_TIMER_IRQS=",
        )
        if first_quantum_count <= 1 or second_quantum_count <= 1:
            raise AssertionError(
                f"CPU{processor_id} work was not split into bounded quanta"
            )
        if timer_interrupt_count < first_quantum_count + second_quantum_count:
            raise AssertionError(
                f"CPU{processor_id} timer IRQs do not cover its work quanta"
            )

        stack_address = marker_hex(
            transcript,
            f"SWIFTOS:SMP_CPU{processor_id}_STACK=",
        )
        if stack_address == 0 or stack_address in stack_addresses:
            raise AssertionError(
                f"CPU{processor_id} did not publish a unique nonzero stack"
            )
        stack_addresses.add(stack_address)

        for task_slot in (1, 2):
            checksum = marker_hex(
                transcript,
                f"SWIFTOS:SMP_CPU{processor_id}_TASK{task_slot}_CHECKSUM=",
            )
            if checksum == 0 or checksum in checksums:
                raise AssertionError(
                    f"CPU{processor_id} task {task_slot} checksum is invalid"
                )
            checksums.add(checksum)


def marker_hex(transcript: str, marker: str) -> int:
    match = re.search(re.escape(marker) + r"0x([0-9a-fA-F]+)", transcript)
    if match is None:
        raise AssertionError(f"missing hexadecimal evidence {marker}")
    return int(match.group(1), 16)


def self_test() -> None:
    processor_count = 4
    transcript: list[str] = list(EXPECTED_BEFORE_SMP)
    transcript.extend(
        f"SWIFTOS:SMP_CPU{processor_id}_ONLINE"
        for processor_id in range(1, processor_count)
    )
    for processor_id in range(1, processor_count):
        transcript.extend(
            (
                f"SWIFTOS:SMP_CPU{processor_id}_TASK1_OK",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK1_CHECKSUM="
                    f"0x{processor_id * 2 + 1:x}",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK1_QUANTA=0x2",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK2_OK",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK2_CHECKSUM="
                    f"0x{processor_id * 2 + 2:x}",
                f"SWIFTOS:SMP_CPU{processor_id}_TASK2_QUANTA=0x3",
                f"SWIFTOS:SMP_CPU{processor_id}_STACK="
                    f"0x{0x1000 * processor_id:x}",
                f"SWIFTOS:SMP_CPU{processor_id}_TIMER_IRQS=0x5",
            )
        )

    # Deliberately scramble each independently emitted per-CPU marker group.
    # The legacy lifecycle markers retain their runtime-defined order.
    transcript.extend(EXPECTED_AFTER_SMP[:4])
    transcript.extend(
        f"SWIFTOS:EL0_CPU{processor_id}_ONLINE"
        for processor_id in (3, 0, 2, 1)
    )
    transcript.extend(
        f"SWIFTOS:EL0_CPU{processor_id}_REPORT"
        for processor_id in (1, 3, 0, 2)
    )
    transcript.extend(EXPECTED_AFTER_SMP[4:6])
    transcript.extend(
        f"SWIFTOS:EL0_CPU{processor_id}_TIMER_IRQ"
        for processor_id in (2, 0, 1, 3)
    )
    transcript.extend(EXPECTED_AFTER_SMP[6:])
    valid_transcript = "\n".join(transcript) + "\n"
    validate(valid_transcript, processor_count)

    missing_cpu_evidence = valid_transcript.replace(
        "SWIFTOS:EL0_CPU2_REPORT\n",
        "",
    )
    try:
        validate(missing_cpu_evidence, processor_count)
    except AssertionError as error:
        if "missing processor marker SWIFTOS:EL0_CPU2_REPORT" not in str(error):
            raise
    else:
        raise AssertionError("missing per-CPU evidence unexpectedly passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", nargs="?", type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--virtualization", action="store_true")
    parser.add_argument("--cpu", default="cortex-a72")
    parser.add_argument("--cpus", type=int, default=4)
    parser.add_argument("--gic-version", type=int, choices=(2, 3), default=3)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    if arguments.cpus < 2 or arguments.cpus > 64:
        parser.error("--cpus must be between 2 and 64")
    if arguments.self_test:
        if arguments.kernel is not None:
            parser.error("kernel cannot be supplied with --self-test")
        try:
            self_test()
        except AssertionError as error:
            print(f"SMP/EL0 parser self-test failed: {error}", file=sys.stderr)
            return 1
        print("SMP/EL0 parser self-test passed")
        return 0
    if arguments.kernel is None:
        parser.error("kernel is required unless --self-test is used")
    managed_processor_count = min(arguments.cpus, 4)
    transcript = run_kernel(
        os.environ.get("QEMU", "qemu-system-aarch64"),
        arguments.kernel.resolve(),
        arguments.timeout,
        arguments.virtualization,
        arguments.cpu,
        arguments.cpus,
        arguments.gic_version,
    )
    try:
        validate(transcript, managed_processor_count)
    except AssertionError as error:
        print(f"SMP/EL0 smoke failed: {error}", file=sys.stderr)
        return 1
    entry = "EL2 handoff" if arguments.virtualization else "EL1 entry"
    print(
        "SMP/EL0 smoke: "
        f"{managed_processor_count}/{arguments.cpus} {arguments.cpu} CPUs, "
        f"GICv{arguments.gic_version}, isolated Swift threads, and "
        f"report-proven cross-CPU migration passed ({entry})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
