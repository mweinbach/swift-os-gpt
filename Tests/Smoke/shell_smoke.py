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


def read_until(
    process: subprocess.Popen[bytes],
    transcript: bytearray,
    marker: bytes,
    timeout: float,
) -> None:
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    try:
        while marker not in transcript and time.monotonic() < deadline:
            if not selector.select(timeout=max(0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            transcript.extend(chunk)
            if b"SWIFTOS:PANIC" in transcript:
                raise AssertionError(
                    transcript.decode("utf-8", errors="replace")
                )
    finally:
        selector.close()

    if marker not in transcript:
        raise AssertionError(
            f"missing shell marker {marker!r}:\n"
            + transcript.decode("utf-8", errors="replace")
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--timeout", type=float, default=5.0)
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
        "-display", "none",
        "-monitor", "none",
        "-serial", "stdio",
        "-no-reboot",
        "-kernel", str(arguments.kernel.resolve()),
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=False,
        bufsize=0,
    )
    transcript = bytearray()
    try:
        assert process.stdin is not None
        read_until(process, transcript, b"SWIFTOS:READY", arguments.timeout)

        commands = [
            (b"help\r", b"COMMANDS: HELP UNAME STATUS CLEAR ABOUT UPTIME"),
            (b"uname\r", b"SWIFTOS 0.1 AARCH64 EMBEDDED-SWIFT"),
            (b"status\r", b"FRAMEBUFFER: 800X600 XRGB8888"),
            (b"uptime\r", b"SECONDS: "),
            (b"bogus\r", b"COMMAND NOT FOUND: bogus"),
            (b"clear\r", b"[SCREEN CLEARED]"),
            (b"about\r", b"NO DARWIN OR APPLE FRAMEWORKS UNDER THIS SHELL"),
        ]
        for command_bytes, expected in commands:
            process.stdin.write(command_bytes)
            process.stdin.flush()
            read_until(process, transcript, expected, arguments.timeout)

        print("shell smoke: 7 interactive commands passed over PL011")
        return 0
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"shell smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)

