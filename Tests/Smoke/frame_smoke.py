#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import tempfile
import time
import tty


class DeadlineLineReader:
    def __init__(self, stream) -> None:
        self.file_descriptor = stream.fileno()
        self.buffer = bytearray()
        self.serial_path: str | None = None
        os.set_blocking(self.file_descriptor, False)

    def read_line(self, timeout: float) -> bytes:
        deadline = time.monotonic() + timeout
        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                line = bytes(self.buffer[:newline + 1])
                del self.buffer[:newline + 1]
                return line

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("QMP response timeout")

            selector = selectors.DefaultSelector()
            selector.register(self.file_descriptor, selectors.EVENT_READ)
            try:
                if not selector.select(timeout=remaining):
                    raise AssertionError("QMP response timeout")
                try:
                    chunk = os.read(self.file_descriptor, 4096)
                except BlockingIOError:
                    continue
            finally:
                selector.close()

            if not chunk:
                raise AssertionError("QMP connection closed")
            self.buffer.extend(chunk)


def receive_qmp(reader: DeadlineLineReader, expected_id: str, timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while True:
        message = read_qmp_message(reader, deadline - time.monotonic())
        if message.get("id") == expected_id:
            if "error" in message:
                raise AssertionError(f"QMP {expected_id} failed: {message['error']}")
            return message


def read_qmp_message(reader: DeadlineLineReader, timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while True:
        line = reader.read_line(deadline - time.monotonic())
        if not line.strip():
            continue
        serial_match = re.search(rb"char device redirected to (/[^\s]+)", line)
        if serial_match:
            reader.serial_path = serial_match.group(1).decode("utf-8")
            continue
        try:
            return json.loads(line)
        except json.JSONDecodeError as error:
            raise AssertionError(f"invalid QMP record {line!r}") from error


def execute_qmp(
    reader,
    writer,
    command: str,
    command_id: str,
    arguments: dict | None = None,
    timeout: float = 2.0,
) -> dict:
    request: dict[str, object] = {"execute": command, "id": command_id}
    if arguments is not None:
        request["arguments"] = arguments
    writer.write(json.dumps(request).encode("utf-8") + b"\r\n")
    writer.flush()
    return receive_qmp(reader, command_id, timeout)


def find_serial_pty(reader: DeadlineLineReader, timeout: float) -> str:
    if reader.serial_path is not None:
        return reader.serial_path
    deadline = time.monotonic() + timeout
    while True:
        line = reader.read_line(deadline - time.monotonic())
        match = re.search(rb"char device redirected to (/[^\s]+)", line)
        if match:
            reader.serial_path = match.group(1).decode("utf-8")
            return reader.serial_path


def read_serial_until(
    process: subprocess.Popen[bytes],
    file_descriptor: int,
    transcript: bytearray,
    marker: bytes,
    timeout: float,
) -> None:
    selector = selectors.DefaultSelector()
    selector.register(file_descriptor, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    try:
        while marker not in transcript and time.monotonic() < deadline:
            if not selector.select(timeout=max(0.0, deadline - time.monotonic())):
                break
            try:
                chunk = os.read(file_descriptor, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                break
            transcript.extend(chunk)
            if process.poll() is not None:
                break
    finally:
        selector.close()

    if marker not in transcript:
        raise AssertionError(
            f"serial marker timeout for {marker!r}:\n"
            + transcript.decode("utf-8", errors="replace")
        )
    if b"SWIFTOS:PANIC" in transcript:
        raise AssertionError(transcript.decode("utf-8", errors="replace"))


def write_serial(file_descriptor: int, data: bytes, timeout: float) -> None:
    selector = selectors.DefaultSelector()
    selector.register(file_descriptor, selectors.EVENT_WRITE)
    deadline = time.monotonic() + timeout
    offset = 0
    try:
        while offset < len(data) and time.monotonic() < deadline:
            if not selector.select(timeout=max(0.0, deadline - time.monotonic())):
                break
            try:
                offset += os.write(file_descriptor, data[offset:])
            except BlockingIOError:
                continue
    finally:
        selector.close()

    if offset != len(data):
        raise AssertionError(f"serial write timeout after {offset}/{len(data)} bytes")


def assert_deadline_reader_rejects_partial_line() -> None:
    read_descriptor, write_descriptor = os.pipe()
    stream = os.fdopen(read_descriptor, "rb", buffering=0)
    try:
        os.write(write_descriptor, b"{")
        reader = DeadlineLineReader(stream)
        try:
            reader.read_line(0.02)
        except AssertionError as error:
            if str(error) != "QMP response timeout":
                raise
        else:
            raise AssertionError("partial QMP record bypassed its deadline")
    finally:
        os.close(write_descriptor)
        stream.close()


def remaining(deadline: float) -> float:
    duration = deadline - time.monotonic()
    if duration <= 0:
        raise AssertionError("frame smoke deadline expired")
    return duration


def assert_no_panic(transcript: bytearray) -> None:
    if b"SWIFTOS:PANIC" in transcript:
        raise AssertionError(transcript.decode("utf-8", errors="replace"))


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
    # These tight regions require glyph pixels, not merely panel backgrounds.
    assert_region(
        pixels,
        width,
        (68, 126, 220, 135),
        (34, 211, 238),
        minimum_fraction=0.05,
    )
    assert_region(
        pixels,
        width,
        (566, 96, 638, 110),
        (248, 250, 252),
        minimum_fraction=0.05,
    )


def validate_wrapped_backspace(path: Path) -> None:
    width, height, pixels = parse_ppm(path)
    if (width, height) != (800, 600):
        raise AssertionError(f"unexpected edit screenshot size {width}x{height}")

    # The 60-byte input wraps after column 69. Six deletes must clear row 5
    # and then the last two cells of row 4. The previous implementation left
    # cyan A glyphs in these two cells even though the command buffer shrank.
    assert_region(
        pixels,
        width,
        (476, 162, 482, 171),
        (8, 14, 26),
        minimum_fraction=1.0,
        tolerance=0,
    )
    assert_region(
        pixels,
        width,
        (471, 163, 474, 164),
        (34, 211, 238),
        minimum_fraction=1.0,
        tolerance=0,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=5.0)
    arguments = parser.parse_args()

    qemu = os.environ.get("QEMU", "qemu-system-aarch64")
    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    assert_deadline_reader_rejects_partial_line()

    with tempfile.TemporaryDirectory(
        prefix="swiftos-frame-",
        dir=str(output.parent),
    ) as temporary:
        edited_output = output.with_name(f"{output.stem}-edited{output.suffix}")
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
            assert process.stderr is not None
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
            read_serial_until(
                process,
                serial_descriptor,
                transcript,
                b"SWIFTOS:READY",
                remaining(deadline),
            )
            assert_no_panic(transcript)
            if b"SWIFTOS:RAMFB_OK" not in transcript:
                raise AssertionError("serial transcript omitted RAMFB_OK")

            execute_qmp(
                qmp,
                process.stdin,
                "stop",
                "stop-base",
                timeout=remaining(deadline),
            )
            execute_qmp(
                qmp,
                process.stdin,
                "screendump",
                "shot-base",
                {
                    "filename": str(output),
                    "device": "ramfb0",
                    "head": 0,
                    "format": "ppm",
                },
                timeout=remaining(deadline),
            )
            validate_screenshot(output)

            execute_qmp(
                qmp,
                process.stdin,
                "cont",
                "edit",
                timeout=remaining(deadline),
            )
            edit_input = (b"a" * 60) + (b"\x7f" * 6)
            edit_echo = (b"a" * 60) + (b"\x08 \x08" * 6)
            write_serial(serial_descriptor, edit_input, remaining(deadline))
            read_serial_until(
                process,
                serial_descriptor,
                transcript,
                edit_echo,
                remaining(deadline),
            )
            execute_qmp(
                qmp,
                process.stdin,
                "stop",
                "stop-edit",
                timeout=remaining(deadline),
            )
            execute_qmp(
                qmp,
                process.stdin,
                "screendump",
                "shot-edit",
                {
                    "filename": str(edited_output),
                    "device": "ramfb0",
                    "head": 0,
                    "format": "ppm",
                },
                timeout=remaining(deadline),
            )
            validate_wrapped_backspace(edited_output)
            print(
                "frame smoke: 800x600 ramfb, glyphs, and wrapped edit pixels passed"
            )
            execute_qmp(
                qmp,
                process.stdin,
                "quit",
                "quit",
                timeout=remaining(deadline),
            )
            process.wait(timeout=2)
        finally:
            if serial_descriptor is not None:
                os.close(serial_descriptor)
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
    except (AssertionError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"frame smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
