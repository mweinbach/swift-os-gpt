#!/usr/bin/env python3
"""Build and inspect a sparse, deterministic SwiftOS Raspberry Pi 5 image.

The builder accepts only a new regular-file output. It never opens a block
device, unmounts media, or chooses a flash target. The resulting image has an
MBR, a bootable FAT32 partition populated from a validated Pi package, and a
type-0xDA SwiftOS data partition with duplicate signed superblocks plus a
bounded empty persistent-log arena.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import sys
import zlib


SECTOR_SIZE = 512
ALIGNMENT_SECTORS = 2_048
FAT32_LBA_TYPE = 0x0C
SWIFTOS_DATA_TYPE = 0xDA
DATA_MAGIC = b"SWOSDATA"
DATA_VERSION = 1
DATA_HEADER_BYTES = 64
LOG_MAGIC = b"SWLOG001"
LOG_VERSION = 1
LOG_HEADER_BYTES = 40
MAX_LOG_BLOCKS = 65_536
MAX_LOG_BYTES = 32 * 1_024 * 1_024
DEFAULT_LOG_BLOCKS = 4_096
DEFAULT_BOOT_MIB = 256
DEFAULT_TOTAL_MIB = 1_024
MINIMUM_BOOT_MIB = 40
MINIMUM_DATA_MIB = 8
MAXIMUM_DIRECTORY_BYTES = 1 * 1_024 * 1_024
MAXIMUM_DIRECTORY_DEPTH = 64
MAXIMUM_DIRECTORY_COUNT = 4_096
MAXIMUM_DIRECTORY_SCAN_BYTES = 64 * 1_024 * 1_024
MAXIMUM_BOOT_FILE_COUNT = 4_096
MAXIMUM_BOOT_FILE_BYTES = 512 * 1_024 * 1_024
MAXIMUM_TOTAL_BOOT_FILE_BYTES = 512 * 1_024 * 1_024


class MediaError(Exception):
    pass


def align_up(value: int, alignment: int) -> int:
    return ((value + alignment - 1) // alignment) * alignment


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFF_FFFF


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_exact(image, offset: int, byte_count: int, label: str) -> bytes:
    if offset < 0 or byte_count < 0:
        raise MediaError(f"invalid {label} extent")
    image.seek(offset)
    data = image.read(byte_count)
    if len(data) != byte_count:
        raise MediaError(f"truncated {label}")
    return data


@dataclass
class FATNode:
    name: str
    is_directory: bool
    data: bytes = b""
    children: list["FATNode"] = field(default_factory=list)
    parent: "FATNode | None" = None
    short_name: bytes = b""
    needs_lfn: bool = False
    clusters: list[int] = field(default_factory=list)


class FAT32Volume:
    reserved_sectors = 32
    fat_count = 2
    root_cluster = 2

    def __init__(
        self,
        image,
        partition_start: int,
        partition_sectors: int,
        files: dict[str, bytes],
    ) -> None:
        self.image = image
        self.partition_start = partition_start
        self.partition_sectors = partition_sectors
        self.sectors_per_cluster = self._choose_sectors_per_cluster(
            partition_sectors
        )
        self.cluster_bytes = self.sectors_per_cluster * SECTOR_SIZE
        self.fat_sectors, self.cluster_count = self._fat_geometry()
        if self.cluster_count < 65_525:
            raise MediaError("boot partition is too small for a valid FAT32 volume")
        self.data_start = (
            partition_start + self.reserved_sectors
            + self.fat_count * self.fat_sectors
        )
        self.root = self._build_tree(files)
        self.next_cluster = self.root_cluster
        self.fat = [0] * (self.cluster_count + 2)
        self.fat[0] = 0x0FFF_FFF8
        self.fat[1] = 0x0FFF_FFFF

    @staticmethod
    def _choose_sectors_per_cluster(partition_sectors: int) -> int:
        # Keep at least 65,525 data clusters while avoiding needlessly large
        # FATs. Supported package sizes are far below the resulting limits.
        for candidate in (64, 32, 16, 8, 4, 2, 1):
            if partition_sectors // candidate >= 65_600:
                return candidate
        return 1

    def _fat_geometry(self) -> tuple[int, int]:
        fat_sectors = 1
        while True:
            data_sectors = (
                self.partition_sectors - self.reserved_sectors
                - self.fat_count * fat_sectors
            )
            if data_sectors <= 0:
                raise MediaError("boot partition has no FAT32 data area")
            clusters = data_sectors // self.sectors_per_cluster
            required = math.ceil((clusters + 2) * 4 / SECTOR_SIZE)
            # A slightly oversized FAT is valid. Requiring exact equality can
            # oscillate by one allocation unit near a geometry boundary.
            if required <= fat_sectors:
                return fat_sectors, clusters
            fat_sectors = required

    def _build_tree(self, files: dict[str, bytes]) -> FATNode:
        root = FATNode(name="", is_directory=True)
        for path_text, data in sorted(files.items()):
            path = PurePosixPath(path_text)
            if path.is_absolute() or ".." in path.parts or not path.parts:
                raise MediaError(f"unsafe boot package path: {path_text}")
            directory = root
            for component in path.parts[:-1]:
                existing = next(
                    (child for child in directory.children
                     if child.name == component),
                    None,
                )
                if existing is None:
                    existing = FATNode(
                        name=component,
                        is_directory=True,
                        parent=directory,
                    )
                    directory.children.append(existing)
                if not existing.is_directory:
                    raise MediaError(f"boot package path collision: {path_text}")
                directory = existing
            name = path.parts[-1]
            if any(child.name == name for child in directory.children):
                raise MediaError(f"duplicate boot package path: {path_text}")
            directory.children.append(
                FATNode(name=name, is_directory=False, data=data, parent=directory)
            )
        self._assign_short_names(root)
        return root

    def _assign_short_names(self, directory: FATNode) -> None:
        used: set[bytes] = set()
        for node in sorted(directory.children, key=lambda item: item.name):
            node.short_name, node.needs_lfn = self._short_name(node.name, used)
            used.add(node.short_name)
            if node.is_directory:
                self._assign_short_names(node)

    @staticmethod
    def _short_name(name: str, used: set[bytes]) -> tuple[bytes, bool]:
        if "." in name and not name.startswith("."):
            base, extension = name.rsplit(".", 1)
        else:
            base, extension = name, ""
        allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$%'-@~`!(){}^#&"

        def clean(value: str) -> str:
            return "".join(character for character in value.upper()
                           if character in allowed)

        clean_base = clean(base)
        clean_extension = clean(extension)
        direct = (clean_base[:8].ljust(8) + clean_extension[:3].ljust(3)).encode(
            "ascii"
        )
        directly_representable = (
            bool(clean_base)
            and len(base) <= 8
            and len(extension) <= 3
            and clean_base == base.upper()
            and clean_extension == extension.upper()
            and direct not in used
        )
        if directly_representable:
            canonical = clean_base + (("." + clean_extension)
                                      if clean_extension else "")
            return direct, name != canonical

        prefix = (clean_base or "FILE")[:6]
        for ordinal in range(1, 1_000_000):
            suffix = f"~{ordinal}"
            alias_base = (prefix[: 8 - len(suffix)] + suffix).ljust(8)
            alias = (alias_base + clean_extension[:3].ljust(3)).encode("ascii")
            if alias not in used:
                return alias, True
        raise MediaError(f"could not allocate FAT alias for {name}")

    @staticmethod
    def _lfn_entry_count(node: FATNode) -> int:
        if not node.needs_lfn:
            return 0
        units = len(node.name.encode("utf-16le")) // 2
        return math.ceil((units + 1) / 13)

    def _directory_entry_count(self, directory: FATNode) -> int:
        count = 0 if directory.parent is None else 2
        for child in directory.children:
            count += 1 + self._lfn_entry_count(child)
        return count + 1

    def _allocate_chain(self, cluster_count: int) -> list[int]:
        if cluster_count <= 0:
            cluster_count = 1
        first = self.next_cluster
        last = first + cluster_count
        if last > self.cluster_count + 2:
            raise MediaError("boot package does not fit in FAT32 partition")
        chain = list(range(first, last))
        self.next_cluster = last
        for index, cluster in enumerate(chain):
            self.fat[cluster] = (
                chain[index + 1] if index + 1 < len(chain) else 0x0FFF_FFFF
            )
        return chain

    def _allocate(self) -> None:
        directories: list[FATNode] = []
        files: list[FATNode] = []

        def collect(node: FATNode) -> None:
            directories.append(node)
            for child in sorted(node.children, key=lambda item: item.name):
                if child.is_directory:
                    collect(child)
                else:
                    files.append(child)

        collect(self.root)
        for directory in directories:
            bytes_needed = self._directory_entry_count(directory) * 32
            directory.clusters = self._allocate_chain(
                math.ceil(bytes_needed / self.cluster_bytes)
            )
        if self.root.clusters[0] != self.root_cluster:
            raise MediaError("FAT32 root cluster allocation changed")
        for file_node in files:
            file_node.clusters = self._allocate_chain(
                max(1, math.ceil(len(file_node.data) / self.cluster_bytes))
            )

    def _cluster_offset(self, cluster: int) -> int:
        sector = self.data_start + (cluster - 2) * self.sectors_per_cluster
        return sector * SECTOR_SIZE

    def _write_at(self, offset: int, data: bytes) -> None:
        self.image.seek(offset)
        self.image.write(data)

    def _boot_sector(self) -> bytes:
        sector = bytearray(SECTOR_SIZE)
        sector[0:3] = b"\xeb\x58\x90"
        sector[3:11] = b"SWIFTOS "
        struct.pack_into("<H", sector, 11, SECTOR_SIZE)
        sector[13] = self.sectors_per_cluster
        struct.pack_into("<H", sector, 14, self.reserved_sectors)
        sector[16] = self.fat_count
        sector[21] = 0xF8
        struct.pack_into("<H", sector, 24, 63)
        struct.pack_into("<H", sector, 26, 255)
        struct.pack_into("<I", sector, 28, self.partition_start)
        struct.pack_into("<I", sector, 32, self.partition_sectors)
        struct.pack_into("<I", sector, 36, self.fat_sectors)
        struct.pack_into("<I", sector, 44, self.root_cluster)
        struct.pack_into("<H", sector, 48, 1)
        struct.pack_into("<H", sector, 50, 6)
        sector[64] = 0x80
        sector[66] = 0x29
        struct.pack_into("<I", sector, 67, 0x5357_4F53)
        sector[71:82] = b"SWIFTOS    "
        sector[82:90] = b"FAT32   "
        sector[510:512] = b"\x55\xaa"
        return bytes(sector)

    def _fsinfo_sector(self) -> bytes:
        sector = bytearray(SECTOR_SIZE)
        struct.pack_into("<I", sector, 0, 0x4161_5252)
        struct.pack_into("<I", sector, 484, 0x6141_7272)
        allocated = self.next_cluster - 2
        struct.pack_into("<I", sector, 488, self.cluster_count - allocated)
        struct.pack_into("<I", sector, 492, self.next_cluster)
        struct.pack_into("<I", sector, 508, 0xAA55_0000)
        return bytes(sector)

    @staticmethod
    def _lfn_checksum(short_name: bytes) -> int:
        checksum = 0
        for byte in short_name:
            checksum = (((checksum & 1) << 7) | (checksum >> 1)) + byte
            checksum &= 0xFF
        return checksum

    def _lfn_entries(self, node: FATNode) -> list[bytes]:
        if not node.needs_lfn:
            return []
        units = list(struct.unpack(
            f"<{len(node.name.encode('utf-16le')) // 2}H",
            node.name.encode("utf-16le"),
        ))
        units.append(0)
        while len(units) % 13:
            units.append(0xFFFF)
        chunks = [units[index:index + 13]
                  for index in range(0, len(units), 13)]
        checksum = self._lfn_checksum(node.short_name)
        entries: list[bytes] = []
        positions = (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)
        for ordinal in range(len(chunks), 0, -1):
            entry = bytearray(32)
            entry[0] = ordinal | (0x40 if ordinal == len(chunks) else 0)
            entry[11] = 0x0F
            entry[13] = checksum
            for position, unit in zip(positions, chunks[ordinal - 1]):
                struct.pack_into("<H", entry, position, unit)
            entries.append(bytes(entry))
        return entries

    @staticmethod
    def _short_entry(node: FATNode) -> bytes:
        entry = bytearray(32)
        entry[0:11] = node.short_name
        entry[11] = 0x10 if node.is_directory else 0x20
        first_cluster = node.clusters[0]
        struct.pack_into("<H", entry, 20, first_cluster >> 16)
        struct.pack_into("<H", entry, 26, first_cluster & 0xFFFF)
        # 1980-01-01, midnight.
        struct.pack_into("<H", entry, 16, 0x0021)
        struct.pack_into("<H", entry, 18, 0x0021)
        struct.pack_into("<H", entry, 24, 0x0021)
        if not node.is_directory:
            struct.pack_into("<I", entry, 28, len(node.data))
        return bytes(entry)

    @staticmethod
    def _dot_entry(name: bytes, cluster: int) -> bytes:
        entry = bytearray(32)
        entry[0:11] = name.ljust(11)
        entry[11] = 0x10
        struct.pack_into("<H", entry, 20, cluster >> 16)
        struct.pack_into("<H", entry, 26, cluster & 0xFFFF)
        return bytes(entry)

    def _directory_bytes(self, directory: FATNode) -> bytes:
        output = bytearray()
        if directory.parent is not None:
            output += self._dot_entry(b".", directory.clusters[0])
            parent_cluster = (
                directory.parent.clusters[0]
                if directory.parent.parent is not None else 0
            )
            output += self._dot_entry(b"..", parent_cluster)
        for node in sorted(directory.children, key=lambda item: item.name):
            for entry in self._lfn_entries(node):
                output += entry
            output += self._short_entry(node)
        output += bytes(32)
        capacity = len(directory.clusters) * self.cluster_bytes
        if len(output) > capacity:
            raise MediaError(f"directory allocation is short for {directory.name}")
        return bytes(output).ljust(capacity, b"\0")

    def write(self) -> None:
        self._allocate()
        base = self.partition_start * SECTOR_SIZE
        boot = self._boot_sector()
        fsinfo = self._fsinfo_sector()
        self._write_at(base, boot)
        self._write_at(base + SECTOR_SIZE, fsinfo)
        self._write_at(base + 6 * SECTOR_SIZE, boot)
        self._write_at(base + 7 * SECTOR_SIZE, fsinfo)

        fat_bytes = bytearray(self.fat_sectors * SECTOR_SIZE)
        for cluster, value in enumerate(self.fat):
            struct.pack_into("<I", fat_bytes, cluster * 4, value)
        for fat_index in range(self.fat_count):
            offset = (
                self.partition_start + self.reserved_sectors
                + fat_index * self.fat_sectors
            ) * SECTOR_SIZE
            self._write_at(offset, fat_bytes)

        def write_node(node: FATNode) -> None:
            content = (
                self._directory_bytes(node) if node.is_directory else node.data
            )
            for index, cluster in enumerate(node.clusters):
                chunk = content[
                    index * self.cluster_bytes:(index + 1) * self.cluster_bytes
                ]
                self._write_at(
                    self._cluster_offset(cluster),
                    chunk.ljust(self.cluster_bytes, b"\0"),
                )
            if node.is_directory:
                for child in node.children:
                    write_node(child)

        write_node(self.root)


def package_files(package: Path) -> dict[str, bytes]:
    if not package.is_dir():
        raise MediaError(f"boot package directory not found: {package}")
    checksum_path = package / "SHA256SUMS"
    if not checksum_path.is_file():
        raise MediaError("boot package has no SHA256SUMS")
    expected: dict[str, str] = {}
    for line in checksum_path.read_text(encoding="utf-8").splitlines():
        try:
            digest, relative = line.split("  ", 1)
        except ValueError as error:
            raise MediaError("malformed boot-package SHA256SUMS") from error
        expected[relative] = digest
    files: dict[str, bytes] = {}
    total_file_bytes = 0
    folded_paths: set[str] = set()
    for path in sorted(package.rglob("*")):
        if path.is_symlink():
            raise MediaError(f"boot package contains a symlink: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(package).as_posix()
        if relative.casefold() in folded_paths:
            raise MediaError("boot package contains case-fold-colliding paths")
        folded_paths.add(relative.casefold())
        data = path.read_bytes()
        if len(data) > MAXIMUM_BOOT_FILE_BYTES:
            raise MediaError(f"boot package file is too large: {relative}")
        files[relative] = data
        total_file_bytes += len(data)
        if total_file_bytes > MAXIMUM_TOTAL_BOOT_FILE_BYTES:
            raise MediaError("boot package exceeds the total byte limit")
        if relative != "SHA256SUMS":
            if expected.get(relative) != sha256(data):
                raise MediaError(f"boot package checksum mismatch: {relative}")
    actual_hashed = set(files) - {"SHA256SUMS"}
    if len(files) > MAXIMUM_BOOT_FILE_COUNT:
        raise MediaError("boot package has too many files")
    if set(expected) != actual_hashed:
        raise MediaError("boot package checksum membership changed")
    return files


def mbr_partition_entry(
    *, bootable: bool, partition_type: int, start: int, count: int
) -> bytes:
    if not (0 < start <= 0xFFFF_FFFF and 0 < count <= 0xFFFF_FFFF):
        raise MediaError("partition extent exceeds MBR addressing")
    entry = bytearray(16)
    entry[0] = 0x80 if bootable else 0
    entry[1:4] = b"\xfe\xff\xff"
    entry[4] = partition_type
    entry[5:8] = b"\xfe\xff\xff"
    struct.pack_into("<II", entry, 8, start, count)
    return bytes(entry)


def data_superblock(total_blocks: int, log_blocks: int) -> bytes:
    if not (
        2 <= log_blocks <= MAX_LOG_BLOCKS
        and log_blocks * SECTOR_SIZE <= MAX_LOG_BYTES
        and total_blocks > 2 + log_blocks
    ):
        raise MediaError("invalid SwiftOS data-volume geometry")
    header = bytearray(SECTOR_SIZE)
    header[0:8] = DATA_MAGIC
    struct.pack_into("<HHI", header, 8, DATA_VERSION, DATA_HEADER_BYTES, SECTOR_SIZE)
    struct.pack_into("<Q", header, 16, total_blocks)
    struct.pack_into("<QQ", header, 24, 2, log_blocks)
    struct.pack_into("<QQ", header, 40, 2 + log_blocks, total_blocks - 2 - log_blocks)
    struct.pack_into("<I", header, 56, 0)
    struct.pack_into("<I", header, 60, crc32(header[:60]))
    return bytes(header)


def build_image(
    package: Path,
    output: Path,
    *,
    total_sectors: int,
    boot_sectors: int,
    log_blocks: int,
) -> dict[str, object]:
    if os.path.lexists(output):
        mode = output.lstat().st_mode
        if not stat.S_ISREG(mode):
            raise MediaError("output must be a new regular file, never a device")
        raise MediaError(f"output already exists: {output}")
    if boot_sectors < MINIMUM_BOOT_MIB * 2_048:
        raise MediaError("boot partition is below the FAT32 minimum")
    boot_start = ALIGNMENT_SECTORS
    data_start = align_up(boot_start + boot_sectors, ALIGNMENT_SECTORS)
    data_sectors = total_sectors - data_start
    if data_sectors < MINIMUM_DATA_MIB * 2_048:
        raise MediaError("image leaves no useful SwiftOS data partition")
    if total_sectors > 0xFFFF_FFFF:
        raise MediaError("image exceeds the MBR sector-count limit")
    files = package_files(package)

    output.parent.mkdir(parents=True, exist_ok=True)
    created_output = False
    try:
        with output.open("xb") as image:
            created_output = True
            image.truncate(total_sectors * SECTOR_SIZE)
            mbr = bytearray(SECTOR_SIZE)
            struct.pack_into("<I", mbr, 440, 0x5357_4F53)
            mbr[446:462] = mbr_partition_entry(
                bootable=True,
                partition_type=FAT32_LBA_TYPE,
                start=boot_start,
                count=boot_sectors,
            )
            mbr[462:478] = mbr_partition_entry(
                bootable=False,
                partition_type=SWIFTOS_DATA_TYPE,
                start=data_start,
                count=data_sectors,
            )
            mbr[510:512] = b"\x55\xaa"
            image.seek(0)
            image.write(mbr)

            FAT32Volume(
                image,
                partition_start=boot_start,
                partition_sectors=boot_sectors,
                files=files,
            ).write()

            superblock = data_superblock(data_sectors, log_blocks)
            for relative_block in (0, 1):
                image.seek((data_start + relative_block) * SECTOR_SIZE)
                image.write(superblock)
            # The new sparse file reads as zero throughout the bounded log arena
            # and user arena; no full-device write is needed.
            image.flush()
            os.fsync(image.fileno())
    except Exception:
        if created_output:
            try:
                output.unlink()
            except FileNotFoundError:
                pass
        raise

    return {
        "format": "swiftos-rpi5-media-v1",
        "logical_block_bytes": SECTOR_SIZE,
        "logical_block_count": total_sectors,
        "boot": {
            "index": 1,
            "type": FAT32_LBA_TYPE,
            "start_block": boot_start,
            "block_count": boot_sectors,
        },
        "data": {
            "index": 2,
            "type": SWIFTOS_DATA_TYPE,
            "start_block": data_start,
            "block_count": data_sectors,
            "kernel_log_start_block": 2,
            "kernel_log_block_count": log_blocks,
            "user_data_start_block": 2 + log_blocks,
            "user_data_block_count": data_sectors - 2 - log_blocks,
        },
    }


def read_partition_entries(image) -> list[dict[str, int | bool]]:
    image_size = os.fstat(image.fileno()).st_size
    if image_size < SECTOR_SIZE or image_size % SECTOR_SIZE:
        raise MediaError("image size is not a whole number of logical blocks")
    image_blocks = image_size // SECTOR_SIZE
    mbr = read_exact(image, 0, SECTOR_SIZE, "MBR")
    if mbr[510:512] != b"\x55\xaa":
        raise MediaError("image has no valid MBR signature")
    entries = []
    for index in range(4):
        offset = 446 + index * 16
        status = mbr[offset]
        partition_type = mbr[offset + 4]
        start, count = struct.unpack_from("<II", mbr, offset + 8)
        if partition_type == 0:
            continue
        if (
            status not in (0, 0x80)
            or start == 0
            or count == 0
            or start >= image_blocks
            or count > image_blocks - start
        ):
            raise MediaError(f"invalid MBR partition {index + 1}")
        entries.append({
            "index": index + 1,
            "bootable": status == 0x80,
            "type": partition_type,
            "start_block": start,
            "block_count": count,
        })
    for first, left in enumerate(entries):
        left_start = int(left["start_block"])
        left_end = left_start + int(left["block_count"])
        for right in entries[first + 1:]:
            right_start = int(right["start_block"])
            right_end = right_start + int(right["block_count"])
            if left_start < right_end and right_start < left_end:
                raise MediaError("MBR partitions overlap")
    return entries


class FAT32Reader:
    def __init__(self, image, partition: dict[str, int | bool]) -> None:
        self.image = image
        self.start = int(partition["start_block"])
        self.count = int(partition["block_count"])
        boot = read_exact(
            image,
            self.start * SECTOR_SIZE,
            SECTOR_SIZE,
            "FAT32 boot sector",
        )
        if boot[510:512] != b"\x55\xaa":
            raise MediaError("FAT32 boot sector signature is invalid")
        self.bytes_per_sector = struct.unpack_from("<H", boot, 11)[0]
        self.sectors_per_cluster = boot[13]
        self.reserved = struct.unpack_from("<H", boot, 14)[0]
        self.fats = boot[16]
        self.fat_sectors = struct.unpack_from("<I", boot, 36)[0]
        self.root_cluster = struct.unpack_from("<I", boot, 44)[0]
        hidden_sectors = struct.unpack_from("<I", boot, 28)[0]
        total_sectors = struct.unpack_from("<I", boot, 32)[0]
        if (
            self.bytes_per_sector != SECTOR_SIZE
            or self.sectors_per_cluster == 0
            or self.sectors_per_cluster > 128
            or self.sectors_per_cluster & (self.sectors_per_cluster - 1)
            or self.reserved < 2
            or self.fats != 2
            or self.fat_sectors == 0
            or hidden_sectors != self.start
            or total_sectors != self.count
            or boot[82:90] != b"FAT32   "
        ):
            raise MediaError("boot partition is not the SwiftOS FAT32 format")
        self.fat_start = self.start + self.reserved
        self.data_start = self.fat_start + self.fats * self.fat_sectors
        self.cluster_bytes = self.sectors_per_cluster * SECTOR_SIZE
        data_sectors = self.start + self.count - self.data_start
        if data_sectors <= 0:
            raise MediaError("FAT32 data area lies outside its partition")
        self.cluster_count = data_sectors // self.sectors_per_cluster
        self.maximum_cluster = self.cluster_count + 1
        fat_entry_capacity = self.fat_sectors * SECTOR_SIZE // 4
        if (
            self.cluster_count < 65_525
            or self.cluster_count + 2 > fat_entry_capacity
            or not 2 <= self.root_cluster <= self.maximum_cluster
        ):
            raise MediaError("FAT32 cluster geometry is invalid")

    def _next_cluster(self, cluster: int) -> int | None:
        if not 2 <= cluster <= self.maximum_cluster:
            raise MediaError("FAT32 chain references an out-of-range cluster")
        raw = read_exact(
            self.image,
            self.fat_start * SECTOR_SIZE + cluster * 4,
            4,
            "FAT32 entry",
        )
        value = struct.unpack("<I", raw)[0] & 0x0FFF_FFFF
        if value >= 0x0FFF_FFF8:
            return None
        if not 2 <= value <= self.maximum_cluster:
            raise MediaError("FAT32 chain references an invalid cluster")
        return value

    def _chain(
        self,
        first: int,
        *,
        required_byte_count: int | None,
        maximum_byte_count: int,
    ) -> bytes:
        if required_byte_count is not None and required_byte_count < 0:
            raise MediaError("negative FAT32 file size")
        maximum_clusters = max(1, math.ceil(maximum_byte_count / self.cluster_bytes))
        expected_clusters = (
            None if required_byte_count is None
            else max(1, math.ceil(required_byte_count / self.cluster_bytes))
        )
        output = bytearray()
        cluster = first
        visited: set[int] = set()
        while cluster is not None:
            if cluster in visited:
                raise MediaError("FAT32 cluster chain loops")
            if len(visited) >= maximum_clusters:
                raise MediaError("FAT32 cluster chain exceeds its bounded extent")
            visited.add(cluster)
            sector = self.data_start + (cluster - 2) * self.sectors_per_cluster
            if sector < self.data_start or (
                sector + self.sectors_per_cluster > self.start + self.count
            ):
                raise MediaError("FAT32 cluster lies outside its partition")
            output += read_exact(
                self.image,
                sector * SECTOR_SIZE,
                self.cluster_bytes,
                "FAT32 cluster",
            )
            cluster = self._next_cluster(cluster)
        if expected_clusters is not None and len(visited) != expected_clusters:
            raise MediaError("FAT32 file chain length disagrees with its size")
        if required_byte_count is not None:
            return bytes(output[:required_byte_count])
        return bytes(output)

    @staticmethod
    def _decode_lfn(entries: list[bytes], short_name: bytes) -> str:
        if not entries or not (entries[0][0] & 0x40):
            raise MediaError("FAT32 long-name sequence has no terminal entry")
        expected_ordinals = list(range(len(entries), 0, -1))
        actual_ordinals = [entry[0] & 0x1F for entry in entries]
        if actual_ordinals != expected_ordinals:
            raise MediaError("FAT32 long-name ordinals are malformed")
        if any(entry[12] != 0 or entry[26:28] != b"\0\0" for entry in entries):
            raise MediaError("FAT32 long-name reserved fields are invalid")
        checksum = FAT32Volume._lfn_checksum(short_name)
        if any(entry[13] != checksum for entry in entries):
            raise MediaError("FAT32 long-name checksum is invalid")
        positions = (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)
        chunks: dict[int, list[int]] = {}
        for entry in entries:
            ordinal = entry[0] & 0x1F
            chunks[ordinal] = [struct.unpack_from("<H", entry, position)[0]
                               for position in positions]
        units: list[int] = []
        for ordinal in range(1, len(chunks) + 1):
            units.extend(chunks[ordinal])
        units = [unit for unit in units if unit not in (0, 0xFFFF)]
        return struct.pack(f"<{len(units)}H", *units).decode("utf-16le")

    def files(self) -> dict[str, bytes]:
        output: dict[str, bytes] = {}
        visited_directories: set[int] = set()
        visited_paths: set[str] = set()
        total_file_bytes = 0
        total_directory_bytes = 0

        def visit(first_cluster: int, prefix: str, depth: int) -> None:
            nonlocal total_file_bytes, total_directory_bytes
            if depth > MAXIMUM_DIRECTORY_DEPTH:
                raise MediaError("FAT32 directory nesting exceeds the limit")
            if first_cluster in visited_directories:
                raise MediaError("FAT32 directory graph contains a cycle")
            if len(visited_directories) >= MAXIMUM_DIRECTORY_COUNT:
                raise MediaError("FAT32 directory count exceeds the limit")
            visited_directories.add(first_cluster)
            remaining_directory_bytes = (
                MAXIMUM_DIRECTORY_SCAN_BYTES - total_directory_bytes
            )
            if remaining_directory_bytes <= 0:
                raise MediaError("FAT32 directory bytes exceed the limit")
            data = self._chain(
                first_cluster,
                required_byte_count=None,
                maximum_byte_count=min(
                    MAXIMUM_DIRECTORY_BYTES,
                    remaining_directory_bytes,
                ),
            )
            total_directory_bytes += len(data)
            lfn: list[bytes] = []
            for offset in range(0, len(data), 32):
                entry = data[offset:offset + 32]
                if entry[0] == 0:
                    break
                if entry[0] == 0xE5:
                    lfn = []
                    continue
                if entry[11] == 0x0F:
                    lfn.append(entry)
                    if len(lfn) > 20:
                        raise MediaError("FAT32 long name exceeds the bounded limit")
                    continue
                short_base = entry[0:8].decode("ascii").rstrip()
                short_ext = entry[8:11].decode("ascii").rstrip()
                name = (
                    self._decode_lfn(lfn, entry[0:11]) if lfn else short_base
                    + (("." + short_ext) if short_ext else "")
                )
                lfn = []
                if name in (".", ".."):
                    continue
                cluster = (
                    struct.unpack_from("<H", entry, 20)[0] << 16
                    | struct.unpack_from("<H", entry, 26)[0]
                )
                path = f"{prefix}/{name}" if prefix else name
                folded_path = path.casefold()
                if folded_path in visited_paths:
                    raise MediaError("FAT32 contains duplicate case-folded paths")
                visited_paths.add(folded_path)
                if entry[11] & 0x10:
                    visit(cluster, path, depth + 1)
                else:
                    size = struct.unpack_from("<I", entry, 28)[0]
                    if size > MAXIMUM_BOOT_FILE_BYTES:
                        raise MediaError("FAT32 file exceeds the inspection limit")
                    if size > MAXIMUM_TOTAL_BOOT_FILE_BYTES - total_file_bytes:
                        raise MediaError("FAT32 package exceeds the total byte limit")
                    total_file_bytes += size
                    if size == 0 and cluster == 0:
                        output[path] = b""
                    else:
                        output[path] = self._chain(
                            cluster,
                            required_byte_count=size,
                            maximum_byte_count=(
                                size if size else self.cluster_bytes
                            ),
                        )
                    if len(output) > MAXIMUM_BOOT_FILE_COUNT:
                        raise MediaError("FAT32 file count exceeds the limit")

        visit(self.root_cluster, "", 0)
        return output


def decode_data_layout(block: bytes, expected_blocks: int) -> dict[str, int]:
    if len(block) != SECTOR_SIZE or block[:8] != DATA_MAGIC:
        raise MediaError("SwiftOS data superblock magic is invalid")
    version, header_bytes, block_bytes = struct.unpack_from("<HHI", block, 8)
    total = struct.unpack_from("<Q", block, 16)[0]
    log_start, log_count = struct.unpack_from("<QQ", block, 24)
    user_start, user_count = struct.unpack_from("<QQ", block, 40)
    features, stored_crc = struct.unpack_from("<II", block, 56)
    if (
        version != DATA_VERSION
        or header_bytes != DATA_HEADER_BYTES
        or block_bytes != SECTOR_SIZE
        or total != expected_blocks
        or log_start != 2
        or not 2 <= log_count <= MAX_LOG_BLOCKS
        or log_count * SECTOR_SIZE > MAX_LOG_BYTES
        or user_start != log_start + log_count
        or user_count != total - user_start
        or features != 0
        or stored_crc != crc32(block[:60])
    ):
        raise MediaError("SwiftOS data superblock fields are invalid")
    return {
        "total_block_count": total,
        "kernel_log_start_block": log_start,
        "kernel_log_block_count": log_count,
        "user_data_start_block": user_start,
        "user_data_block_count": user_count,
        "crc32": stored_crc,
    }


def persistent_records(image, data_partition, layout) -> list[dict[str, object]]:
    records = []
    data_start = int(data_partition["start_block"])
    for slot in range(layout["kernel_log_block_count"]):
        block = read_exact(
            image,
            (data_start + layout["kernel_log_start_block"] + slot)
            * SECTOR_SIZE,
            SECTOR_SIZE,
            "persistent log block",
        )
        if block[:8] != LOG_MAGIC:
            continue
        version, header_bytes, payload_size = struct.unpack_from("<HHI", block, 8)
        sequence, timestamp = struct.unpack_from("<QQ", block, 16)
        payload_crc, header_crc = struct.unpack_from("<II", block, 32)
        if (
            version != LOG_VERSION
            or header_bytes != LOG_HEADER_BYTES
            or not 0 < payload_size <= SECTOR_SIZE - LOG_HEADER_BYTES
            or sequence == 0
            or (sequence - 1) % layout["kernel_log_block_count"] != slot
            or header_crc != crc32(block[:36])
        ):
            continue
        payload = block[LOG_HEADER_BYTES:LOG_HEADER_BYTES + payload_size]
        if payload_crc != crc32(payload):
            continue
        record: dict[str, object] = {
            "sequence": sequence,
            "timestamp_ticks": timestamp,
            "payload_hex": payload.hex(),
        }
        if len(payload) == 48:
            record["kernel_log_sequence"] = struct.unpack_from("<Q", payload, 0)[0]
            record["kernel_log_event_code"] = struct.unpack_from("<I", payload, 20)[0]
        records.append(record)
    records.sort(key=lambda item: int(item["sequence"]))
    return records


def inspect_image(path: Path) -> dict[str, object]:
    with path.open("rb") as image:
        entries = read_partition_entries(image)
        if len(entries) != 2:
            raise MediaError("SwiftOS media must have exactly two MBR partitions")
        boot, data = entries
        if (
            boot["index"] != 1
            or boot["type"] != FAT32_LBA_TYPE
            or not boot["bootable"]
            or data["index"] != 2
            or data["type"] != SWIFTOS_DATA_TYPE
            or data["bootable"]
            or int(boot["start_block"]) + int(boot["block_count"])
                > int(data["start_block"])
        ):
            raise MediaError("SwiftOS MBR layout is invalid")
        fat_files = FAT32Reader(image, boot).files()
        if "SHA256SUMS" not in fat_files:
            raise MediaError("FAT32 package has no SHA256SUMS")
        for line in fat_files["SHA256SUMS"].decode("utf-8").splitlines():
            digest, name = line.split("  ", 1)
            if name not in fat_files or sha256(fat_files[name]) != digest:
                raise MediaError(f"FAT32 package checksum mismatch: {name}")
        data_start = int(data["start_block"])
        primary = read_exact(
            image,
            data_start * SECTOR_SIZE,
            SECTOR_SIZE,
            "primary SwiftOS data superblock",
        )
        backup = read_exact(
            image,
            (data_start + 1) * SECTOR_SIZE,
            SECTOR_SIZE,
            "backup SwiftOS data superblock",
        )
        decoded: list[tuple[str, dict[str, int]]] = []
        for name, block in (("primary", primary), ("backup", backup)):
            try:
                decoded.append((
                    name,
                    decode_data_layout(block, int(data["block_count"])),
                ))
            except MediaError:
                pass
        if not decoded:
            raise MediaError("both SwiftOS data superblocks are invalid")
        if len(decoded) == 2 and decoded[0][1] != decoded[1][1]:
            raise MediaError("valid SwiftOS data superblocks disagree")
        layout = decoded[0][1]
        superblock_status = (
            "healthy" if len(decoded) == 2
            else f"degraded-{decoded[0][0]}-only"
        )
        records = persistent_records(image, data, layout)
        return {
            "format": "swiftos-rpi5-media-v1",
            "partitions": entries,
            "boot_files": {
                name: {"byte_count": len(value), "sha256": sha256(value)}
                for name, value in sorted(fat_files.items())
            },
            "data_volume": layout,
            "data_superblock_status": superblock_status,
            "persistent_records": records,
        }


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="build a new sparse media image")
    build.add_argument("package", type=Path)
    build.add_argument("output", type=Path)
    build.add_argument("--total-size-mib", type=int, default=DEFAULT_TOTAL_MIB)
    build.add_argument("--total-block-count", type=int)
    build.add_argument("--boot-size-mib", type=int, default=DEFAULT_BOOT_MIB)
    build.add_argument("--kernel-log-block-count", type=int,
                       default=DEFAULT_LOG_BLOCKS)
    inspect = commands.add_parser("inspect", help="validate and list image contents")
    inspect.add_argument("image", type=Path)
    return root


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "build":
            if arguments.total_block_count is not None:
                total_sectors = arguments.total_block_count
            else:
                total_sectors = arguments.total_size_mib * 2_048
            result = build_image(
                arguments.package,
                arguments.output,
                total_sectors=total_sectors,
                boot_sectors=arguments.boot_size_mib * 2_048,
                log_blocks=arguments.kernel_log_block_count,
            )
            result["image"] = str(arguments.output)
        else:
            result = inspect_image(arguments.image)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (MediaError, OSError, UnicodeError, ValueError, struct.error) as error:
        print(f"build-rpi5-media: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
