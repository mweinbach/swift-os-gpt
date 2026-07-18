#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


def receive_qmp(stream, expected_id: str) -> dict:
    while True:
        line = stream.readline()
        if not line:
            raise AssertionError("QMP connection closed")
        message = json.loads(line)
        if message.get("id") == expected_id:
            if "error" in message:
                raise AssertionError(f"QMP {expected_id} failed: {message['error']}")
            return message


def execute_qmp(
    reader,
    writer,
    command: str,
    command_id: str,
    arguments: dict | None = None,
) -> dict:
    request: dict[str, object] = {"execute": command, "id": command_id}
    if arguments is not None:
        request["arguments"] = arguments
    writer.write(json.dumps(request).encode("utf-8") + b"\r\n")
    writer.flush()
    return receive_qmp(reader, command_id)


def wait_for_gui(process: subprocess.Popen[bytes], serial_log: Path, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    transcript = b""
    while time.monotonic() < deadline:
        if serial_log.exists():
            transcript = serial_log.read_bytes()
        if b"SWIFTOS:PANIC" in transcript:
            raise AssertionError(transcript.decode("utf-8", errors="replace"))
        if b"SWIFTOS:GUI_READY" in transcript:
            return transcript.decode("utf-8", errors="replace")
        if process.poll() is not None:
            break
        time.sleep(0.01)
    raise AssertionError(
        "GUI marker timeout:\n" + transcript.decode("utf-8", errors="replace")
    )


def parse_ppm(path: Path) -> tuple[int, int, bytes]:
    blob = path.read_bytes()
    match = re.match(
        rb"P6[ \t\r\n]+([0-9]+)[ \t\r\n]+([0-9]+)"
        rb"[ \t\r\n]+255(?:\r\n|[ \t\n])",
        blob,
    )
    if not match:
        raise AssertionError("invalid P6 screenshot")
    width, height = (int(value) for value in match.groups())
    pixels = blob[match.end():]
    if len(pixels) != width * height * 3:
        raise AssertionError("truncated PPM pixel data")
    return width, height, pixels


def assert_region(
    pixels: bytes,
    width: int,
    rectangle: tuple[int, int, int, int],
    expected: tuple[int, int, int],
    minimum_fraction: float = 0.95,
    tolerance: int = 2,
) -> None:
    start_x, start_y, end_x, end_y = rectangle
    matched = 0
    total = 0
    for y in range(start_y, end_y):
        for x in range(start_x, end_x):
            offset = (y * width + x) * 3
            actual = pixels[offset:offset + 3]
            if all(abs(actual[index] - expected[index]) <= tolerance for index in range(3)):
                matched += 1
            total += 1
    fraction = matched / total
    if fraction < minimum_fraction:
        raise AssertionError(
            f"region {rectangle} expected {expected}: {fraction:.1%} matched"
        )


def validate_screenshot(path: Path) -> None:
    width, height, pixels = parse_ppm(path)
    if (width, height) != (800, 600):
        raise AssertionError(f"unexpected screenshot size {width}x{height}")

    assert_region(pixels, width, (4, 80, 32, 180), (11, 16, 32))
    assert_region(pixels, width, (300, 4, 500, 28), (17, 24, 39))
    assert_region(pixels, width, (200, 34, 500, 36), (34, 211, 238))
    assert_region(pixels, width, (170, 340, 470, 410), (8, 14, 26))
    assert_region(pixels, width, (570, 278, 730, 286), (17, 24, 39))
    assert_region(pixels, width, (620, 500, 760, 525), (11, 16, 32))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=5.0)
    arguments = parser.parse_args()

    qemu = os.environ.get("QEMU", "qemu-system-aarch64")
    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(
        prefix="swiftos-gui-",
        dir=str(output.parent),
    ) as temporary:
        serial_log = Path(temporary) / "serial.log"
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
            "-qmp", "stdio",
            "-serial", f"file:{serial_log}",
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
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            assert process.stderr is not None
            deadline = time.monotonic() + arguments.timeout
            greeting_line = process.stdout.readline()
            if not greeting_line:
                error_output = process.stderr.read().decode("utf-8", errors="replace")
                raise AssertionError(f"QMP greeting missing: {error_output}")
            greeting = json.loads(greeting_line)
            if "QMP" not in greeting:
                raise AssertionError(f"unexpected QMP greeting: {greeting}")
            execute_qmp(
                process.stdout,
                process.stdin,
                "qmp_capabilities",
                "caps",
            )
            transcript = wait_for_gui(
                process,
                serial_log,
                max(0.1, deadline - time.monotonic()),
            )
            execute_qmp(process.stdout, process.stdin, "stop", "stop")
            execute_qmp(
                process.stdout,
                process.stdin,
                "screendump",
                "shot",
                {
                    "filename": str(output),
                    "device": "ramfb0",
                    "head": 0,
                    "format": "ppm",
                },
            )
            validate_screenshot(output)
            print("GUI smoke: 800x600 native ramfb regions passed")
            if "SWIFTOS:RAMFB_OK" not in transcript:
                raise AssertionError("serial transcript omitted RAMFB_OK")
            execute_qmp(process.stdout, process.stdin, "quit", "quit")
            process.wait(timeout=2)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"GUI smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
