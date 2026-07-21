#!/usr/bin/env python3
"""Semantically verify the signed SwiftOS Raspberry Pi 5 boot payload.

The source is always opened read-only. By default it must be a whole-media
image or an unambiguous whole-disk device with an MBR. ``--partition-image``
accepts a regular-file capture of only the FAT32 partition. The verifier reads
SHA256SUMS and follows only paths named by that manifest; unrelated host
metadata is neither rejected nor recursively traversed.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import struct
import sys

import build_rpi5_media as media
import inspect_rpi5_persistent_log as source_io


def read_mbr_boot_partitions(
    image: source_io.BoundedReadOnlyMedia,
    logical_block_count: int,
) -> tuple[
    list[dict[str, int | bool]],
    dict[str, dict[str, int | bool]],
    dict[str, int | bool] | None,
]:
    mbr = media.read_exact(image, 0, media.SECTOR_SIZE, "MBR")
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
                raise media.MediaError(
                    f"malformed empty MBR partition {index + 1}"
                )
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

    version, layout = media.classify_media_layout(entries)
    if version == "v1":
        return entries, {"A": layout["boot"]}, None
    selector = layout["selector"]
    media.FAT12SelectorVolume.read_autoboot(image, selector)
    return entries, {
        "A": layout["slot_a"],
        "B": layout["slot_b"],
    }, selector


def verify_stream(
    image: source_io.BoundedReadOnlyMedia,
    geometry: source_io.SourceGeometry,
    *,
    source_path: str,
    partition_image: bool,
    expected_manifest: bytes | None,
    selected_slot: str,
) -> dict[str, object]:
    if partition_image:
        if geometry.kind != "regular-image":
            raise media.MediaError(
                "--partition-image accepts only a regular-file partition capture"
            )
        entries: list[dict[str, int | bool]] = []
        if selected_slot == "both":
            raise media.MediaError(
                "--partition-image requires --slot a or --slot b"
            )
        slots: dict[str, dict[str, int | bool]] = {
            selected_slot.upper(): {
                "index": 1,
                "bootable": True,
                "type": media.FAT32_LBA_TYPE,
                "start_block": 0,
                "block_count": geometry.logical_block_count,
            }
        }
        selector = None
        validate_hidden_sectors = False
    else:
        entries, slots, selector = read_mbr_boot_partitions(
            image,
            geometry.logical_block_count,
        )
        validate_hidden_sectors = True

    requested = (
        sorted(slots)
        if selected_slot == "both"
        else [selected_slot.upper()]
    )
    if any(slot not in slots for slot in requested):
        raise media.MediaError("requested boot slot is not present on this media")
    slot_results: dict[str, dict[str, object]] = {}
    for slot in requested:
        slot_results[slot] = media.verify_fat32_boot_manifest(
            image,
            slots[slot],
            validate_hidden_sectors=validate_hidden_sectors,
            expected_manifest=expected_manifest,
        )
        slot_results[slot]["partition"] = slots[slot]
    if len(slot_results) == 2 and (
        slot_results["A"]["manifest"]["sha256"]
        != slot_results["B"]["manifest"]["sha256"]
    ):
        raise media.MediaError("A/B boot-slot manifests disagree")

    primary_slot = requested[0]
    result = dict(slot_results[primary_slot])
    result["format"] = "swiftos-rpi5-boot-verification-v2"
    result["selected_slots"] = requested
    result["boot_slots"] = slot_results
    result["source"] = {
        "path": source_path,
        "kind": geometry.kind,
        "byte_count": geometry.byte_count,
        "logical_block_bytes": media.SECTOR_SIZE,
        "logical_block_count": geometry.logical_block_count,
        "discovered_byte_count": geometry.discovered_byte_count,
        "layout": "fat32-partition-image" if partition_image else "whole-media",
    }
    result["partitions"] = entries
    result["boot_partition"] = slots[primary_slot]
    if selector is not None:
        result["selector_partition"] = selector
    return result


def read_expected_manifest(path: Path) -> bytes:
    before = os.lstat(path)
    if stat.S_ISLNK(before.st_mode):
        raise media.MediaError("expected SHA256SUMS symlinks are forbidden")
    if not stat.S_ISREG(before.st_mode):
        raise media.MediaError("expected SHA256SUMS must be a regular file")
    if before.st_size > media.MAXIMUM_BOOT_MANIFEST_BYTES:
        raise media.MediaError("expected SHA256SUMS is too large")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(
        os,
        "O_NOFOLLOW",
        0,
    )
    descriptor = os.open(path, flags)
    try:
        after = os.fstat(descriptor)
        if not source_io.same_opened_object(before, after):
            raise media.MediaError(
                "expected SHA256SUMS changed while it was being opened"
            )
        if (
            not stat.S_ISREG(after.st_mode)
            or after.st_size > media.MAXIMUM_BOOT_MANIFEST_BYTES
        ):
            raise media.MediaError("expected SHA256SUMS extent is invalid")
        chunks: list[bytes] = []
        remaining = after.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 64 * 1_024))
            if not chunk:
                raise media.MediaError(
                    "expected SHA256SUMS changed while being read"
                )
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def verify_path(
    path: Path,
    *,
    expected_byte_count: int | None = None,
    expected_block_count: int | None = None,
    partition_image: bool = False,
    expected_manifest_path: Path | None = None,
    selected_slot: str = "both",
) -> dict[str, object]:
    expected_manifest: bytes | None = None
    if expected_manifest_path is not None:
        expected_manifest = read_expected_manifest(expected_manifest_path)
    with source_io.open_media_read_only(
        path,
        expected_byte_count=expected_byte_count,
        expected_block_count=expected_block_count,
    ) as (image, geometry):
        return verify_stream(
            image,
            geometry,
            source_path=str(path),
            partition_image=partition_image,
            expected_manifest=expected_manifest,
            selected_slot=selected_slot,
        )


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("source", type=Path)
    extent = root.add_mutually_exclusive_group()
    extent.add_argument("--expected-byte-count", type=int)
    extent.add_argument("--expected-block-count", type=int)
    root.add_argument(
        "--partition-image",
        action="store_true",
        help="treat a regular file as a raw FAT32 partition capture",
    )
    root.add_argument(
        "--expected-sha256sums",
        type=Path,
        help="also require byte equality with a trusted SHA256SUMS copy",
    )
    root.add_argument(
        "--slot",
        choices=("a", "b", "both"),
        default="both",
        help="verify slot A, slot B, or both A/B payloads",
    )
    return root


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        result = verify_path(
            arguments.source,
            expected_byte_count=arguments.expected_byte_count,
            expected_block_count=arguments.expected_block_count,
            partition_image=arguments.partition_image,
            expected_manifest_path=arguments.expected_sha256sums,
            selected_slot=arguments.slot,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (media.MediaError, OSError, ValueError, struct.error) as error:
        print(f"verify-rpi5-boot-partition: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
