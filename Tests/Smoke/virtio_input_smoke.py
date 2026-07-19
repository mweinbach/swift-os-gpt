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
import tty
from typing import Any

from frame_smoke import (
    DeadlineLineReader,
    execute_qmp,
    find_serial_pty,
    read_qmp_message,
    read_serial_until,
    remaining,
)


def input_event(event_type: str, data: dict[str, Any]) -> dict[str, Any]:
    return {"type": event_type, "data": data}


def send_input(
    qmp: DeadlineLineReader,
    writer,
    command_id: str,
    events: list[dict[str, Any]],
    deadline: float,
) -> None:
    execute_qmp(
        qmp,
        writer,
        "input-send-event",
        command_id,
        {"events": events},
        timeout=remaining(deadline),
    )


def assert_default_smp_defers_input(
    qemu: str,
    kernel: Path,
    timeout: float,
) -> None:
    command = [
        qemu,
        "-machine", "virt,gic-version=3",
        "-cpu", "cortex-a72",
        "-accel", "tcg",
        "-smp", "4",
        "-m", "512M",
        "-device", "ramfb,id=ramfb0",
        "-global", "virtio-mmio.force-legacy=false",
        "-device", "virtio-keyboard-device,id=keyboard0",
        "-device", "virtio-mouse-device,id=mouse0",
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
            if not selector.select(
                timeout=max(0.0, deadline - time.monotonic())
            ):
                break
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            transcript.extend(chunk)
            if b"SWIFTOS:READY" in transcript \
                    or b"SWIFTOS:PANIC" in transcript:
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

    if b"SWIFTOS:PANIC" in transcript or b"SWIFTOS:READY" not in transcript:
        raise AssertionError(
            "default-SMP input boot failed:\n"
            + transcript.decode("utf-8", errors="replace")
        )
    if b"SWIFTOS:VIRTIO_INPUT_" in transcript:
        raise AssertionError(
            "default SMP incorrectly claimed live VirtIO input:\n"
            + transcript.decode("utf-8", errors="replace")
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--timeout", type=float, default=12.0)
    arguments = parser.parse_args()

    qemu = os.environ.get("QEMU", "qemu-system-aarch64")
    command = [
        qemu,
        "-machine", "virt,gic-version=3",
        "-cpu", "cortex-a72",
        "-accel", "tcg",
        "-smp", "1",
        "-m", "512M",
        "-device", "ramfb,id=ramfb0",
        "-global", "virtio-mmio.force-legacy=false",
        "-device", "virtio-keyboard-device,id=keyboard0",
        "-device", "virtio-mouse-device,id=mouse0",
        "-display", "none",
        "-monitor", "none",
        "-S",
        "-qmp", "stdio",
        "-serial", "pty",
        "-no-reboot",
        "-kernel", str(arguments.kernel.resolve()),
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=False,
        bufsize=0,
    )
    serial_descriptor: int | None = None
    try:
        assert process.stdin is not None
        assert process.stdout is not None
        deadline = time.monotonic() + arguments.timeout
        qmp = DeadlineLineReader(process.stdout)
        greeting = read_qmp_message(qmp, remaining(deadline))
        if "QMP" not in greeting:
            raise AssertionError(f"unexpected QMP greeting: {greeting}")
        execute_qmp(
            qmp,
            process.stdin,
            "qmp_capabilities",
            "caps",
            timeout=remaining(deadline),
        )
        serial_path = find_serial_pty(qmp, remaining(deadline))
        serial_descriptor = os.open(
            serial_path,
            os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK,
        )
        tty.setraw(serial_descriptor)
        execute_qmp(
            qmp,
            process.stdin,
            "cont",
            "boot",
            timeout=remaining(deadline),
        )

        transcript = bytearray()
        for marker in (
            b"SWIFTOS:VIRTIO_INPUT_KEYBOARD_ID=",
            b"SWIFTOS:VIRTIO_INPUT_POINTER_ID=",
            b"SWIFTOS:VIRTIO_INPUT_READY",
            b"SWIFTOS:READY",
        ):
            read_serial_until(
                process,
                serial_descriptor,
                transcript,
                marker,
                remaining(deadline),
            )

        send_input(
            qmp,
            process.stdin,
            "a-down",
            [input_event("key", {
                "down": True,
                "key": {"type": "qcode", "data": "a"},
            })],
            deadline,
        )
        read_serial_until(
            process,
            serial_descriptor,
            transcript,
            b"SWIFTOS:VIRTIO_INPUT_A_DOWN",
            remaining(deadline),
        )

        send_input(
            qmp,
            process.stdin,
            "a-up",
            [input_event("key", {
                "down": False,
                "key": {"type": "qcode", "data": "a"},
            })],
            deadline,
        )
        read_serial_until(
            process,
            serial_descriptor,
            transcript,
            b"SWIFTOS:VIRTIO_INPUT_A_UP",
            remaining(deadline),
        )

        send_input(
            qmp,
            process.stdin,
            "pointer-motion",
            [
                input_event("rel", {"axis": "x", "value": 37}),
                input_event("rel", {"axis": "y", "value": -19}),
            ],
            deadline,
        )
        read_serial_until(
            process,
            serial_descriptor,
            transcript,
            b"SWIFTOS:VIRTIO_INPUT_POINTER_DX_37_DY_NEG19",
            remaining(deadline),
        )

        send_input(
            qmp,
            process.stdin,
            "left-down",
            [input_event("btn", {"down": True, "button": "left"})],
            deadline,
        )
        read_serial_until(
            process,
            serial_descriptor,
            transcript,
            b"SWIFTOS:VIRTIO_INPUT_LEFT_DOWN",
            remaining(deadline),
        )

        send_input(
            qmp,
            process.stdin,
            "left-up",
            [input_event("btn", {"down": False, "button": "left"})],
            deadline,
        )
        read_serial_until(
            process,
            serial_descriptor,
            transcript,
            b"SWIFTOS:VIRTIO_INPUT_LEFT_UP",
            remaining(deadline),
        )
        read_serial_until(
            process,
            serial_descriptor,
            transcript,
            b"SWIFTOS:VIRTIO_INPUT_PROOF_OK",
            remaining(deadline),
        )

    finally:
        if serial_descriptor is not None:
            os.close(serial_descriptor)
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)

    assert_default_smp_defers_input(
        qemu,
        arguments.kernel.resolve(),
        arguments.timeout,
    )
    print(
        "VirtIO input smoke: QMP A down/up, relative +37/-19, and left "
        "down/up crossed the guest canonical queue; default SMP deferred it"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"VirtIO input smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
