#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib


REPOSITORY = Path(__file__).resolve().parents[2]
PACKAGER = REPOSITORY / "Boards/RaspberryPi5/package-boot.sh"
MEDIA_TOOL = REPOSITORY / "tools/build_rpi5_media.py"
SELECTOR_AUTOBOOT_A = b"""[all]
tryboot_a_b=1
boot_partition=2
[tryboot]
boot_partition=3
"""
SELECTOR_AUTOBOOT_B = b"""[all]
tryboot_a_b=1
boot_partition=3
[tryboot]
boot_partition=2
"""
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


def extent_digest(path: Path, start_block: int, block_count: int) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        source.seek(start_block * 512)
        remaining = block_count * 512
        while remaining:
            chunk = source.read(min(remaining, 1_024 * 1_024))
            require(bool(chunk), "slot digest extent is truncated")
            value.update(chunk)
            remaining -= len(chunk)
    return value.hexdigest()


def content_digest(path: Path, start_block: int, block_count: int) -> str:
    """Hash a slot with its validated FAT32 location fields normalized."""

    value = hashlib.sha256()
    with path.open("rb") as source:
        source.seek(start_block * 512)
        remaining = block_count * 512
        relative_offset = 0
        while remaining:
            chunk = bytearray(source.read(min(remaining, 1_024 * 1_024)))
            require(bool(chunk), "slot content extent is truncated")
            chunk_end = relative_offset + len(chunk)
            for boot_sector in (0, 6):
                field_offset = boot_sector * 512 + 28
                if relative_offset <= field_offset < chunk_end:
                    local = field_offset - relative_offset
                    require(
                        struct.unpack_from("<I", chunk, local)[0]
                            == start_block,
                        "slot BPB_HiddSec does not name its partition",
                    )
                    chunk[local:local + 4] = bytes(4)
            value.update(chunk)
            relative_offset = chunk_end
            remaining -= len(chunk)
    return value.hexdigest()


def relocate_slot_hidden_sectors(
    path: Path,
    start_block: int,
) -> None:
    with path.open("r+b") as target:
        for boot_sector in (0, 6):
            target.seek((start_block + boot_sector) * 512 + 28)
            target.write(struct.pack("<I", start_block))


def legacy_fat12_entry(
    short_name: bytes,
    first_cluster: int,
    byte_count: int,
) -> bytes:
    entry = bytearray(32)
    entry[0:11] = short_name
    entry[11] = 0x20
    for offset in (16, 18, 24):
        struct.pack_into("<H", entry, offset, 0x0021)
    struct.pack_into("<H", entry, 26, first_cluster)
    struct.pack_into("<I", entry, 28, byte_count)
    return bytes(entry)


def set_legacy_fat12_value(
    fat: bytearray,
    cluster: int,
    value: int,
) -> None:
    offset = cluster + cluster // 2
    if cluster & 1:
        fat[offset] = (fat[offset] & 0x0F) | ((value << 4) & 0xF0)
        fat[offset + 1] = (value >> 4) & 0xFF
    else:
        fat[offset] = value & 0xFF
        fat[offset + 1] = (
            fat[offset + 1] & 0xF0
        ) | ((value >> 8) & 0x0F)


def install_revision_two_selector(
    image: Path,
    selector: tuple[int, int],
    package: Path,
) -> None:
    start, count = selector
    files = (
        (b"AUTOBOOTTXT", SELECTOR_AUTOBOOT_A),
        (b"CONFIG  TXT", (package / "RESCUE-CONFIG.txt").read_bytes()),
        (b"KERNEL8 IMG", (package / "kernel8.img").read_bytes()),
        (b"RESCUE  DTB", (package / "bcm2712-rpi-5-b.dtb").read_bytes()),
    )
    allocations: list[tuple[bytes, bytes, tuple[int, ...]]] = []
    next_cluster = 2
    for short_name, contents in files:
        cluster_count = max(1, (len(contents) + 511) // 512)
        clusters = tuple(range(next_cluster, next_cluster + cluster_count))
        allocations.append((short_name, contents, clusters))
        next_cluster += cluster_count
    require(next_cluster - 2 <= count - 15,
            "revision-two rescue fixture does not fit")

    manifest = bytearray(128)
    manifest[0:8] = b"SWRSQ001"
    struct.pack_into("<HHHH", manifest, 8, 1, 128, 3, 0)
    for index, (_, contents, _) in enumerate(allocations[1:]):
        struct.pack_into("<I", manifest, 16 + index * 4, len(contents))
        manifest[28 + index * 32:60 + index * 32] = hashlib.sha256(
            contents
        ).digest()
    struct.pack_into(
        "<I",
        manifest,
        124,
        zlib.crc32(manifest[:124]) & 0xFFFF_FFFF,
    )

    boot = bytearray(512)
    boot[0:3] = b"\xeb\x3c\x90"
    boot[3:11] = b"SWIFTOS "
    struct.pack_into("<H", boot, 11, 512)
    boot[13] = 1
    struct.pack_into("<H", boot, 14, 1)
    boot[16] = 2
    struct.pack_into("<H", boot, 17, 32)
    struct.pack_into("<H", boot, 19, count)
    boot[21] = 0xF8
    struct.pack_into("<H", boot, 22, 6)
    struct.pack_into("<H", boot, 24, 63)
    struct.pack_into("<H", boot, 26, 255)
    struct.pack_into("<I", boot, 28, start)
    boot[36] = 0x80
    boot[38] = 0x29
    struct.pack_into("<I", boot, 39, 0x4354_4C31)
    boot[43:54] = b"SWIFTOS-CTL"
    boot[54:62] = b"FAT12   "
    boot[64:192] = manifest
    boot[510:512] = b"\x55\xaa"

    fat = bytearray(6 * 512)
    set_legacy_fat12_value(fat, 0, 0xFF8)
    set_legacy_fat12_value(fat, 1, 0xFFF)
    for _, _, clusters in allocations:
        for index, cluster in enumerate(clusters):
            value = clusters[index + 1] if index + 1 < len(clusters) else 0xFFF
            set_legacy_fat12_value(fat, cluster, value)

    root = bytearray(2 * 512)
    for index, (short_name, contents, clusters) in enumerate(allocations):
        root[index * 32:(index + 1) * 32] = legacy_fat12_entry(
            short_name,
            clusters[0],
            len(contents),
        )

    with image.open("r+b") as target:
        target.seek(start * 512)
        target.write(bytes(count * 512))
        target.seek(start * 512)
        target.write(boot)
        target.write(fat)
        target.write(fat)
        target.write(root)
        data_start = start + 15
        for _, contents, clusters in allocations:
            for index, cluster in enumerate(clusters):
                chunk = contents[index * 512:(index + 1) * 512]
                target.seek((data_start + cluster - 2) * 512)
                target.write(chunk.ljust(512, b"\0"))


def convert_to_revision_two(
    source: Path,
    destination: Path,
    package: Path,
    selector: tuple[int, int],
    slot_a: tuple[int, int],
    slot_b: tuple[int, int],
    data: tuple[int, int],
) -> str:
    shutil.copyfile(source, destination)
    install_revision_two_selector(destination, selector, package)
    with destination.open("r+b") as target:
        for slot_start, _ in (slot_a, slot_b):
            for relative_block in (0, 6):
                target.seek((slot_start + relative_block) * 512 + 28)
                target.write(bytes(4))
    raw_digest = extent_digest(destination, *slot_a)
    require(
        extent_digest(destination, *slot_b) == raw_digest,
        "revision-two raw slots did not converge",
    )
    with destination.open("r+b") as target:
        for replica in (0, 1):
            offset = (data[0] + replica) * 512 + 64
            target.seek(offset)
            record = bytearray(target.read(160))
            require(len(record) == 160,
                    "revision-two boot-control fixture is truncated")
            record[72:104] = bytes.fromhex(raw_digest)
            struct.pack_into("<Q", record, 136, 0x5357_4142_0000_0002)
            struct.pack_into(
                "<I",
                record,
                156,
                zlib.crc32(record[:156]) & 0xFFFF_FFFF,
            )
            target.seek(offset)
            target.write(record)
    return raw_digest


def package_fixture(root: Path, *, mutate_kernel: bool = False) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    firmware = root / "firmware"
    firmware.mkdir()
    make_firmware_checkout(firmware)
    kernel = root / "kernel8.img"
    write_image(kernel)
    if mutate_kernel:
        contents = bytearray(kernel.read_bytes())
        require(bool(contents), "alternate kernel fixture is empty")
        contents[-1] ^= 0x01
        kernel.write_bytes(contents)
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


def require_selector_rescue_layout(
    image: Path,
    selector: tuple[int, int],
    package: Path,
) -> dict[str, int]:
    sources = {
        "config.txt": package / "RESCUE-CONFIG.txt",
        "kernel8.img": package / "kernel8.img",
        "bcm2712-rpi-5-b.dtb": package / "bcm2712-rpi-5-b.dtb",
        "overlays/dwc2.dtbo": package / "overlays/dwc2.dtbo",
    }
    expected_root = [
        ("autoboot.txt", b"AUTOBOOTTXT", None),
        ("config.txt", b"CONFIG  TXT", sources["config.txt"]),
        ("kernel8.img", b"KERNEL8 IMG", sources["kernel8.img"]),
        (
            "bcm2712-rpi-5-b.dtb",
            b"BCM271~1DTB",
            sources["bcm2712-rpi-5-b.dtb"],
        ),
    ]

    def lfn_checksum(short_name: bytes) -> int:
        value = 0
        for byte in short_name:
            value = (((value & 1) << 7) | (value >> 1)) + byte
            value &= 0xFF
        return value

    def consume_lfn(
        directory: bytes,
        offset: int,
        name: str,
        short_name: bytes,
    ) -> int:
        entries: list[bytes] = []
        while directory[offset + 11] == 0x0F:
            entries.append(directory[offset:offset + 32])
            offset += 32
        require(bool(entries), f"selector lacks a VFAT name for {name}")
        expected_count = (len(name) + 1 + 12) // 13
        require(len(entries) == expected_count,
                f"selector VFAT entry count changed: {name}")
        chunks: dict[int, list[int]] = {}
        positions = (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)
        for disk_index, entry in enumerate(entries):
            ordinal = entry[0] & 0x1F
            require(ordinal == expected_count - disk_index,
                    f"selector VFAT order changed: {name}")
            require(bool(entry[0] & 0x40) == (disk_index == 0),
                    f"selector VFAT terminator changed: {name}")
            require(entry[11] == 0x0F and entry[12] == 0
                    and entry[13] == lfn_checksum(short_name)
                    and entry[26:28] == b"\0\0",
                    f"selector VFAT metadata changed: {name}")
            chunks[ordinal] = [
                struct.unpack_from("<H", entry, position)[0]
                for position in positions
            ]
        units = [
            unit
            for ordinal in range(1, expected_count + 1)
            for unit in chunks[ordinal]
        ]
        terminator = units.index(0)
        require(all(unit == 0xFFFF for unit in units[terminator + 1:]),
                f"selector VFAT padding changed: {name}")
        decoded = b"".join(
            struct.pack("<H", unit) for unit in units[:terminator]
        ).decode("utf-16le")
        require(decoded == name, f"selector VFAT name changed: {name}")
        return offset

    clusters: dict[str, int] = {}
    with image.open("rb") as source:
        root_block = selector[0] + 1 + 2 * 6
        source.seek(root_block * 512)
        root = source.read(2 * 512)
        require(len(root) == 1_024, "selector root directory is truncated")
        next_cluster = 2
        offset = 0
        for name, short_name, path in expected_root:
            offset = consume_lfn(root, offset, name, short_name)
            entry = root[offset:offset + 32]
            require(entry[:11] == short_name,
                    f"selector short name changed: {name}")
            require(entry[11] == 0x20,
                    f"selector attributes changed: {name}")
            first_cluster = struct.unpack_from("<H", entry, 26)[0]
            byte_count = struct.unpack_from("<I", entry, 28)[0]
            require(first_cluster == next_cluster,
                    f"selector allocation is not sequential: {name}")
            clusters[name] = first_cluster
            cluster_count = max(1, (byte_count + 511) // 512)
            if path is not None:
                contents = path.read_bytes()
                require(byte_count == len(contents),
                        f"selector rescue size changed: {name}")
                data_block = selector[0] + 15 + first_cluster - 2
                source.seek(data_block * 512)
                encoded = source.read(cluster_count * 512)
                require(encoded[:byte_count] == contents,
                        f"selector rescue content changed: {name}")
                require(not any(encoded[byte_count:]),
                        f"selector rescue padding is not zero: {name}")
            next_cluster += cluster_count
            offset += 32

        offset = consume_lfn(root, offset, "overlays", b"OVERLAYS   ")
        overlay_directory = root[offset:offset + 32]
        require(overlay_directory[:11] == b"OVERLAYS   "
                and overlay_directory[11] == 0x10
                and struct.unpack_from("<H", overlay_directory, 26)[0]
                    == next_cluster
                and struct.unpack_from("<I", overlay_directory, 28)[0] == 0,
                "selector overlay directory entry is invalid")
        clusters["overlays"] = next_cluster
        next_cluster += 1
        offset += 32
        require(not any(root[offset:]),
                "selector root has an unexpected entry")

        overlay_path = sources["overlays/dwc2.dtbo"]
        overlay_contents = overlay_path.read_bytes()
        overlay_clusters = max(1, (len(overlay_contents) + 511) // 512)
        source.seek((selector[0] + 15 + clusters["overlays"] - 2) * 512)
        directory = source.read(512)
        require(directory[:11] == b".          "
                and directory[11] == 0x10
                and struct.unpack_from("<H", directory, 26)[0]
                    == clusters["overlays"],
                "selector overlay '.' entry is invalid")
        require(directory[32:43] == b"..         "
                and directory[43] == 0x10
                and struct.unpack_from("<H", directory, 58)[0] == 0,
                "selector overlay '..' entry is invalid")
        overlay_offset = consume_lfn(
            directory,
            64,
            "dwc2.dtbo",
            b"DWC2~1  DTB",
        )
        overlay_entry = directory[overlay_offset:overlay_offset + 32]
        require(overlay_entry[:11] == b"DWC2~1  DTB"
                and overlay_entry[11] == 0x20
                and struct.unpack_from("<H", overlay_entry, 26)[0]
                    == next_cluster
                and struct.unpack_from("<I", overlay_entry, 28)[0]
                    == len(overlay_contents)
                and not any(directory[overlay_offset + 32:]),
                "selector overlay file entry is invalid")
        clusters["overlays/dwc2.dtbo"] = next_cluster
        source.seek((selector[0] + 15 + next_cluster - 2) * 512)
        encoded = source.read(overlay_clusters * 512)
        require(encoded[:len(overlay_contents)] == overlay_contents,
                "selector DWC2 overlay content changed")
        require(not any(encoded[len(overlay_contents):]),
                "selector DWC2 overlay padding is not zero")
    require(clusters["autoboot.txt"] == 2,
            "autoboot.txt moved away from cluster 2")
    return clusters


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


def writing_boot_control(
    *,
    confirmed_digest: str,
    candidate_digest: str,
    slot_block_count: int,
    next_candidate_block: int,
    phase: int = 1,
) -> bytes:
    record = bytearray(160)
    record[0:8] = b"SWABCTL1"
    struct.pack_into("<HH", record, 8, 1, len(record))
    struct.pack_into("<Q", record, 16, 2)
    record[24] = phase
    record[25] = 1  # confirmed A
    record[26] = 2  # candidate B
    record[27] = 1  # release
    struct.pack_into("<Q", record, 32, 1)
    struct.pack_into("<Q", record, 40, 2)
    struct.pack_into("<Q", record, 48, 0x1122_3344_5566_7788)
    struct.pack_into("<Q", record, 56, next_candidate_block)
    struct.pack_into("<Q", record, 64, slot_block_count)
    record[72:104] = bytes.fromhex(confirmed_digest)
    record[104:136] = bytes.fromhex(candidate_digest)
    struct.pack_into("<Q", record, 136, 0x5357_4142_0000_0003)
    struct.pack_into("<I", record, 156, zlib.crc32(record[:156]) & 0xFFFF_FFFF)
    return bytes(record)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="swiftos-rpi5-media-") as temporary:
        root = Path(temporary)
        package = package_fixture(root)
        alternate_package = package_fixture(
            root / "alternate-source",
            mutate_kernel=True,
        )
        first = root / "first.img"
        second = root / "second.img"
        alternate = root / "alternate.img"
        exact = root / "exact-block-count.img"
        default = root / "default-layout.img"
        build(package, first)
        build(package, second)
        build(alternate_package, alternate)
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
        slot_a_raw_digest = extent_digest(first, *slot_a)
        slot_b_raw_digest = extent_digest(first, *slot_b)
        slot_digest = content_digest(first, *slot_a)
        require(slot_digest == content_digest(first, *slot_b),
                "fresh A/B slots are not semantically identical")
        require(slot_a_raw_digest != slot_b_raw_digest,
                "location-specific A/B slots unexpectedly have one raw hash")
        with first.open("rb") as source:
            source.seek(slot_a[0] * 512)
            slot_a_boot = source.read(512)
            source.seek(slot_b[0] * 512)
            slot_b_boot = source.read(512)
        normalized_a_boot = bytearray(slot_a_boot)
        normalized_b_boot = bytearray(slot_b_boot)
        normalized_a_boot[28:32] = bytes(4)
        normalized_b_boot[28:32] = bytes(4)
        require(normalized_a_boot == normalized_b_boot,
                "A/B boot sectors differ outside BPB_HiddSec")
        require(struct.unpack_from("<I", slot_a_boot, 28)[0] == slot_a[0],
                "slot A FAT32 hidden sectors do not name its partition")
        require(struct.unpack_from("<I", slot_b_boot, 28)[0] == slot_b[0],
                "slot B FAT32 hidden sectors do not name its partition")
        with first.open("rb") as source:
            source.seek((slot_a[0] + 6) * 512 + 28)
            slot_a_backup_hidden = struct.unpack("<I", source.read(4))[0]
            source.seek((slot_b[0] + 6) * 512 + 28)
            slot_b_backup_hidden = struct.unpack("<I", source.read(4))[0]
        require(slot_a_backup_hidden == slot_a[0],
                "slot A backup BPB_HiddSec does not name its partition")
        require(slot_b_backup_hidden == slot_b[0],
                "slot B backup BPB_HiddSec does not name its partition")
        require(slot_a_boot[71:82] == b"SWIFTOS-AB ",
                "A/B FAT32 canonical volume label changed")
        selector_clusters = require_selector_rescue_layout(
            first,
            selector,
            package,
        )
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
        require(report["selector"]["policy_valid"] is True,
                "fresh selector policy was not accepted")
        require(report["selector"]["try_slot"] == "B",
                "fresh selector does not trial B")
        require(report["selector"]["autoboot_cluster"] == 2,
                "inspector lost the selector-writer cluster")
        require(report["selector"]["autoboot_partition_block"] == 15,
                "inspector lost the selector-writer block")
        rescue = report["selector"]["rescue"]
        require(rescue["boot_partition"] == 1,
                "inspector lost the rescue boot partition")
        require(rescue["hardware_verified"] is False,
                "unverified rescue fallback was presented as verified")
        rescue_sources = {
            "config.txt": package / "RESCUE-CONFIG.txt",
            "kernel8.img": package / "kernel8.img",
            "bcm2712-rpi-5-b.dtb": package / "bcm2712-rpi-5-b.dtb",
            "overlays/dwc2.dtbo": package / "overlays/dwc2.dtbo",
        }
        for name, path in rescue_sources.items():
            require(
                rescue["files"][name]["sha256"]
                    == hashlib.sha256(path.read_bytes()).hexdigest(),
                f"inspector rescue digest changed: {name}",
            )

        # Rescue payload bytes are immutable and must be the exact release
        # bytes carried in both boot slots. Self-consistent FAT metadata is not
        # enough to bless a mutated recovery kernel.
        with second.open("r+b") as target:
            kernel_block = (
                selector[0] + 15 + selector_clusters["kernel8.img"] - 2
            )
            target.seek(kernel_block * 512)
            original = target.read(1)
            require(len(original) == 1, "rescue corruption fixture is truncated")
            target.seek(kernel_block * 512)
            target.write(bytes([original[0] ^ 0x80]))
        rescue_error = inspect(second, should_succeed=False)
        require("selector rescue kernel8.img digest is invalid" in rescue_error,
                "mutated selector rescue kernel was not rejected")
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
        require(
            report["boot_slots"]["A"]["image_sha256"] == slot_a_raw_digest
                and report["boot_slots"]["B"]["image_sha256"]
                    == slot_b_raw_digest
                and report["boot_slots"]["A"]["content_sha256"]
                    == slot_digest
                and report["boot_slots"]["B"]["content_sha256"]
                    == slot_digest,
            "inspector lost raw or location-neutral slot identity",
        )
        require(
            report["ab_transaction"]["raw_slots_converged"] is False
                and report["ab_transaction"]["semantic_slots_converged"] is True
                and report["ab_transaction"]["both_slots_valid"] is True,
            "fresh A/B transaction was not reported as converged",
        )
        journal = report["boot_control_journal"]
        require(journal["status"] == "healthy"
                and journal["valid_replicas"] == 2,
                "fresh boot-control journal is not redundant")
        initial = journal["newest"]
        require(initial["sequence"] == 1 and initial["phase"] == "stable",
                "fresh boot-control state is not stable sequence one")
        require(initial["confirmed_slot"] == "A"
                and initial["confirmed_generation"] == 1,
                "fresh boot-control state does not confirm slot A")
        require(initial["confirmed_digest"] == slot_digest,
                "fresh boot-control digest lost content identity")
        require(initial["slot_block_count"] == slot_a[1],
                "fresh boot-control geometry differs from the slots")
        require(initial["media_layout_fingerprint"]
                == "0x5357414200000003",
                "fresh boot-control layout fingerprint changed")
        require(report["data_superblock_status"] == "healthy",
                "fresh superblocks are not healthy")
        layout = report["data_volume"]
        require(layout["kernel_log_start_block"] == 2, "log arena start")
        require(layout["kernel_log_block_count"] == 64, "log arena count")
        require(layout["user_data_start_block"] == 66, "user arena start")

        legacy_revision_two = root / "legacy-revision-two.img"
        legacy_digest = convert_to_revision_two(
            first,
            legacy_revision_two,
            package,
            selector,
            slot_a,
            slot_b,
            data,
        )
        legacy_report = inspect(legacy_revision_two)
        require(
            legacy_report["media_layout"]["revision"] == 2
                and legacy_report["media_layout"]["compatibility"]
                    == "legacy-read-only"
                and legacy_report["media_layout"]
                    ["requires_whole_card_reflash"] is True,
            "revision-two whole image lost its read-only compatibility profile",
        )
        require(
            legacy_report["selector"]["format_revision"] == 2
                and legacy_report["selector"]["read_only_compatibility"] is True
                and "rescue.dtb"
                    in legacy_report["selector"]["rescue"]["files"],
            "revision-two selector was not decoded by its frozen reader",
        )
        require(
            legacy_report["boot_slots"]["A"]["image_sha256"] == legacy_digest
                and legacy_report["boot_slots"]["A"]
                    ["journal_identity_sha256"] == legacy_digest
                and legacy_report["boot_slots"]["B"]
                    ["journal_identity_sha256"] == legacy_digest
                and legacy_report["boot_control_journal"]["newest"]
                    ["confirmed_digest"] == legacy_digest,
            "revision-two raw-slot journal identity was not preserved",
        )

        torn_journal = root / "torn-journal.img"
        shutil.copyfile(first, torn_journal)
        with torn_journal.open("r+b") as target:
            target.seek(data[0] * 512 + 64)
            target.write(b"X")
        torn_report = inspect(torn_journal)
        require(torn_report["boot_control_journal"]["status"] == "degraded"
                and torn_report["boot_control_journal"]["valid_replicas"] == 1,
                "one torn boot-control replica did not recover from its peer")

        # A torn one-sector selector commit must not hide the immutable rescue
        # volume or the journal-authorized repair direction. The candidate was
        # already fully verified and health-confirmed in this phase, so repair
        # targets B while compatibility data remains sourced from confirmed A.
        torn_selector = root / "torn-selector-policy.img"
        shutil.copyfile(first, torn_selector)
        pending = writing_boot_control(
            confirmed_digest=slot_digest,
            candidate_digest=slot_digest,
            slot_block_count=slot_b[1],
            next_candidate_block=slot_b[1],
            phase=4,
        )
        with torn_selector.open("r+b") as target:
            target.seek((selector[0] + 15) * 512)
            target.write(b"X")
            for replica in (0, 1):
                target.seek((data[0] + replica) * 512 + 64)
                target.write(pending)
        torn_selector_report = inspect(torn_selector)
        require(
            torn_selector_report["selector"]["policy_valid"] is False
                and torn_selector_report["selector"]["default_slot"] is None
                and torn_selector_report["selector"]["try_slot"] is None
                and torn_selector_report["selector"]["repair_target"] == "B"
                and torn_selector_report["ab_transaction"]
                    ["selector_requires_repair"] is True
                and torn_selector_report["ab_transaction"]
                    ["selector_repair_target"] == "B",
            "torn selector policy lost its journal-derived repair target",
        )
        require(
            torn_selector_report["ab_transaction"]
                ["transaction_consistent"] is False,
            "torn selector policy was reported as transaction-consistent",
        )

        wrong_selector = root / "wrong-valid-selector.img"
        shutil.copyfile(first, wrong_selector)
        with wrong_selector.open("r+b") as target:
            target.seek((selector[0] + 15) * 512)
            target.write(SELECTOR_AUTOBOOT_B.ljust(512, b"\0"))
        wrong_selector_error = inspect(wrong_selector, should_succeed=False)
        require(
            "selector default disagrees with boot-control state"
                in wrong_selector_error,
            "valid but unauthorized selector policy passed reconciliation",
        )

        # Divergence is a valid durable state after a failed trial. The
        # confirmed slot remains strict while an independently valid peer no
        # longer causes returned-card troubleshooting to abort.
        divergent = root / "divergent-stable.img"
        shutil.copyfile(first, divergent)
        _, _, alternate_a, _, _ = read_mbr(alternate)
        require(alternate_a[1] == slot_b[1],
                "alternate valid release has different slot geometry")
        require(extent_digest(alternate, *alternate_a) != slot_digest,
                "alternate valid release did not change raw slot identity")
        with alternate.open("rb") as source, divergent.open("r+b") as target:
            source.seek(alternate_a[0] * 512)
            target.seek(slot_b[0] * 512)
            remaining = slot_b[1] * 512
            while remaining:
                chunk = source.read(min(remaining, 1_024 * 1_024))
                require(bool(chunk), "alternate slot fixture is truncated")
                target.write(chunk)
                remaining -= len(chunk)
        relocate_slot_hidden_sectors(divergent, slot_b[0])
        divergent_report = inspect(divergent)
        require(
            divergent_report["ab_transaction"]["raw_slots_converged"] is False
                and divergent_report["ab_transaction"]
                    ["semantic_slots_converged"] is False
                and divergent_report["ab_transaction"]["both_slots_valid"] is True
                and divergent_report["ab_transaction"]["confirmed_slot"] == "A",
            "valid stable slot divergence was not recoverably reported",
        )

        # Candidate boot sectors are deliberately invalid while a raw slot is
        # staged. Journal reconciliation must keep the confirmed A slot usable
        # and report B's bounded validation failure rather than rejecting all
        # diagnostic access to the returned card.
        staging = root / "writing-candidate.img"
        shutil.copyfile(first, staging)
        candidate_digest = content_digest(staging, *slot_b)
        writing = writing_boot_control(
            confirmed_digest=slot_digest,
            candidate_digest=candidate_digest,
            slot_block_count=slot_b[1],
            next_candidate_block=1,
        )
        with staging.open("r+b") as target:
            target.seek(slot_b[0] * 512)
            target.write(bytes(512))
            target.seek((slot_b[0] + 6) * 512)
            target.write(bytes(512))
            for replica in (0, 1):
                target.seek((data[0] + replica) * 512 + 64)
                target.write(writing)
        staging_report = inspect(staging)
        require(
            staging_report["ab_transaction"]["phase"] == "writing-candidate"
                and staging_report["ab_transaction"]["confirmed_slot"] == "A"
                and staging_report["ab_transaction"]["both_slots_valid"] is False
                and staging_report["boot_slots"]["A"]["valid"] is True
                and staging_report["boot_slots"]["B"]["valid"] is False,
            "in-progress activation-last media was not recoverably reported",
        )

        backup_corrupt = root / "backup-boot-corrupt.img"
        shutil.copyfile(first, backup_corrupt)
        with backup_corrupt.open("r+b") as target:
            target.seek((slot_a[0] + 6) * 512 + 10)
            encoded = target.read(1)
            require(len(encoded) == 1, "backup-boot fixture is truncated")
            target.seek((slot_a[0] + 6) * 512 + 10)
            target.write(bytes([encoded[0] ^ 0x40]))
        backup_error = inspect(backup_corrupt, should_succeed=False)
        require("boot-sector replicas disagree" in backup_error,
                "confirmed slot accepted a mismatched FAT32 backup boot sector")

        wrong_hidden = root / "wrong-hidden-sectors.img"
        shutil.copyfile(first, wrong_hidden)
        with wrong_hidden.open("r+b") as target:
            for boot_sector in (0, 6):
                target.seek((slot_a[0] + boot_sector) * 512 + 28)
                target.write(bytes(4))
        hidden_error = inspect(wrong_hidden, should_succeed=False)
        require("not the SwiftOS FAT32 format" in hidden_error,
                "confirmed slot accepted BPB_HiddSec for another location")

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

        # A self-looping root chain is bounded and rejected. Corrupt both FAT
        # replicas so the fixture reaches chain traversal after replica checks.
        looped = root / "looped-fat.img"
        shutil.copyfile(first, looped)
        _, _, slot_a, _, _ = read_mbr(looped)
        with looped.open("r+b") as target:
            boot_offset = slot_a[0] * 512
            target.seek(boot_offset)
            bpb = target.read(512)
            reserved = struct.unpack_from("<H", bpb, 14)[0]
            fat_sectors = struct.unpack_from("<I", bpb, 36)[0]
            for fat_index in range(2):
                fat_offset = (
                    slot_a[0] + reserved + fat_index * fat_sectors
                ) * 512
                target.seek(fat_offset + 2 * 4)
                target.write(struct.pack("<I", 2))
        loop_error = inspect(looped, should_succeed=False)
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
