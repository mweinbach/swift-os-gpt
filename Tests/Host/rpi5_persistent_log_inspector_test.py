#!/usr/bin/env python3
from __future__ import annotations

from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
from unittest import mock
import zlib


REPOSITORY = Path(__file__).resolve().parents[2]
TOOLS = REPOSITORY / "tools"
INSPECTOR = TOOLS / "inspect_rpi5_persistent_log.py"
sys.path.insert(0, str(TOOLS))
import build_rpi5_media as media  # noqa: E402
import inspect_rpi5_persistent_log as inspector  # noqa: E402


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def partition_entry(partition_type: int, start: int, count: int) -> bytes:
    entry = bytearray(16)
    entry[4] = partition_type
    struct.pack_into("<II", entry, 8, start, count)
    return bytes(entry)


def valid_record(sequence: int, timestamp: int, payload: bytes) -> bytes:
    block = bytearray(512)
    block[:8] = media.LOG_MAGIC
    struct.pack_into("<HHIQQ", block, 8, 1, 40, len(payload), sequence, timestamp)
    struct.pack_into("<I", block, 32, zlib.crc32(payload) & 0xFFFF_FFFF)
    struct.pack_into("<I", block, 36, zlib.crc32(block[:36]) & 0xFFFF_FFFF)
    block[40:40 + len(payload)] = payload
    return bytes(block)


def fixture_bytes() -> bytearray:
    blocks = 64
    data_start = 16
    data_count = 32
    result = bytearray(blocks * 512)
    result[446:462] = partition_entry(0x0C, 1, 8)
    result[462:478] = partition_entry(media.SWIFTOS_DATA_TYPE,
                                      data_start, data_count)
    result[510:512] = b"\x55\xaa"
    superblock = media.data_superblock(data_count, 2)
    result[data_start * 512:(data_start + 1) * 512] = superblock
    result[(data_start + 1) * 512:(data_start + 2) * 512] = superblock
    payload = bytearray(48)
    struct.pack_into("<Q", payload, 0, 77)
    struct.pack_into("<Q", payload, 8, 1_234)
    payload[16] = 5
    struct.pack_into("<H", payload, 18, 6)
    struct.pack_into("<I", payload, 20, 0x1122_3344)
    result[(data_start + 2) * 512:(data_start + 3) * 512] = valid_record(
        1, 5_678, bytes(payload)
    )
    return result


class RecordingBytesIO(io.BytesIO):
    def __init__(self, data: bytes) -> None:
        super().__init__(data)
        self.read_extents: list[tuple[int, int]] = []

    def read(self, size: int = -1) -> bytes:
        start = self.tell()
        value = super().read(size)
        self.read_extents.append((start, len(value)))
        return value


def geometry(byte_count: int) -> inspector.SourceGeometry:
    return inspector.SourceGeometry(
        kind="regular-image",
        byte_count=byte_count,
        logical_block_count=byte_count // 512,
        discovered_byte_count=byte_count,
    )


def inspect_bytes(value: bytes) -> tuple[dict[str, object], RecordingBytesIO]:
    source = RecordingBytesIO(value)
    bounded = inspector.BoundedReadOnlyMedia(source, len(value))
    report = inspector.inspect_stream(
        bounded,
        geometry(len(value)),
        source_path="fixture.img",
    )
    return report, source


def expect_media_error(action, text: str) -> None:
    try:
        action()
    except media.MediaError as error:
        require(text in str(error), f"unexpected refusal: {error}")
    else:
        raise AssertionError(f"expected media refusal containing: {text}")


def test_valid_capture_is_partition_bounded() -> None:
    value = fixture_bytes()
    report, source = inspect_bytes(value)
    require(report["persistent_record_count"] == 1, "record count changed")
    record = report["persistent_records"][0]
    require(record["sequence"] == 1, "persistent sequence changed")
    require(record["kernel_log_sequence"] == 77, "kernel sequence changed")
    require(record["kernel_log_event_code"] == 0x1122_3344,
            "kernel event code changed")
    expected_reads = {
        (0, 512),
        (16 * 512, 512),
        (17 * 512, 512),
        (18 * 512, 512),
        (19 * 512, 512),
    }
    require(set(source.read_extents) == expected_reads,
            f"inspector read outside MBR/superblock/log extents: {source.read_extents}")
    require(not any(512 <= start < 9 * 512 for start, _ in source.read_extents),
            "inspector scanned unrelated FAT32 content")


def test_mbr_and_partition_refusals() -> None:
    missing = fixture_bytes()
    missing[510:512] = b"\0\0"
    expect_media_error(lambda: inspect_bytes(missing), "MBR signature")

    duplicate = fixture_bytes()
    duplicate[478:494] = partition_entry(media.SWIFTOS_DATA_TYPE, 49, 8)
    expect_media_error(lambda: inspect_bytes(duplicate), "exactly one type-0xDA")

    overlap = fixture_bytes()
    overlap[446:462] = partition_entry(0x0C, 1, 20)
    expect_media_error(lambda: inspect_bytes(overlap), "partitions overlap")

    outside = fixture_bytes()
    outside[462:478] = partition_entry(media.SWIFTOS_DATA_TYPE, 60, 32)
    expect_media_error(lambda: inspect_bytes(outside), "invalid MBR partition")


def test_superblocks_are_both_signed_and_identical() -> None:
    corrupt = fixture_bytes()
    corrupt[17 * 512] ^= 0xFF
    expect_media_error(lambda: inspect_bytes(corrupt), "backup SwiftOS data superblock")

    disagreeing = fixture_bytes()
    different = media.data_superblock(32, 3)
    disagreeing[17 * 512:18 * 512] = different
    expect_media_error(lambda: inspect_bytes(disagreeing), "are not duplicates")


def test_unbounded_log_layout_is_rejected_before_arena_scan() -> None:
    value = fixture_bytes()
    block = bytearray(value[16 * 512:17 * 512])
    struct.pack_into("<Q", block, 32, media.MAX_LOG_BLOCKS + 1)
    struct.pack_into("<Q", block, 40, media.MAX_LOG_BLOCKS + 3)
    struct.pack_into("<Q", block, 48, 1)
    struct.pack_into("<I", block, 60, zlib.crc32(block[:60]) & 0xFFFF_FFFF)
    value[16 * 512:17 * 512] = block
    value[17 * 512:18 * 512] = block
    source = RecordingBytesIO(value)
    bounded = inspector.BoundedReadOnlyMedia(source, len(value))
    expect_media_error(
        lambda: inspector.inspect_stream(
            bounded,
            geometry(len(value)),
            source_path="unbounded.img",
        ),
        "superblock fields",
    )
    require(len(source.read_extents) == 3,
            "invalid layout caused a persistent-arena scan")


def test_source_open_is_read_only_and_refuses_symlinks() -> None:
    with tempfile.TemporaryDirectory(prefix="swiftos-log-inspector-") as temporary:
        root = Path(temporary)
        image = root / "media.img"
        image.write_bytes(fixture_bytes())
        observed_flags: list[int] = []
        real_open = os.open

        def open_spy(path, flags, *args, **kwargs):
            observed_flags.append(flags)
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(inspector.os, "open", side_effect=open_spy):
            result = inspector.inspect_path(image)
        require(result["persistent_record_count"] == 1,
                "read-only path inspection failed")
        require(len(observed_flags) == 1, "source was opened more than once")
        require(observed_flags[0] & os.O_ACCMODE == os.O_RDONLY,
                "source was not opened O_RDONLY")

        link = root / "media-link.img"
        link.symlink_to(image)
        expect_media_error(
            lambda: inspector.inspect_path(link),
            "symlinks are forbidden",
        )


def test_geometry_and_whole_device_contracts() -> None:
    expect_media_error(
        lambda: inspector.requested_byte_count(None, None, required=True),
        "requires an expected whole-device",
    )
    expect_media_error(
        lambda: inspector.requested_byte_count(512, 1, required=True),
        "only one",
    )
    expect_media_error(
        lambda: inspector.requested_byte_count(513, None, required=True),
        "not 512-byte aligned",
    )
    fake_block = os.stat_result((stat.S_IFBLK, 0, 0, 1, 0, 0, 0, 0, 0, 0))
    reason = inspector.partition_device_reason(Path("/dev/rdisk7s1"), fake_block)
    require(reason is not None and "partition" in reason,
            "macOS partition node was not rejected")
    reason = inspector.partition_device_reason(Path("/dev/nvme0n1p2"), fake_block)
    require(reason is not None and "partition" in reason,
            "Linux partition node was not rejected")


def test_cli_outputs_json_for_explicit_regular_image() -> None:
    with tempfile.TemporaryDirectory(prefix="swiftos-log-cli-") as temporary:
        image = Path(temporary) / "explicit.img"
        image.write_bytes(fixture_bytes())
        result = subprocess.run(
            [sys.executable, str(INSPECTOR), str(image)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        require(result.returncode == 0, f"CLI failed: {result.stdout}")
        report = json.loads(result.stdout)
        require(report["source"]["path"] == str(image),
                "CLI did not preserve the explicit source path")
        require(report["superblocks"] == "healthy-identical",
                "CLI did not validate duplicate signed superblocks")


def main() -> int:
    tests = [
        test_valid_capture_is_partition_bounded,
        test_mbr_and_partition_refusals,
        test_superblocks_are_both_signed_and_identical,
        test_unbounded_log_layout_is_rejected_before_arena_scan,
        test_source_open_is_read_only_and_refuses_symlinks,
        test_geometry_and_whole_device_contracts,
        test_cli_outputs_json_for_explicit_regular_image,
    ]
    for test in tests:
        test()
    print(f"Raspberry Pi 5 persistent log inspector: {len(tests)} groups passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
