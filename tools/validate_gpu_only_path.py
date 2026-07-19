#!/usr/bin/env python3
"""Reject CPU-rasterized color or scanout work in the accelerated crossing."""

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
    compiler_path = (
        path.parents[1]
        / "Drivers"
        / "VirtIO"
        / "VirGLIRCompiler.swift"
    )
    file_manager_runtime_path = (
        path.parents[1]
        / "Drivers"
        / "VirtIO"
        / "QEMUAcceleratedFileManagerRuntime.swift"
    )
    file_manager_scene_path = (
        path.parents[1] / "UI" / "GPUFileManagerSceneCompiler.swift"
    )
    if not session_path.is_file():
        print(
            f"gpu-only path: missing accelerated session {session_path}",
            file=sys.stderr,
        )
        return 1
    if not compiler_path.is_file():
        print(
            f"gpu-only path: missing IR compiler {compiler_path}",
            file=sys.stderr,
        )
        return 1
    if not file_manager_runtime_path.is_file():
        print(
            "gpu-only path: missing accelerated file-manager runtime "
            f"{file_manager_runtime_path}",
            file=sys.stderr,
        )
        return 1
    if not file_manager_scene_path.is_file():
        print(
            "gpu-only path: missing file-manager scene compiler "
            f"{file_manager_scene_path}",
            file=sys.stderr,
        )
        return 1
    session = session_path.read_text(encoding="utf-8")
    compiler = compiler_path.read_text(encoding="utf-8")
    file_manager_runtime = file_manager_runtime_path.read_text(encoding="utf-8")
    file_manager_scene = file_manager_scene_path.read_text(encoding="utf-8")
    try:
        activation = function_source(source, "activateVirtIOGPU3D")
        accelerated = function_source(source, "runQEMUAcceleratedDesktop")
    except ValueError as error:
        print(f"gpu-only path: {error}", file=sys.stderr)
        return 1

    combined = (
        activation
        + accelerated
        + session
        + file_manager_runtime
        + file_manager_scene
    )
    forbidden = (
        "LinearFramebuffer",
        "ScaledFramebufferCanvas",
        "DesktopRenderer",
        "SoftwareRasterizer",
        "SoftwareLayerCompositor",
        "PSF2GlyphRenderer",
        ".drawText(",
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
        "GPUDesktopScene.makeInitialFrame",
        "encodeResourceInlineWrite",
        "b8g8r8a8SRGB",
        "unitQuadResourceID",
        "roundedVertexShaderHandle",
        "roundedFragmentShaderHandle",
        "supportsR8UNormSampler",
        "r8UNorm",
        "samplerViewBind",
        "glyphAtlasResourceID",
        "encodeAndSubmitGlyphAtlas",
        "GPUMaskFontAtlasWriter.writeUpload",
        "VirGLIRGlyphPipeline",
        "GPUBootTextScene.makeFrame",
        "glyphVertexShaderHandle",
        "glyphFragmentShaderHandle",
        "glyphSamplerViewHandle",
        "glyphNearestSamplerHandle",
        "glyphLinearSamplerHandle",
        "mutating func render(",
        "QEMUAcceleratedFileManagerRuntime.activate",
        "QEMUVirtIOInputRuntime.serviceOnce",
        "QEMUAcceleratedFileManagerRuntime.serviceOnce",
        "GPUFileManagerSceneCompiler.compile",
        "session.renderBatch",
        "SynchronousInputEventDispatcher.install",
        "FileManagerDirectoryLoader.load",
    )
    missing = [token for token in required if token not in combined]
    if missing:
        print(
            "gpu-only path: missing accelerated crossing evidence: "
            + ", ".join(missing),
            file=sys.stderr,
        )
        return 1

    compiler_required = (
        "glyphFragmentShaderText",
        "TEX TEMP[0]",
        "MUL OUT[0]",
        "encodeSetSamplerViews",
        "encodeBindSamplerStates",
    )
    missing_compiler = [
        token for token in compiler_required if token not in compiler
    ]
    if missing_compiler:
        print(
            "gpu-only path: missing GPU glyph lowering evidence: "
            + ", ".join(missing_compiler),
            file=sys.stderr,
        )
        return 1

    print(
        "gpu-only path: accelerated boot and file manager have no "
        "CPU-rasterized color or scanout dependencies"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
