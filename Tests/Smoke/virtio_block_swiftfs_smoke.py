#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time


FIRST_BOOT = [
    b"SWIFTOS:BOOT",
    b"SWIFTOS:VIRTIO_BLOCK_READY",
    b"SWIFTOS:DATA_VOLUME_INITIALIZED",
    b"SWIFTOS:SWIFTFS_FORMATTED",
    b"SWIFTOS:SWIFTFS_SEEDED",
    b"SWIFTOS:SWIFTFS_DATA_OK",
    b"SWIFTOS:SWIFTFS_READY",
    b"SWIFTOS:READY",
]

SECOND_BOOT = [
    b"SWIFTOS:BOOT",
    b"SWIFTOS:VIRTIO_BLOCK_READY",
    b"SWIFTOS:DATA_VOLUME_MOUNTED",
    b"SWIFTOS:SWIFTFS_REMOUNTED",
    b"SWIFTOS:SWIFTFS_DATA_OK",
    b"SWIFTOS:SWIFTFS_READY",
    b"SWIFTOS:READY",
]

FAILURE_MARKERS = [
    b"SWIFTOS:PANIC",
    b"SWIFTOS:VIRTIO_BLOCK_INIT_FAILED",
    b"SWIFTOS:DATA_VOLUME_UNAVAILABLE",
    b"SWIFTOS:SWIFTFS_UNAVAILABLE",
    b"SWIFTOS:SWIFTFS_SEED_FAILED",
    b"SWIFTOS:SWIFTFS_DATA_INVALID",
]


def boot(
    qemu: str,
    kernel: Path,
    disk: Path,
    timeout: float,
) -> bytes:
    command = [
        qemu,
        "-machine", "virt,gic-version=3",
        "-cpu", "cortex-a72",
        "-accel", "tcg",
        "-smp", "1",
        "-m", "512M",
        "-device", "ramfb,id=ramfb0",
        "-global", "virtio-mmio.force-legacy=false",
        "-drive", f"if=none,format=raw,file={disk},id=users0",
        "-device", "virtio-blk-device,drive=users0,id=usersblk0",
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
            if not selector.select(timeout=max(0.0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            transcript.extend(chunk)
            if b"SWIFTOS:READY" in transcript or any(
                marker in transcript for marker in FAILURE_MARKERS
            ):
                break
    finally:
        selector.close()
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
    return bytes(transcript).replace(b"\r", b"")


def validate(transcript: bytes, expected: list[bytes], label: str) -> None:
    for marker in FAILURE_MARKERS:
        if marker in transcript:
            raise AssertionError(
                f"{label} reported {marker!r}:\n"
                + transcript.decode("utf-8", errors="replace")
            )
    position = -1
    for marker in expected:
        position = transcript.find(marker, position + 1)
        if position < 0:
            raise AssertionError(
                f"{label} missing ordered marker {marker!r}:\n"
                + transcript.decode("utf-8", errors="replace")
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--timeout", type=float, default=25.0)
    arguments = parser.parse_args()
    qemu = os.environ.get("QEMU", "qemu-system-aarch64")

    try:
        with tempfile.TemporaryDirectory(prefix="swiftos-swiftfs-") as directory:
            disk = Path(directory) / "users.raw"
            with disk.open("wb") as image:
                image.truncate(512 * 512)

            first = boot(
                qemu,
                arguments.kernel.resolve(),
                disk,
                arguments.timeout,
            )
            validate(first, FIRST_BOOT, "first boot")

            second = boot(
                qemu,
                arguments.kernel.resolve(),
                disk,
                arguments.timeout,
            )
            validate(second, SECOND_BOOT, "second boot")
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"VirtIO block/SwiftFS smoke failed: {error}", file=sys.stderr)
        return 1

    print(
        "VirtIO block/SwiftFS smoke: blank format, durable seed, and "
        "second-boot remount passed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
