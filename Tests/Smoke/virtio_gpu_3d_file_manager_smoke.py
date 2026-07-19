#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import tty
from typing import Any

from frame_smoke import (
    DeadlineLineReader,
    execute_qmp,
    find_serial_pty,
    parse_ppm,
    read_qmp_message,
    read_serial_until,
    remaining,
)


CAPABILITY_UNAVAILABLE = 77


def command_output(command: list[str]) -> str:
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return result.stdout


def select_gl_display(qemu: str, requested: str | None) -> str | None:
    if requested:
        return requested
    available = command_output([qemu, "-display", "help"])
    for backend in ("egl-headless", "gtk", "sdl"):
        if backend in available:
            return f"{backend},gl=on"
    return None


def input_event(event_type: str, data: dict[str, Any]) -> dict[str, Any]:
    return {"type": event_type, "data": data}


def changed_pixel_count(before: Path, after: Path) -> int:
    before_width, before_height, before_pixels = parse_ppm(before)
    after_width, after_height, after_pixels = parse_ppm(after)
    if (before_width, before_height) != (after_width, after_height):
        raise AssertionError("accelerated display mode changed after input")
    changed = 0
    for offset in range(0, len(before_pixels), 3):
        if before_pixels[offset:offset + 3] != after_pixels[offset:offset + 3]:
            changed += 1
    return changed


def validate_accelerated_frame(path: Path) -> None:
    width, height, pixels = parse_ppm(path)
    if (width, height) != (800, 600):
        raise AssertionError(f"unexpected accelerated mode {width}x{height}")
    sampled_colors = {
        pixels[offset:offset + 3]
        for offset in range(0, len(pixels), 3 * 97)
    }
    if len(sampled_colors) < 4:
        raise AssertionError("accelerated screenshot is blank or nearly uniform")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Require a live VirGL file-manager frame, mounted SwiftFS, and "
            "an input-driven GPU redraw"
        )
    )
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--display",
        default=os.environ.get("QEMU_GL_DISPLAY"),
        help="QEMU GL display backend, for example egl-headless,gl=on",
    )
    arguments = parser.parse_args()

    qemu = os.environ.get("QEMU", "qemu-system-aarch64")
    device_help = command_output([qemu, "-device", "help"])
    if 'name "virtio-gpu-gl-device"' not in device_help:
        print(
            "VirtIO GPU 3D acceptance unavailable: QEMU has no "
            "virtio-gpu-gl-device",
            file=sys.stderr,
        )
        return CAPABILITY_UNAVAILABLE
    display = select_gl_display(qemu, arguments.display)
    if display is None:
        print(
            "VirtIO GPU 3D acceptance unavailable: QEMU has no supported "
            "GL display backend; set QEMU_GL_DISPLAY explicitly",
            file=sys.stderr,
        )
        return CAPABILITY_UNAVAILABLE

    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    updated_output = output.with_name(
        f"{output.stem}-input{output.suffix}"
    )

    with tempfile.TemporaryDirectory(
        prefix="swiftos-virtio-gpu-3d-",
        dir=str(output.parent),
    ) as directory:
        disk = Path(directory) / "users.raw"
        with disk.open("wb") as image:
            image.truncate(512 * 512)

        command = [
            qemu,
            "-machine", "virt,gic-version=3",
            "-cpu", "cortex-a72",
            "-accel", "tcg",
            "-smp", "1",
            "-m", "512M",
            "-global", "virtio-mmio.force-legacy=false",
            "-drive", f"if=none,format=raw,file={disk},id=users0",
            "-device", "virtio-blk-device,drive=users0,id=usersblk0",
            "-device", "virtio-keyboard-device,id=keyboard0",
            "-device", "virtio-mouse-device,id=mouse0",
            "-device", "virtio-gpu-gl-device,id=gpu0,xres=800,yres=600",
            "-display", display,
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
                b"SWIFTOS:SWIFTFS_READY",
                b"SWIFTOS:VIRTIO_INPUT_READY",
                b"SWIFTOS:VIRTIO_GPU_3D_OK",
                b"SWIFTOS:QEMU_FILE_MANAGER_READY",
                b"SWIFTOS:QEMU_FILE_MANAGER_SWIFTFS",
                b"SWIFTOS:QEMU_FILE_MANAGER_FRAME",
                b"SWIFTOS:QEMU_FILE_MANAGER_STEADY",
            ):
                read_serial_until(
                    process,
                    serial_descriptor,
                    transcript,
                    marker,
                    remaining(deadline),
                )

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
            validate_accelerated_frame(output)

            execute_qmp(
                qmp,
                process.stdin,
                "cont",
                "input",
                timeout=remaining(deadline),
            )
            execute_qmp(
                qmp,
                process.stdin,
                "input-send-event",
                "pointer-motion",
                {"events": [
                    input_event("rel", {"axis": "x", "value": 37}),
                    input_event("rel", {"axis": "y", "value": -19}),
                ]},
                timeout=remaining(deadline),
            )
            read_serial_until(
                process,
                serial_descriptor,
                transcript,
                b"SWIFTOS:VIRTIO_INPUT_POINTER_DX_37_DY_NEG19",
                remaining(deadline),
            )
            read_serial_until(
                process,
                serial_descriptor,
                transcript,
                b"SWIFTOS:QEMU_FILE_MANAGER_INTERACTION_FRAME",
                remaining(deadline),
            )
            execute_qmp(
                qmp,
                process.stdin,
                "stop",
                "stop-input",
                timeout=remaining(deadline),
            )
            execute_qmp(
                qmp,
                process.stdin,
                "screendump",
                "shot-input",
                {
                    "filename": str(updated_output),
                    "device": "gpu0",
                    "head": 0,
                    "format": "ppm",
                },
                timeout=remaining(deadline),
            )
            if changed_pixel_count(output, updated_output) < 16:
                raise AssertionError("input did not visibly change the GPU frame")

            print(
                "VirtIO GPU 3D acceptance: mounted SwiftFS file manager, "
                "VirGL frame, and input-driven redraw passed"
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
                process.send_signal(signal.SIGINT)
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
        print(f"VirtIO GPU 3D acceptance failed: {error}", file=sys.stderr)
        raise SystemExit(1)
