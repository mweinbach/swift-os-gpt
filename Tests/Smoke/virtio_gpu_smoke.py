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
    execute_qmp,
    find_serial_pty,
    parse_ppm,
    read_qmp_message,
    read_serial_until,
    remaining,
    validate_screenshot,
    write_serial,
)


def changed_pixel_count(before: Path, after: Path) -> int:
    before_width, before_height, before_pixels = parse_ppm(before)
    after_width, after_height, after_pixels = parse_ppm(after)
    if (before_width, before_height) != (after_width, after_height):
        raise AssertionError("VirtIO-GPU mode changed after monitor input")
    return sum(
        before_pixels[offset:offset + 3] != after_pixels[offset:offset + 3]
        for offset in range(0, len(before_pixels), 3)
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=10.0)
    arguments = parser.parse_args()

    qemu = os.environ.get("QEMU", "qemu-system-aarch64")
    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(
        prefix="swiftos-virtio-gpu-",
        dir=str(output.parent),
    ):
        updated_output = output.with_name(
            f"{output.stem}-updated{output.suffix}"
        )
        command = [
            qemu,
            "-machine", "virt,gic-version=3",
            "-cpu", "cortex-a72",
            "-accel", "tcg",
            "-smp", "1",
            "-m", "512M",
            "-global", "virtio-mmio.force-legacy=false",
            "-device", "virtio-gpu-device,id=gpu0,xres=800,yres=600",
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
            for marker in (
                b"SWIFTOS:VIRTIO_MMIO_OK",
                b"SWIFTOS:VIRTIO_GPU_OK",
                b"SWIFTOS:FRAMEBUFFER_READY",
            ):
                if marker not in transcript:
                    raise AssertionError(f"serial transcript omitted {marker!r}")
            if b"SWIFTOS:RAMFB_OK" in transcript:
                raise AssertionError("VirtIO-GPU smoke silently used ramfb")

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
                    "device": "gpu0",
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
                "monitor-command",
                timeout=remaining(deadline),
            )
            write_serial(serial_descriptor, b"status\r", remaining(deadline))
            read_serial_until(
                process,
                serial_descriptor,
                transcript,
                b"FRAMEBUFFER: 800X600 XRGB8888",
                remaining(deadline),
            )
            read_serial_until(
                process,
                serial_descriptor,
                transcript,
                b"SWIFTOS:DISPLAY_UPDATE_OK",
                remaining(deadline),
            )
            execute_qmp(
                qmp,
                process.stdin,
                "stop",
                "stop-updated",
                timeout=remaining(deadline),
            )
            execute_qmp(
                qmp,
                process.stdin,
                "screendump",
                "shot-updated",
                {
                    "filename": str(updated_output),
                    "device": "gpu0",
                    "head": 0,
                    "format": "ppm",
                },
                timeout=remaining(deadline),
            )
            if changed_pixel_count(output, updated_output) < 100:
                raise AssertionError("monitor updates were not presented by VirtIO-GPU")

            print(
                "VirtIO-GPU smoke: modern MMIO 2D scanout and monitor updates passed"
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
        print(f"VirtIO-GPU smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
