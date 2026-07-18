#!/usr/bin/env python3
"""Fail the build if the accelerated boot crossing gains a CPU pixel path."""

from __future__ import annotations

import pathlib
import sys


def function_source(source: str, name: str) -> str:
    marker = f"private func {name}("
    start = source.find(marker)
    if start < 0:
        raise ValueError(f"missing function {name}")
    opening = source.find("{", start)
    if opening < 0:
        raise ValueError(f"missing body for {name}")

    depth = 0
    for index in range(opening, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise ValueError(f"unterminated body for {name}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_gpu_only_path.py KERNEL_MAIN", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    source = path.read_text(encoding="utf-8")
    session_path = (
        path.parents[1]
        / "Drivers"
        / "VirtIO"
        / "VirtIOGPU3DSession.swift"
    )
    if not session_path.is_file():
        print(
            f"gpu-only path: missing accelerated session {session_path}",
            file=sys.stderr,
        )
        return 1
    session = session_path.read_text(encoding="utf-8")
    try:
        activation = function_source(source, "activateVirtIOGPU3D")
        accelerated = function_source(source, "runQEMUAcceleratedDesktop")
    except ValueError as error:
        print(f"gpu-only path: {error}", file=sys.stderr)
        return 1

    combined = activation + accelerated + session
    forbidden = (
        "LinearFramebuffer",
        "ScaledFramebufferCanvas",
        "DesktopRenderer",
        "SoftwareRasterizer",
        "SoftwareLayerCompositor",
        "ScanoutBuffer",
        "resourceAttachBacking",
        "transferToHost2D",
    )
    violations = [token for token in forbidden if token in combined]
    if violations:
        print(
            "gpu-only path: forbidden CPU pixel dependencies: "
            + ", ".join(violations),
            file=sys.stderr,
        )
        return 1

    required = (
        "allocateClassifiedPages",
        "VirtIOGPU3DBootstrapMemory",
        "VirtIOGPU3DSession",
        "configureAndRenderDesktop",
        "VirtIOGPU3DSession.readyMarker",
        "SWIFTOS:GPU_FRAME_READY",
        "VirGLIRCompiler",
        "encodeResourceInlineWrite",
        "b8g8r8a8SRGB",
        "unitQuadResourceID",
        "mutating func render(",
    )
    missing = [token for token in required if token not in combined]
    if missing:
        print(
            "gpu-only path: missing accelerated crossing evidence: "
            + ", ".join(missing),
            file=sys.stderr,
        )
        return 1

    print("gpu-only path: accelerated boot has no CPU pixel dependencies")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
