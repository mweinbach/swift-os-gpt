#!/usr/bin/env python3
"""Safely inspect SwiftOS persistent logs on an explicit Pi media source.

The source is always opened read-only. Regular image geometry comes from the
file itself; block/raw devices additionally require a caller-supplied expected
whole-device size. Inspection reads only the MBR, the two SwiftOS data-volume
superblocks, and the superblock-bounded persistent-log arena.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys
from typing import BinaryIO, Iterator

import build_rpi5_media as media


LOGICAL_BLOCK_BYTES = media.SECTOR_SIZE
MAXIMUM_SOURCE_BYTES = (1 << 63) - 1
LINUX_BLKGETSIZE64 = 0x8008_1272
DARWIN_DKIOCGETBLOCKSIZE = 0x4004_6418
DARWIN_DKIOCGETBLOCKCOUNT = 0x4008_6419


@dataclass(frozen=True)
class SourceGeometry:
    kind: str
    byte_count: int
    logical_block_count: int
    discovered_byte_count: int | None


class BoundedReadOnlyMedia:
    """Seekable reader that refuses unbounded or out-of-geometry reads."""

    def __init__(self, source: BinaryIO, byte_count: int) -> None:
        self._source = source
        self.byte_count = byte_count
        self._position = 0

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence == os.SEEK_SET:
            target = offset
        elif whence == os.SEEK_CUR:
            target = self._position + offset
        elif whence == os.SEEK_END:
            target = self.byte_count + offset
        else:
            raise media.MediaError("unsupported media seek mode")
        if not 0 <= target <= self.byte_count:
            raise media.MediaError("media seek exceeds expected whole-device extent")
        actual = self._source.seek(target, os.SEEK_SET)
        if actual != target:
            raise media.MediaError("media source did not honor an exact seek")
        self._position = target
        return target

    def read(self, byte_count: int = -1) -> bytes:
        if byte_count < 0:
            raise media.MediaError("unbounded media reads are forbidden")
        if byte_count > self.byte_count - self._position:
            raise media.MediaError("media read exceeds expected whole-device extent")
        data = self._source.read(byte_count)
        self._position += len(data)
        return data

    def tell(self) -> int:
        return self._position


def requested_byte_count(
    expected_byte_count: int | None,
    expected_block_count: int | None,
    *,
    required: bool,
) -> int | None:
    if expected_byte_count is not None and expected_block_count is not None:
        raise media.MediaError(
            "specify only one expected whole-device byte or block count"
        )
    if required and expected_byte_count is None and expected_block_count is None:
        raise media.MediaError(
            "non-regular media requires an expected whole-device byte or block count"
        )
    if expected_block_count is not None:
        if not 0 < expected_block_count <= MAXIMUM_SOURCE_BYTES // LOGICAL_BLOCK_BYTES:
            raise media.MediaError("expected whole-device block count is invalid")
        return expected_block_count * LOGICAL_BLOCK_BYTES
    if expected_byte_count is not None:
        if (
            not 0 < expected_byte_count <= MAXIMUM_SOURCE_BYTES
            or expected_byte_count % LOGICAL_BLOCK_BYTES
        ):
            raise media.MediaError(
                "expected whole-device byte count is not 512-byte aligned"
            )
        return expected_byte_count
    return None


def partition_device_reason(path: Path, status: os.stat_result) -> str | None:
    """Return a refusal reason when the node is discoverably a partition."""

    name = path.name
    if re.fullmatch(r"r?disk\d+s\d+(?:s\d+)*", name):
        return "macOS disk path names a partition, not a whole device"
    if re.fullmatch(
        r"(?:nvme\d+n\d+|mmcblk\d+|loop\d+|md\d+|dm-\d+)p\d+",
        name,
    ) or re.fullmatch(r"(?:sd|vd|xvd)[a-z]+\d+", name):
        return "Linux disk path names a partition, not a whole device"
    if sys.platform.startswith("linux") and stat.S_ISBLK(status.st_mode):
        partition_marker = Path(
            f"/sys/dev/block/{os.major(status.st_rdev)}:"
            f"{os.minor(status.st_rdev)}/partition"
        )
        if partition_marker.exists():
            return "Linux sysfs identifies the source as a partition"
    return None


def validate_nonregular_node(path: Path, status: os.stat_result) -> None:
    reason = partition_device_reason(path, status)
    if reason is not None:
        raise media.MediaError(reason)
    if not path.is_absolute():
        raise media.MediaError("non-regular media path must be absolute")
    if stat.S_ISCHR(status.st_mode):
        if sys.platform != "darwin" or not re.fullmatch(r"rdisk\d+", path.name):
            raise media.MediaError(
                "character source is not an unambiguous macOS whole raw disk"
            )
    elif sys.platform == "darwin" and not re.fullmatch(r"disk\d+", path.name):
        raise media.MediaError(
            "block source is not an unambiguous macOS whole disk"
        )


def discover_device_byte_count(
    descriptor: int,
    status: os.stat_result,
) -> int | None:
    """Query device geometry when the host exposes a read-only ioctl."""

    if status.st_size > 0:
        return status.st_size
    try:
        if sys.platform.startswith("linux") and stat.S_ISBLK(status.st_mode):
            result = bytearray(8)
            fcntl.ioctl(descriptor, LINUX_BLKGETSIZE64, result, True)
            return struct.unpack("=Q", result)[0]
        if sys.platform == "darwin":
            block_size = bytearray(4)
            block_count = bytearray(8)
            fcntl.ioctl(
                descriptor,
                DARWIN_DKIOCGETBLOCKSIZE,
                block_size,
                True,
            )
            fcntl.ioctl(
                descriptor,
                DARWIN_DKIOCGETBLOCKCOUNT,
                block_count,
                True,
            )
            return (
                struct.unpack("=I", block_size)[0]
                * struct.unpack("=Q", block_count)[0]
            )
    except OSError:
        return None
    return None


def same_opened_object(before: os.stat_result, after: os.stat_result) -> bool:
    if stat.S_IFMT(before.st_mode) != stat.S_IFMT(after.st_mode):
        return False
    if stat.S_ISREG(before.st_mode):
        return before.st_dev == after.st_dev and before.st_ino == after.st_ino
    return before.st_rdev == after.st_rdev


@contextmanager
def open_media_read_only(
    path: Path,
    *,
    expected_byte_count: int | None = None,
    expected_block_count: int | None = None,
) -> Iterator[tuple[BoundedReadOnlyMedia, SourceGeometry]]:
    before = os.lstat(path)
    if stat.S_ISLNK(before.st_mode):
        raise media.MediaError("media source symlinks are forbidden")
    regular = stat.S_ISREG(before.st_mode)
    device = stat.S_ISBLK(before.st_mode) or stat.S_ISCHR(before.st_mode)
    if not regular and not device:
        raise media.MediaError("media source is neither a regular image nor a disk")
    requested = requested_byte_count(
        expected_byte_count,
        expected_block_count,
        required=not regular,
    )
    if device:
        validate_nonregular_node(path, before)

    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    source: BinaryIO | None = None
    try:
        after = os.fstat(descriptor)
        if not same_opened_object(before, after):
            raise media.MediaError("media source changed while it was being opened")
        if regular:
            byte_count = after.st_size
            discovered = after.st_size
            kind = "regular-image"
            if requested is not None and requested != byte_count:
                raise media.MediaError(
                    "regular image extent differs from the expected whole-device size"
                )
        else:
            assert requested is not None
            byte_count = requested
            discovered = discover_device_byte_count(descriptor, after)
            kind = "raw-device" if stat.S_ISCHR(after.st_mode) else "block-device"
            if discovered is not None and discovered != byte_count:
                raise media.MediaError(
                    "device geometry differs from the expected whole-device size"
                )
        if (
            byte_count < LOGICAL_BLOCK_BYTES
            or byte_count % LOGICAL_BLOCK_BYTES
            or byte_count > MAXIMUM_SOURCE_BYTES
        ):
            raise media.MediaError(
                "media extent is not a supported whole number of logical blocks"
            )

        source = os.fdopen(descriptor, "rb", closefd=True)
        descriptor = -1
        geometry = SourceGeometry(
            kind=kind,
            byte_count=byte_count,
            logical_block_count=byte_count // LOGICAL_BLOCK_BYTES,
            discovered_byte_count=discovered,
        )
        yield BoundedReadOnlyMedia(source, byte_count), geometry
    finally:
        if source is not None:
            source.close()
        elif descriptor >= 0:
            os.close(descriptor)


def read_mbr_partitions(
    image: BoundedReadOnlyMedia,
    logical_block_count: int,
) -> tuple[list[dict[str, int | bool]], dict[str, int | bool]]:
    mbr = media.read_exact(image, 0, LOGICAL_BLOCK_BYTES, "MBR")
    if mbr[510:512] != b"\x55\xaa":
        raise media.MediaError("media has no valid MBR signature")
    entries: list[dict[str, int | bool]] = []
    for index in range(4):
        offset = 446 + index * 16
        status = mbr[offset]
        partition_type = mbr[offset + 4]
        start, count = struct.unpack_from("<II", mbr, offset + 8)
        if partition_type == 0:
            if status != 0 or start != 0 or count != 0:
                raise media.MediaError(f"malformed empty MBR partition {index + 1}")
            continue
        if (
            status not in (0, 0x80)
            or start == 0
            or count == 0
            or start >= logical_block_count
            or count > logical_block_count - start
        ):
            raise media.MediaError(f"invalid MBR partition {index + 1}")
        entries.append({
            "index": index + 1,
            "bootable": status == 0x80,
            "type": partition_type,
            "start_block": start,
            "block_count": count,
        })

    for position, left in enumerate(entries):
        left_start = int(left["start_block"])
        left_end = left_start + int(left["block_count"])
        for right in entries[position + 1:]:
            right_start = int(right["start_block"])
            right_end = right_start + int(right["block_count"])
            if left_start < right_end and right_start < left_end:
                raise media.MediaError("MBR partitions overlap")

    data_entries = [entry for entry in entries
                    if entry["type"] == media.SWIFTOS_DATA_TYPE]
    if len(data_entries) != 1:
        raise media.MediaError(
            "MBR must contain exactly one type-0xDA SwiftOS data partition"
        )
    data = data_entries[0]
    if data["bootable"] or int(data["block_count"]) <= 2:
        raise media.MediaError("SwiftOS data partition flags or extent are invalid")
    return entries, data


def inspect_stream(
    image: BoundedReadOnlyMedia,
    geometry: SourceGeometry,
    *,
    source_path: str,
) -> dict[str, object]:
    entries, data = read_mbr_partitions(image, geometry.logical_block_count)
    data_start = int(data["start_block"])
    data_count = int(data["block_count"])
    primary = media.read_exact(
        image,
        data_start * LOGICAL_BLOCK_BYTES,
        LOGICAL_BLOCK_BYTES,
        "primary SwiftOS data superblock",
    )
    backup = media.read_exact(
        image,
        (data_start + 1) * LOGICAL_BLOCK_BYTES,
        LOGICAL_BLOCK_BYTES,
        "backup SwiftOS data superblock",
    )
    decoded: list[tuple[str, dict[str, int]]] = []
    for name, block in (("primary", primary), ("backup", backup)):
        try:
            decoded.append((name, media.decode_data_layout(block, data_count)))
        except media.MediaError:
            pass
    if not decoded:
        raise media.MediaError("both SwiftOS data superblocks are invalid")
    if len(decoded) == 2 and decoded[0][1] != decoded[1][1]:
        raise media.MediaError("valid SwiftOS data superblocks disagree")
    layout = decoded[0][1]
    superblock_status = (
        "healthy" if len(decoded) == 2
        else f"degraded-{decoded[0][0]}-only"
    )

    log_start = int(layout["kernel_log_start_block"])
    log_count = int(layout["kernel_log_block_count"])
    log_end = log_start + log_count
    if (
        log_start < 2
        or log_count < 2
        or log_end > data_count
        or data_start + log_end > geometry.logical_block_count
        or log_count * LOGICAL_BLOCK_BYTES > media.MAX_LOG_BYTES
    ):
        raise media.MediaError("persistent log arena exceeds its bounded partition")

    records = media.persistent_records(image, data, layout)
    diagnostics = media.persistent_log_diagnostics(records)
    return {
        "format": "swiftos-persistent-log-capture-v1",
        "source": {
            "path": source_path,
            "kind": geometry.kind,
            "byte_count": geometry.byte_count,
            "logical_block_bytes": LOGICAL_BLOCK_BYTES,
            "logical_block_count": geometry.logical_block_count,
            "discovered_byte_count": geometry.discovered_byte_count,
        },
        "partitions": entries,
        "swiftos_data_partition": data,
        "data_volume": layout,
        "data_superblock_status": superblock_status,
        "persistent_record_count": len(records),
        "persistent_records": records,
        **diagnostics,
    }


def inspect_path(
    path: Path,
    *,
    expected_byte_count: int | None = None,
    expected_block_count: int | None = None,
) -> dict[str, object]:
    with open_media_read_only(
        path,
        expected_byte_count=expected_byte_count,
        expected_block_count=expected_block_count,
    ) as (image, geometry):
        return inspect_stream(image, geometry, source_path=str(path))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("source", type=Path)
    expected = result.add_mutually_exclusive_group()
    expected.add_argument("--expected-byte-count", type=int)
    expected.add_argument("--expected-block-count", type=int)
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        report = inspect_path(
            arguments.source,
            expected_byte_count=arguments.expected_byte_count,
            expected_block_count=arguments.expected_block_count,
        )
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    except (media.MediaError, OSError, ValueError, struct.error) as error:
        print(f"inspect-rpi5-persistent-log: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
