#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib


REPOSITORY = Path(__file__).resolve().parents[2]
PACKAGER = REPOSITORY / "Boards/RaspberryPi5/package-boot.sh"
MEDIA_TOOL = REPOSITORY / "tools/build_rpi5_media.py"
sys.path.insert(0, str(Path(__file__).parent))
from rpi5_package_contract import make_firmware_checkout, write_image  # noqa: E402


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


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1_024 * 1_024):
            value.update(chunk)
    return value.hexdigest()


def package_fixture(root: Path) -> Path:
    firmware = root / "firmware"
    firmware.mkdir()
    make_firmware_checkout(firmware)
    kernel = root / "kernel8.img"
    write_image(kernel)
    package = root / "package"
    result = run(str(PACKAGER), str(kernel), str(firmware), str(package))
    require(result.returncode == 0, f"package fixture failed: {result.stdout}")
    return package


def build(package: Path, image: Path) -> None:
    result = run(
        sys.executable,
        str(MEDIA_TOOL),
        "build",
        str(package),
        str(image),
        "--total-size-mib",
        "96",
        "--boot-size-mib",
        "64",
        "--kernel-log-block-count",
        "64",
    )
    require(result.returncode == 0, f"media build failed: {result.stdout}")


def inspect(image: Path, should_succeed: bool = True) -> dict[str, object] | str:
    result = run(sys.executable, str(MEDIA_TOOL), "inspect", str(image))
    if should_succeed:
        require(result.returncode == 0, f"media inspection failed: {result.stdout}")
        return json.loads(result.stdout)
    require(result.returncode != 0, "corrupt media passed inspection")
    return result.stdout


def read_mbr(image: Path) -> tuple[bytes, tuple[int, int], tuple[int, int]]:
    with image.open("rb") as source:
        mbr = source.read(512)
    require(mbr[510:512] == b"\x55\xaa", "MBR signature changed")
    require(mbr[446] == 0x80 and mbr[450] == 0x0C,
            "FAT32 partition type or boot flag changed")
    require(mbr[462] == 0 and mbr[466] == 0xDA,
            "SwiftOS data partition type changed")
    boot = struct.unpack_from("<II", mbr, 454)
    data = struct.unpack_from("<II", mbr, 470)
    return mbr, boot, data


def valid_record(sequence: int, timestamp: int, payload: bytes) -> bytes:
    block = bytearray(512)
    block[:8] = b"SWLOG001"
    struct.pack_into("<HHIQQ", block, 8, 1, 40, len(payload), sequence, timestamp)
    struct.pack_into("<I", block, 32, zlib.crc32(payload) & 0xFFFF_FFFF)
    struct.pack_into("<I", block, 36, zlib.crc32(block[:36]) & 0xFFFF_FFFF)
    block[40:40 + len(payload)] = payload
    return bytes(block)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="swiftos-rpi5-media-") as temporary:
        root = Path(temporary)
        package = package_fixture(root)
        first = root / "first.img"
        second = root / "second.img"
        build(package, first)
        build(package, second)

        require(first.stat().st_size == 96 * 1_024 * 1_024,
                "media logical size changed")
        require(first.stat().st_blocks * 512 < first.stat().st_size // 2,
                "media image is not sparse")
        require(digest(first) == digest(second),
                "identical media builds are not byte-deterministic")

        _, boot, data = read_mbr(first)
        require(boot == (2_048, 131_072), "boot partition LBA extent changed")
        require(data == (133_120, 63_488), "data partition LBA extent changed")

        report = inspect(first)
        boot_files = report["boot_files"]
        expected_files = sorted(
            str(path.relative_to(package))
            for path in package.rglob("*")
            if path.is_file()
        )
        require(sorted(boot_files) == expected_files,
                "FAT32 file membership differs from the package")
        for relative in expected_files:
            require(
                boot_files[relative]["sha256"]
                == hashlib.sha256((package / relative).read_bytes()).hexdigest(),
                f"FAT32 file content changed: {relative}",
            )
        require(report["data_superblock_status"] == "healthy",
                "fresh superblocks are not healthy")
        layout = report["data_volume"]
        require(layout["kernel_log_start_block"] == 2, "log arena start")
        require(layout["kernel_log_block_count"] == 64, "log arena count")
        require(layout["user_data_start_block"] == 66, "user arena start")

        data_offset = data[0] * 512
        with first.open("r+b") as target:
            target.seek(data_offset)
            primary = target.read(512)
            backup = target.read(512)
            require(primary == backup, "fresh data superblocks differ")
            require(primary[:8] == b"SWOSDATA", "data magic changed")
            require(
                struct.unpack_from("<I", primary, 60)[0]
                == zlib.crc32(primary[:60]) & 0xFFFF_FFFF,
                "data superblock CRC changed",
            )

            # Kernel recovery accepts one valid duplicate and reports degraded.
            target.seek(data_offset)
            target.write(b"X")
        degraded = inspect(first)
        require(degraded["data_superblock_status"] == "degraded-backup-only",
                "single-superblock recovery was not reported")

        # Two independently valid but conflicting layouts must be rejected.
        conflicting = bytearray(primary)
        struct.pack_into("<Q", conflicting, 32, 63)
        struct.pack_into("<Q", conflicting, 40, 65)
        struct.pack_into("<Q", conflicting, 48, data[1] - 65)
        struct.pack_into("<I", conflicting, 60,
                         zlib.crc32(conflicting[:60]) & 0xFFFF_FFFF)
        with first.open("r+b") as target:
            target.seek(data_offset)
            target.write(conflicting)
        error = inspect(first, should_succeed=False)
        require("superblocks disagree" in error,
                "conflicting-superblock failure was not specific")

        # Restore the primary and prove the read-only inspector extracts one
        # CRC-protected structured-kernel-log payload.
        payload = bytearray(48)
        struct.pack_into("<Q", payload, 0, 77)
        struct.pack_into("<Q", payload, 8, 1234)
        payload[16] = 5
        struct.pack_into("<H", payload, 18, 6)
        struct.pack_into("<I", payload, 20, 0x1122_3344)
        with first.open("r+b") as target:
            target.seek(data_offset)
            target.write(primary)
            target.seek(data_offset + 2 * 512)
            target.write(valid_record(1, 5678, bytes(payload)))
        records = inspect(first)["persistent_records"]
        require(len(records) == 1, "persistent record was not extracted")
        require(records[0]["sequence"] == 1, "persistent sequence changed")
        require(records[0]["kernel_log_sequence"] == 77,
                "kernel ring sequence was not decoded")
        require(records[0]["kernel_log_event_code"] == 0x1122_3344,
                "kernel event code was not decoded")

        overwrite = run(
            sys.executable,
            str(MEDIA_TOOL),
            "build",
            str(package),
            str(first),
        )
        require(overwrite.returncode != 0, "builder overwrote an existing image")

        # A self-looping root chain is bounded and rejected.
        _, boot, _ = read_mbr(second)
        with second.open("r+b") as target:
            boot_offset = boot[0] * 512
            target.seek(boot_offset)
            bpb = target.read(512)
            reserved = struct.unpack_from("<H", bpb, 14)[0]
            fat_offset = (boot[0] + reserved) * 512
            target.seek(fat_offset + 2 * 4)
            target.write(struct.pack("<I", 2))
        loop_error = inspect(second, should_succeed=False)
        require("chain loops" in loop_error,
                "malformed FAT chain was not bounded")

        truncated = root / "truncated.img"
        with first.open("rb") as source, truncated.open("wb") as destination:
            destination.write(source.read(512))
            destination.truncate(4_096)
        truncated_error = inspect(truncated, should_succeed=False)
        require("invalid MBR partition" in truncated_error,
                "truncated image extent was not rejected")

    print("Raspberry Pi 5 media image contract: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
