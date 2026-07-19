#!/usr/bin/env python3
from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile


REPOSITORY = Path(__file__).resolve().parents[2]
PACKAGER = REPOSITORY / "Boards/RaspberryPi5/package-boot.sh"


def run(*command: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_image(path: Path) -> None:
    image = bytearray(64)
    struct.pack_into("<Q", image, 8, 0x80000)
    struct.pack_into("<Q", image, 24, 2)
    image[56:60] = b"ARM\x64"
    path.write_bytes(image)


def make_firmware_checkout(path: Path) -> tuple[Path, Path, str]:
    dtb = path / "boot/bcm2712-rpi-5-b.dtb"
    overlay = path / "boot/overlays/dwc2.dtbo"
    overlay.parent.mkdir(parents=True)
    dtb.write_bytes(b"\xd0\x0d\xfe\xed" + bytes(60))
    overlay.write_bytes(b"\xd0\x0d\xfe\xed" + b"swiftos-dwc2-fixture")

    commands = [
        ("git", "init", "-q"),
        ("git", "config", "user.name", "SwiftOS package test"),
        ("git", "config", "user.email", "package-test@swiftos.invalid"),
        (
            "git",
            "remote",
            "add",
            "origin",
            "https://github.com/raspberrypi/firmware.git",
        ),
        ("git", "add", "boot/bcm2712-rpi-5-b.dtb", "boot/overlays/dwc2.dtbo"),
        ("git", "commit", "-q", "-m", "Pin firmware fixtures"),
    ]
    for command in commands:
        result = run(*command, cwd=path)
        require(result.returncode == 0, f"fixture command failed: {result.stdout}")
    revision = run("git", "rev-parse", "HEAD", cwd=path).stdout.strip()
    return dtb, overlay, revision


def validate_successful_package(
    output: Path,
    dtb: Path,
    overlay: Path,
    revision: str,
) -> None:
    expected_files = [
        "BOOT-MANIFEST.txt",
        "BUILD-METADATA.txt",
        "SHA256SUMS",
        "bcm2712-rpi-5-b.dtb",
        "config.txt",
        "kernel8.img",
        "overlays/dwc2.dtbo",
    ]
    actual_files = sorted(
        str(path.relative_to(output))
        for path in output.rglob("*")
        if path.is_file()
    )
    require(actual_files == sorted(expected_files), "packaged file set changed")
    require((output / "bcm2712-rpi-5-b.dtb").read_bytes() == dtb.read_bytes(),
            "packaged DTB differs from pinned input")
    require((output / "overlays/dwc2.dtbo").read_bytes() == overlay.read_bytes(),
            "packaged DWC2 overlay differs from pinned input")

    config = (output / "config.txt").read_text()
    require("dtoverlay=dwc2,dr_mode=peripheral\n" in config,
            "config does not force DWC2 peripheral mode")
    manifest = (output / "BOOT-MANIFEST.txt").read_text()
    require("overlays/dwc2.dtbo" in manifest,
            "human-readable manifest omits the DWC2 overlay")

    metadata = dict(
        line.split("=", 1)
        for line in (output / "BUILD-METADATA.txt").read_text().splitlines()
    )
    require(metadata["format"] == "swiftos-rpi5-boot-v2",
            "package format was not advanced")
    require(metadata["firmware_repository_revision"] == revision,
            "firmware revision was not recorded")
    require(metadata["dtb_sha256"] == sha256(dtb), "DTB hash mismatch")
    require(metadata["dwc2_overlay_sha256"] == sha256(overlay),
            "DWC2 overlay hash mismatch")

    checksum_lines = (output / "SHA256SUMS").read_text().splitlines()
    expected_checksum_files = [
        "BOOT-MANIFEST.txt",
        "BUILD-METADATA.txt",
        "bcm2712-rpi-5-b.dtb",
        "config.txt",
        "kernel8.img",
        "overlays/dwc2.dtbo",
    ]
    checksum_files: list[str] = []
    for line in checksum_lines:
        digest, file_name = line.split("  ", 1)
        checksum_files.append(file_name)
        require(digest == sha256(output / file_name),
                f"SHA256SUMS mismatch for {file_name}")
    require(checksum_files == expected_checksum_files,
            "SHA256SUMS file order or membership changed")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="swiftos-rpi5-package-") as temporary:
        root = Path(temporary)
        firmware = root / "firmware"
        firmware.mkdir()
        dtb, overlay, revision = make_firmware_checkout(firmware)
        kernel = root / "kernel8.img"
        write_image(kernel)

        output = root / "package"
        result = run(str(PACKAGER), str(kernel), str(firmware), str(output))
        require(result.returncode == 0, f"valid package failed: {result.stdout}")
        validate_successful_package(output, dtb, overlay, revision)

        overlay.write_bytes(overlay.read_bytes() + b"dirty")
        dirty_output = root / "dirty-package"
        dirty_result = run(
            str(PACKAGER),
            str(kernel),
            str(firmware),
            str(dirty_output),
        )
        require(dirty_result.returncode != 0,
                "packager accepted a modified firmware overlay")
        require("DWC2 overlay differs from the recorded firmware revision"
                in dirty_result.stdout,
                "dirty-overlay failure did not identify its provenance gate")

    print("Raspberry Pi 5 package contract: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
