#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import tty

from frame_smoke import (
    DeadlineLineReader,
    assert_no_panic,
    execute_qmp,
    find_serial_pty,
    parse_ppm,
    read_qmp_message,
    read_serial_until,
    remaining,
    validate_screenshot,
)


INDICATOR_BOUNDS = (774, 11, 786, 23)


def changed_pixels(
    before_path: Path,
    after_path: Path,
) -> tuple[int, int]:
    before_width, before_height, before = parse_ppm(before_path)
    after_width, after_height, after = parse_ppm(after_path)
    if (before_width, before_height) != (after_width, after_height):
        raise AssertionError("animation changed the display mode")

    start_x, start_y, end_x, end_y = INDICATOR_BOUNDS
    inside = 0
    outside = 0
    for y in range(before_height):
        for x in range(before_width):
            offset = (y * before_width + x) * 3
            if before[offset:offset + 3] == after[offset:offset + 3]:
                continue
            if start_x <= x < end_x and start_y <= y < end_y:
                inside += 1
            else:
                outside += 1
    return inside, outside


def screenshot(
    qmp: DeadlineLineReader,
    writer,
    path: Path,
    command_id: str,
    timeout: float,
) -> None:
    execute_qmp(
        qmp,
        writer,
        "screendump",
        command_id,
        {
            "filename": str(path),
            "device": "ramfb0",
            "head": 0,
            "format": "ppm",
        },
        timeout=timeout,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=10.0)
    arguments = parser.parse_args()

    qemu = os.environ.get("QEMU", "qemu-system-aarch64")
    low_output = arguments.output.resolve()
    peak_output = low_output.with_name(
        f"{low_output.stem}-peak{low_output.suffix}"
    )
    low_output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(
        prefix="swiftos-animation-",
        dir=str(low_output.parent),
    ):
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
                b"SWIFTOS:ANIMATION_FRAME_OK",
                remaining(deadline),
            )
            assert_no_panic(transcript)
            for marker in (
                b"SWIFTOS:COMPOSITOR_READY",
                b"SWIFTOS:FRAMEBUFFER_READY",
                b"SWIFTOS:READY",
            ):
                if marker not in transcript:
                    raise AssertionError(f"animation boot omitted {marker!r}")

            execute_qmp(
                qmp,
                process.stdin,
                "stop",
                "stop-low",
                timeout=remaining(deadline),
            )
            screenshot(
                qmp,
                process.stdin,
                low_output,
                "shot-low",
                remaining(deadline),
            )
            validate_screenshot(low_output)

            execute_qmp(
                qmp,
                process.stdin,
                "cont",
                "seek-peak",
                timeout=remaining(deadline),
            )
            read_serial_until(
                process,
                serial_descriptor,
                transcript,
                b"SWIFTOS:ANIMATION_PEAK_OK",
                remaining(deadline),
            )
            assert_no_panic(transcript)
            execute_qmp(
                qmp,
                process.stdin,
                "stop",
                "stop-peak",
                timeout=remaining(deadline),
            )
            screenshot(
                qmp,
                process.stdin,
                peak_output,
                "shot-peak",
                remaining(deadline),
            )
            validate_screenshot(peak_output)

            inside, outside = changed_pixels(low_output, peak_output)
            if inside < 20:
                raise AssertionError(
                    f"animation changed only {inside} indicator pixels"
                )
            if outside != 0:
                raise AssertionError(
                    f"damage presentation changed {outside} pixels outside "
                    "the retained layer"
                )

            print(
                "animation smoke: paced retained layer, alpha, rounded "
                "rasterization, and bounded damage passed"
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
        print(f"animation smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
