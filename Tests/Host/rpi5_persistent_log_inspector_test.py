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


def kernel_log_payload(
    sequence: int,
    *,
    timestamp: int,
    level: int,
    subsystem: int,
    event_code: int,
    processor_id: int = 0,
    flags: int = 0,
    argument0: int = 0,
    argument1: int = 0,
) -> bytes:
    return struct.pack(
        "<QQBBHIIIQQ",
        sequence,
        timestamp,
        level,
        0,
        subsystem,
        event_code,
        processor_id,
        flags,
        argument0,
        argument1,
    )


def console_payload(
    sequence: int,
    data: bytes,
    *,
    is_first: bool,
    is_last: bool,
    source: int = 1,
    timestamp: int = 1_000,
    processor_id: int = 0,
) -> bytes:
    require(0 < len(data) <= 16, "console fixture chunk is out of range")
    padded = data.ljust(16, b"\0")
    argument0, argument1 = struct.unpack("<QQ", padded)
    flags = len(data) | source << 16
    if is_first:
        flags |= 1 << 8
    if is_last:
        flags |= 1 << 9
    return kernel_log_payload(
        sequence,
        timestamp=timestamp,
        level=2,
        subsystem=1,
        event_code=media.KERNEL_CONSOLE_EVENT_CODE,
        processor_id=processor_id,
        flags=flags,
        argument0=argument0,
        argument1=argument1,
    )


def blank_fixture_bytes(log_blocks: int) -> tuple[bytearray, int]:
    blocks = 64
    data_start = 16
    data_count = 32
    result = bytearray(blocks * 512)
    result[446:462] = partition_entry(0x0C, 1, 8)
    result[462:478] = partition_entry(media.SWIFTOS_DATA_TYPE,
                                      data_start, data_count)
    result[510:512] = b"\x55\xaa"
    superblock = media.data_superblock(data_count, log_blocks)
    result[data_start * 512:(data_start + 1) * 512] = superblock
    result[(data_start + 1) * 512:(data_start + 2) * 512] = superblock
    return result, data_start


def install_record(
    fixture: bytearray,
    data_start: int,
    log_blocks: int,
    sequence: int,
    payload: bytes,
) -> None:
    slot = (sequence - 1) % log_blocks
    start = (data_start + 2 + slot) * 512
    fixture[start:start + 512] = valid_record(
        sequence,
        5_000 + sequence,
        payload,
    )


def fixture_bytes() -> bytearray:
    result, data_start = blank_fixture_bytes(2)
    install_record(
        result,
        data_start,
        2,
        1,
        kernel_log_payload(
            77,
            timestamp=1_234,
            level=5,
            subsystem=6,
            event_code=0x1122_3344,
            processor_id=0x300,
            flags=0x5566_7788,
            argument0=0x0102_0304_0506_0708,
            argument1=0x1112_1314_1516_1718,
        ),
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
    event = record["kernel_log_event"]
    require(event == {
        "sequence": 77,
        "timestamp_ticks": 1_234,
        "level": 5,
        "level_name": "error",
        "reserved": 0,
        "subsystem": 6,
        "subsystem_name": "drivers",
        "event_code": 0x1122_3344,
        "event_code_hex": "0x11223344",
        "event_code_tag": None,
        "processor_id": 0x300,
        "flags": 0x5566_7788,
        "argument0": 0x0102_0304_0506_0708,
        "argument1": 0x1112_1314_1516_1718,
        "codec_valid": True,
    }, "complete kernel event decode changed")
    require("console_chunk" not in record,
            "non-CONS event was decoded as canonical console data")
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


def test_console_chunks_reconstruct_split_crlf_marker() -> None:
    value, data_start = blank_fixture_bytes(4)
    chunks = [
        (b"SWIFTOS:SD_INIT_", True, False),
        (b"READY\r", False, False),
        (b"\n", False, True),
    ]
    for index, (chunk, is_first, is_last) in enumerate(chunks, start=1):
        install_record(
            value,
            data_start,
            4,
            index,
            console_payload(
                index,
                chunk,
                is_first=is_first,
                is_last=is_last,
                processor_id=0x300,
            ),
        )

    report, source = inspect_bytes(value)
    require(report["persistent_record_count"] == 3,
            "split console record count changed")
    first = report["persistent_records"][0]
    require(first["kernel_log_event"]["event_code_tag"] == "CONS",
            "CONS four-character tag was not decoded")
    require(first["console_chunk"] == {
        "source": 1,
        "source_name": "early-console",
        "is_first": True,
        "is_last": False,
        "byte_count": 16,
        "bytes_hex": b"SWIFTOS:SD_INIT_".hex(),
        "text": "SWIFTOS:SD_INIT_",
        "utf8_valid": True,
    }, "first console chunk fields changed")
    stream = report["canonical_console_stream"]
    expected = b"SWIFTOS:SD_INIT_READY\r\n"
    require(stream["ordering"] == "persistent-sequence",
            "console ordering contract changed")
    require(stream["bytes_hex"] == expected.hex(),
            "canonical console bytes were not reconstructed")
    require(stream["text"] == "SWIFTOS:SD_INIT_READY\r\n",
            "split CRLF marker text was not reconstructed")
    require(stream["chunk_count"] == 3 and stream["byte_count"] == len(expected),
            "canonical console extent changed")
    require(stream["complete_message_count"] == 1,
            "split console message was not completed")
    require(stream["message_boundary_issue_count"] == 0,
            "valid console boundaries were rejected")
    require(stream["is_complete"], "gap-free console stream marked incomplete")
    persistent = report["sequence_metadata"]["persistent_record"]
    kernel = report["sequence_metadata"]["kernel_log"]
    require(persistent["epoch_count"] == 1 and not persistent["has_gaps"],
            "contiguous persistent records reported a gap")
    require(kernel["epoch_count"] == 1 and not kernel["has_gaps"],
            "contiguous kernel records reported a gap")
    expected_log_reads = {
        ((data_start + 2 + slot) * 512, 512) for slot in range(4)
    }
    require(expected_log_reads.issubset(set(source.read_extents)),
            "console reconstruction read outside the pre-scanned arena")


def test_sequence_gaps_and_kernel_epochs_are_explicit() -> None:
    value, data_start = blank_fixture_bytes(6)
    records = [
        (2, 5, b"A"),
        (4, 7, b"B"),
        (5, 1, b"C"),
    ]
    for persistent_sequence, kernel_sequence, chunk in records:
        install_record(
            value,
            data_start,
            6,
            persistent_sequence,
            console_payload(
                kernel_sequence,
                chunk,
                is_first=True,
                is_last=True,
            ),
        )

    report, _ = inspect_bytes(value)
    persistent = report["sequence_metadata"]["persistent_record"]
    require(persistent["record_count"] == 3,
            "persistent sequence record count changed")
    require(persistent["missing_prefix_count"] == 1,
            "persistent overwritten prefix was not reported")
    require(persistent["missing_between_count"] == 1,
            "persistent interior gap was not reported")
    require(persistent["gaps"] == [{
        "epoch_index": 0,
        "previous_persistent_sequence": 2,
        "next_persistent_sequence": 4,
        "previous_sequence": 2,
        "next_sequence": 4,
        "missing_count": 1,
    }], "persistent gap coordinates changed")

    kernel = report["sequence_metadata"]["kernel_log"]
    require(kernel["epoch_count"] == 2 and kernel["reset_count"] == 1,
            "kernel sequence reboot epoch was not retained")
    require(kernel["missing_prefix_count"] == 4,
            "kernel epoch prefix loss was not reported")
    require(kernel["missing_between_count"] == 1,
            "kernel epoch interior loss was not reported")
    require(kernel["resets"] == [{
        "previous_persistent_sequence": 4,
        "next_persistent_sequence": 5,
        "previous_sequence": 7,
        "next_sequence": 1,
    }], "kernel reset coordinates changed")
    stream = report["canonical_console_stream"]
    require(stream["text"] == "ABC", "ordered retained console bytes changed")
    require(stream["complete_message_count"] == 3,
            "single-chunk messages were not counted")
    require(stream["has_sequence_gaps"] and stream["crosses_kernel_epochs"],
            "console loss/epoch status was not surfaced")
    require(not stream["is_complete"],
            "lossy retained console stream was called complete")


def test_kernel_epoch_boundary_is_not_one_complete_stream() -> None:
    value, data_start = blank_fixture_bytes(2)
    for persistent_sequence, chunk in ((1, b"A"), (2, b"B")):
        install_record(
            value,
            data_start,
            2,
            persistent_sequence,
            console_payload(
                1,
                chunk,
                is_first=True,
                is_last=True,
            ),
        )

    report, _ = inspect_bytes(value)
    persistent = report["sequence_metadata"]["persistent_record"]
    kernel = report["sequence_metadata"]["kernel_log"]
    stream = report["canonical_console_stream"]
    require(not persistent["has_gaps"] and not kernel["has_gaps"],
            "epoch-only fixture unexpectedly contains sequence loss")
    require(kernel["epoch_count"] == 2,
            "kernel sequence reset did not create two epochs")
    require(stream["text"] == "AB" and stream["crosses_kernel_epochs"],
            "epoch-spanning retained bytes were not exposed")
    require(not stream["is_complete"],
            "multiple kernel epochs were called one complete console stream")


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


def test_single_valid_superblock_recovers_both_sides() -> None:
    corrupt_backup = fixture_bytes()
    corrupt_backup[17 * 512] ^= 0xFF
    recovered, _ = inspect_bytes(corrupt_backup)
    require(recovered["data_superblock_status"] == "degraded-primary-only",
            "valid primary superblock did not authorize recovery")
    require(recovered["persistent_record_count"] == 1,
            "primary-only recovery did not read the bounded log")

    corrupt_primary = fixture_bytes()
    corrupt_primary[16 * 512] ^= 0xFF
    recovered, _ = inspect_bytes(corrupt_primary)
    require(recovered["data_superblock_status"] == "degraded-backup-only",
            "valid backup superblock did not authorize recovery")
    require(recovered["persistent_record_count"] == 1,
            "backup-only recovery did not read the bounded log")

    corrupt_both = fixture_bytes()
    corrupt_both[16 * 512] ^= 0xFF
    corrupt_both[17 * 512] ^= 0xFF
    expect_media_error(lambda: inspect_bytes(corrupt_both),
                       "both SwiftOS data superblocks are invalid")

    padding_differs = fixture_bytes()
    padding_differs[17 * 512 + 100] ^= 0xFF
    recovered, _ = inspect_bytes(padding_differs)
    require(recovered["data_superblock_status"] == "healthy",
            "matching decoded layouts were compared as raw blocks")


def test_valid_superblock_disagreement_is_rejected() -> None:
    disagreeing = fixture_bytes()
    different = media.data_superblock(32, 3)
    disagreeing[17 * 512:18 * 512] = different
    expect_media_error(lambda: inspect_bytes(disagreeing), "superblocks disagree")


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
        "both SwiftOS data superblocks are invalid",
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
        require(report["data_superblock_status"] == "healthy",
                "CLI did not validate duplicate signed superblocks")


def main() -> int:
    tests = [
        test_valid_capture_is_partition_bounded,
        test_console_chunks_reconstruct_split_crlf_marker,
        test_sequence_gaps_and_kernel_epochs_are_explicit,
        test_kernel_epoch_boundary_is_not_one_complete_stream,
        test_mbr_and_partition_refusals,
        test_single_valid_superblock_recovers_both_sides,
        test_valid_superblock_disagreement_is_rejected,
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
