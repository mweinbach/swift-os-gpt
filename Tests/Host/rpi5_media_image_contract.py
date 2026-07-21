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
        "160",
        "--slot-size-mib",
        "64",
        "--kernel-log-block-count",
        "64",
    )
    require(result.returncode == 0, f"media build failed: {result.stdout}")


def build_with_block_count(
    package: Path,
    image: Path,
    block_count: int,
) -> None:
    result = run(
        sys.executable,
        str(MEDIA_TOOL),
        "build",
        str(package),
        str(image),
        "--total-block-count",
        str(block_count),
        "--slot-size-mib",
        "64",
        "--kernel-log-block-count",
        "64",
    )
    require(result.returncode == 0,
            f"exact-block media build failed: {result.stdout}")


def inspect(image: Path, should_succeed: bool = True) -> dict[str, object] | str:
    result = run(sys.executable, str(MEDIA_TOOL), "inspect", str(image))
    if should_succeed:
        require(result.returncode == 0, f"media inspection failed: {result.stdout}")
        return json.loads(result.stdout)
    require(result.returncode != 0, "corrupt media passed inspection")
    return result.stdout


def read_mbr(
    image: Path,
) -> tuple[
    bytes,
    tuple[int, int],
    tuple[int, int],
    tuple[int, int],
    tuple[int, int],
]:
    with image.open("rb") as source:
        mbr = source.read(512)
    require(mbr[510:512] == b"\x55\xaa", "MBR signature changed")
    require(mbr[446] == 0x80 and mbr[450] == 0x01,
            "FAT12 selector type or boot flag changed")
    require(mbr[462] == 0 and mbr[466] == 0x0C,
            "slot A partition type or boot flag changed")
    require(mbr[478] == 0 and mbr[482] == 0x0C,
            "slot B partition type or boot flag changed")
    require(mbr[494] == 0 and mbr[498] == 0xDA,
            "SwiftOS data partition type changed")
    selector = struct.unpack_from("<II", mbr, 454)
    slot_a = struct.unpack_from("<II", mbr, 470)
    slot_b = struct.unpack_from("<II", mbr, 486)
    data = struct.unpack_from("<II", mbr, 502)
    return mbr, selector, slot_a, slot_b, data


def fat32_entry_cluster(entry: bytes) -> int:
    return (struct.unpack_from("<H", entry, 20)[0] << 16) | struct.unpack_from(
        "<H", entry, 26
    )[0]


def require_root_child_parent_sentinel(
    image: Path,
    boot: tuple[int, int],
    child_short_name: bytes,
) -> None:
    """Require FAT32's zero `..` sentinel for a root-owned directory."""

    with image.open("rb") as source:
        boot_offset = boot[0] * 512
        source.seek(boot_offset)
        bpb = source.read(512)
        require(len(bpb) == 512, "FAT32 boot sector is truncated")
        sectors_per_cluster = bpb[13]
        reserved = struct.unpack_from("<H", bpb, 14)[0]
        fat_count = bpb[16]
        fat_sectors = struct.unpack_from("<I", bpb, 36)[0]
        root_cluster = struct.unpack_from("<I", bpb, 44)[0]
        data_start = boot[0] + reserved + fat_count * fat_sectors
        fat_start = (boot[0] + reserved) * 512

        def cluster_bytes(cluster: int) -> bytes:
            sector = data_start + (cluster - 2) * sectors_per_cluster
            source.seek(sector * 512)
            return source.read(sectors_per_cluster * 512)

        def directory_chain(first_cluster: int) -> bytes:
            output = bytearray()
            visited: set[int] = set()
            cluster = first_cluster
            while cluster < 0x0FFF_FFF8:
                require(cluster >= 2 and cluster not in visited,
                        "directory FAT chain is invalid")
                visited.add(cluster)
                output += cluster_bytes(cluster)
                source.seek(fat_start + cluster * 4)
                encoded = source.read(4)
                require(len(encoded) == 4, "directory FAT entry is truncated")
                cluster = struct.unpack("<I", encoded)[0] & 0x0FFF_FFFF
            return bytes(output)

        root = directory_chain(root_cluster)
        child_cluster: int | None = None
        for offset in range(0, len(root), 32):
            entry = root[offset:offset + 32]
            if len(entry) != 32 or entry[0] == 0:
                break
            if entry[0] == 0xE5 or entry[11] == 0x0F:
                continue
            if entry[:11] == child_short_name and entry[11] & 0x10:
                child_cluster = fat32_entry_cluster(entry)
                break
        require(child_cluster is not None, "root child directory is missing")

        child = directory_chain(child_cluster)
        dot = child[:32]
        dotdot = child[32:64]
        require(dot[:11] == b".          ", "child '.' entry is malformed")
        require(dotdot[:11] == b"..         ", "child '..' entry is malformed")
        require(fat32_entry_cluster(dot) == child_cluster,
                "child '.' entry does not reference itself")
        require(fat32_entry_cluster(dotdot) == 0,
                "root-owned child '..' must use FAT32 cluster-zero sentinel")


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
        exact = root / "exact-block-count.img"
        default = root / "default-layout.img"
        build(package, first)
        build(package, second)
        exact_block_count = 327_681
        build_with_block_count(package, exact, exact_block_count)
        default_result = run(
            sys.executable,
            str(MEDIA_TOOL),
            "build",
            str(package),
            str(default),
            "--total-size-mib",
            "300",
            "--kernel-log-block-count",
            "64",
        )
        require(default_result.returncode == 0,
                f"default-layout build failed: {default_result.stdout}")

        require(first.stat().st_size == 160 * 1_024 * 1_024,
                "media logical size changed")
        require(first.stat().st_blocks * 512 < first.stat().st_size // 2,
                "media image is not sparse")
        require(digest(first) == digest(second),
                "identical media builds are not byte-deterministic")

        require(exact.stat().st_size == exact_block_count * 512,
                "explicit block-count image size changed")
        _, exact_selector, exact_a, exact_b, exact_data = read_mbr(exact)
        require(exact_selector == (1, 2_047),
                "explicit block-count selector extent changed")
        require(exact_a == (2_048, 131_072),
                "explicit block-count slot A extent changed")
        require(exact_b == (133_120, 131_072),
                "explicit block-count slot B extent changed")
        require(exact_data[0] + exact_data[1] == exact_block_count,
                "data partition does not end at exact media geometry")
        exact_report = inspect(exact)
        require(exact_report["logical_block_count"] == exact_block_count,
                "inspector lost the explicit media geometry")

        _, selector, slot_a, slot_b, data = read_mbr(first)
        require(selector == (1, 2_047), "selector LBA extent changed")
        require(slot_a == (2_048, 131_072), "slot A LBA extent changed")
        require(slot_b == (133_120, 131_072), "slot B LBA extent changed")
        require(data == (264_192, 63_488), "data partition LBA extent changed")
        require_root_child_parent_sentinel(first, slot_a, b"OVERLAYS   ")
        require_root_child_parent_sentinel(first, slot_b, b"OVERLAYS   ")

        _, default_selector, default_a, default_b, default_data = read_mbr(
            default
        )
        require(default_selector == (1, 2_047),
                "default selector no longer occupies the alignment gap")
        require(default_a == (2_048, 262_144),
                "default slot A is not 128 MiB")
        require(default_b == (264_192, 262_144),
                "default slot B is not 128 MiB")
        require(default_data[0] == 526_336,
                "default A/B layout moved the existing data start")

        # The selector is tiny by design, but it is still authoritative. A
        # disagreement between its two FAT copies must fail closed rather than
        # letting inspection bless media whose next-boot policy is ambiguous.
        with default.open("r+b") as target:
            target.seek((default_selector[0] + 1) * 512 + 4)
            encoded = target.read(1)
            require(len(encoded) == 1, "selector FAT fixture is truncated")
            target.seek((default_selector[0] + 1) * 512 + 4)
            target.write(bytes([encoded[0] ^ 0x80]))
        selector_error = inspect(default, should_succeed=False)
        require("selector FAT12 allocation tables are invalid" in selector_error,
                "corrupt selector FAT copies were not rejected")

        report = inspect(first)
        require(report["format"] == "swiftos-rpi5-media-v2",
                "media format did not advance")
        require(report["selector"]["default_slot"] == "A",
                "fresh selector does not default to A")
        require(report["selector"]["try_slot"] == "B",
                "fresh selector does not trial B")
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
        require(
            report["boot_slots"]["A"]["files"]
                == report["boot_slots"]["B"]["files"],
            "fresh A/B slots do not contain the same release",
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

        dangling = root / "dangling.img"
        dangling.symlink_to(root / "missing-target.img")
        dangling_result = run(
            sys.executable,
            str(MEDIA_TOOL),
            "build",
            str(package),
            str(dangling),
        )
        require(dangling_result.returncode != 0,
                "builder accepted a dangling output symlink")
        require(dangling.is_symlink(), "builder removed a rejected output symlink")

        # Kernel-slot packages and EEPROM updates use independent rollback
        # domains. Never let an ordinary package smuggle a Pi recovery image
        # into either boot slot.
        forbidden = package / "recovery.bin"
        forbidden.write_bytes(b"not-an-eeprom-image")
        forbidden_output = root / "forbidden-eeprom.img"
        forbidden_result = run(
            sys.executable,
            str(MEDIA_TOOL),
            "build",
            str(package),
            str(forbidden_output),
            "--total-size-mib",
            "160",
            "--slot-size-mib",
            "64",
        )
        require(forbidden_result.returncode != 0,
                "builder accepted an EEPROM updater in a slot package")
        require("forbidden EEPROM updater: recovery.bin" in forbidden_result.stdout,
                "EEPROM rejection did not name the forbidden file")
        require(not forbidden_output.exists(),
                "failed forbidden-package build left an output image")
        forbidden.unlink()

        # A self-looping root chain is bounded and rejected.
        _, _, slot_a, _, _ = read_mbr(second)
        with second.open("r+b") as target:
            boot_offset = slot_a[0] * 512
            target.seek(boot_offset)
            bpb = target.read(512)
            reserved = struct.unpack_from("<H", bpb, 14)[0]
            fat_offset = (slot_a[0] + reserved) * 512
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
