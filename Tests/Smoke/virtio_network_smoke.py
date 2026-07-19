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
    b"SWIFTOS:BOOT",
    b"SWIFTOS:VIRTIO_NET_BOOT_POLLING",
    b"SWIFTOS:VIRTIO_NET_READY",
    b"SWIFTOS:VIRTIO_NET_MAC=0x0000525400123456",
    b"SWIFTOS:DHCP_BOUND",
    b"SWIFTOS:VIRTIO_NET_IPV4=0x000000000a2c000f",
    b"SWIFTOS:RAMFB_OK",
    b"SWIFTOS:READY",
]


def boot_with_user_network(qemu: str, kernel: Path, timeout: float) -> bytes:
    command = [
        qemu,
        "-machine", "virt,gic-version=3",
        "-cpu", "cortex-a72",
        "-accel", "tcg",
        "-smp", "1",
        "-m", "512M",
        "-device", "ramfb,id=ramfb0",
        "-global", "virtio-mmio.force-legacy=false",
        "-netdev",
        "user,id=swiftosnet,net=10.44.0.0/24,dhcpstart=10.44.0.15,restrict=on",
        "-device",
        "virtio-net-device,netdev=swiftosnet,mac=52:54:00:12:34:56",
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
    deadline = time.monotonic() + timeout
    chunks: list[bytes] = []
    selector = selectors.DefaultSelector()
    try:
        assert process.stdout is not None
        selector.register(process.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            remaining = max(0.0, deadline - time.monotonic())
            if not selector.select(timeout=remaining):
                chunks.append(b"<network smoke timeout>\n")
                break
            chunk = os.read(process.stdout.fileno(), 4096)
            if chunk:
                chunks.append(chunk)
                transcript = b"".join(chunks)
                if b"SWIFTOS:READY" in transcript or b"SWIFTOS:PANIC" in transcript:
                    break
                continue
            if process.poll() is not None:
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
    return b"".join(chunks).replace(b"\r", b"")


def validate(transcript: bytes) -> None:
    if b"SWIFTOS:PANIC" in transcript:
        raise AssertionError(
            "kernel panic:\n" + transcript.decode("utf-8", errors="replace")
        )
    position = -1
    for marker in EXPECTED:
        position = transcript.find(marker, position + 1)
        if position < 0:
            raise AssertionError(
                f"missing ordered marker {marker!r}:\n"
                + transcript.decode("utf-8", errors="replace")
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--timeout", type=float, default=8.0)
    arguments = parser.parse_args()
    transcript = boot_with_user_network(
        os.environ.get("QEMU", "qemu-system-aarch64"),
        arguments.kernel.resolve(),
        arguments.timeout,
    )
    try:
        validate(transcript)
    except AssertionError as error:
        print(f"VirtIO network smoke failed: {error}", file=sys.stderr)
        return 1
    print("VirtIO network DHCP smoke: deterministic lease contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
