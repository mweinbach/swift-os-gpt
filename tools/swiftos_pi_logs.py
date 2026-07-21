#!/usr/bin/env python3
"""Pull SwiftOS Raspberry Pi logs from returned media or a live USB link.

Returned-card inspection is deliberately read-only.  On macOS the tool takes a
fresh ``diskutil list external physical`` snapshot, admits only one removable
whole disk with the SwiftOS boot/data partition sentinels, verifies its exact
geometry with ``diskutil info``, and then delegates bounded parsing to the
persistent-log inspector.  It never mounts, unmounts, writes, partitions, or
ejects media.

Live inspection delegates the versioned CDC/SDBG exchange to ``swiftosctl`` so
there is only one implementation of tty setup, SwiftOS USB identity matching,
framing, and console reconstruction.  This wrapper adds repeatable capture and
developer-friendly output without opening the tty a second time.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from contextlib import contextmanager
from dataclasses import dataclass
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import stat
import sys
import time
from typing import Any, BinaryIO, Callable, Iterator, Mapping, Sequence, TextIO

import build_rpi5_media as media
import inspect_rpi5_persistent_log as persistent


REPOSITORY = Path(__file__).resolve().parents[1]
DEFAULT_SWIFTOSCTL = REPOSITORY / ".build" / "swiftosctl"
DISKUTIL = Path("/usr/sbin/diskutil")
MAXIMUM_DISKUTIL_OUTPUT_BYTES = 8 * 1024 * 1024
MAXIMUM_LIVE_REPORT_BYTES = 32 * 1024 * 1024
MAXIMUM_SAVED_CAPTURE_BYTES = 64 * 1024 * 1024
LOGICAL_BLOCK_BYTES = 512
MAXIMUM_SEQUENCE = (1 << 64) - 1
MAXIMUM_CONSOLE_CHUNK_BYTES = 16
LIVE_DEVICE_PATTERN = re.compile(r"/dev/cu\.usbmodem[A-Za-z0-9._-]+")


class PiLogToolError(Exception):
    """A refusal or operational failure safe to present to an operator."""


@dataclass(frozen=True)
class CardCandidate:
    identifier: str
    device_path: Path
    raw_device_path: Path
    byte_count: int
    logical_block_bytes: int
    media_name: str
    protocol: str

    @property
    def logical_block_count(self) -> int:
        return self.byte_count // self.logical_block_bytes


CommandRunner = Callable[[Sequence[str]], subprocess.CompletedProcess[bytes]]


def run_bytes(arguments: Sequence[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        list(arguments),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def _run_plist(
    arguments: Sequence[str],
    *,
    runner: CommandRunner,
) -> Mapping[str, Any]:
    try:
        completed = runner(arguments)
    except OSError as error:
        raise PiLogToolError(
            f"could not execute {arguments[0]}: {error}"
        ) from error
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        if not detail:
            detail = f"exit status {completed.returncode}"
        raise PiLogToolError(f"{' '.join(arguments)} failed: {detail}")
    if len(completed.stdout) > MAXIMUM_DISKUTIL_OUTPUT_BYTES:
        raise PiLogToolError("diskutil returned an unexpectedly large report")
    try:
        value = plistlib.loads(completed.stdout)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise PiLogToolError("diskutil returned an invalid property list") from error
    if not isinstance(value, dict):
        raise PiLogToolError("diskutil property-list root is not a dictionary")
    return value


def _whole_identifier(requested_path: str) -> str:
    match = re.fullmatch(r"/dev/(?:r)?(disk[0-9]+)", requested_path)
    if match is None:
        raise PiLogToolError(
            "card device must be an explicit macOS whole disk such as "
            "/dev/disk4 or /dev/rdisk4"
        )
    return match.group(1)


def _content_key(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return re.sub(r"[^a-z0-9]", "", value.lower())


def _has_swiftos_partition_sentinels(record: Mapping[str, Any]) -> bool:
    if _content_key(record.get("Content")) not in {
        "fdiskpartitionscheme",
        "masterbootrecord",
    }:
        return False
    partitions = record.get("Partitions")
    if not isinstance(partitions, list):
        return False
    has_legacy_boot = False
    has_selector = False
    has_slot_a = False
    has_slot_b = False
    canonical_ab_slot_count = 0
    has_data = False
    for partition in partitions:
        if not isinstance(partition, dict):
            continue
        content = _content_key(partition.get("Content"))
        volume = partition.get("VolumeName")
        if volume == "SWIFTOS" and content in {
            "dosfat32",
            "windowsfat32",
            "0c",
            "c",
        }:
            has_legacy_boot = True
        if volume == "SWIFTOS-CTL" and content in {
            "dosfat12",
            "windowsfat12",
            "01",
            "1",
        }:
            has_selector = True
        if volume == "SWIFTOS-A" and content in {
            "dosfat32",
            "windowsfat32",
            "0c",
            "c",
        }:
            has_slot_a = True
        if volume == "SWIFTOS-B" and content in {
            "dosfat32",
            "windowsfat32",
            "0c",
            "c",
        }:
            has_slot_b = True
        if volume == "SWIFTOS-AB" and content in {
            "dosfat32",
            "windowsfat32",
            "0c",
            "c",
        }:
            canonical_ab_slot_count += 1
        if content in {"da", "0xda"}:
            has_data = True
    has_ab_boot = has_selector and (
        (has_slot_a and has_slot_b) or canonical_ab_slot_count == 2
    )
    return has_data and (has_legacy_boot or has_ab_boot)


def _require_bool(
    info: Mapping[str, Any],
    key: str,
    expected: bool,
    *,
    identifier: str,
) -> None:
    value = info.get(key)
    if value is not expected:
        expectation = "true" if expected else "false"
        raise PiLogToolError(
            f"{identifier} is not eligible: diskutil {key} must be {expectation}"
        )


def _require_bool_alias(
    info: Mapping[str, Any],
    keys: tuple[str, ...],
    expected: bool,
    *,
    identifier: str,
) -> None:
    present = [(key, info[key]) for key in keys if key in info]
    if not present or any(value is not expected for _, value in present):
        expectation = "true" if expected else "false"
        names = "/".join(keys)
        raise PiLogToolError(
            f"{identifier} is not eligible: diskutil {names} must be {expectation}"
        )


def _require_string_if_present(
    info: Mapping[str, Any],
    key: str,
    expected: str,
    *,
    identifier: str,
) -> None:
    value = info.get(key)
    if value is not None and (
        not isinstance(value, str) or value.lower() != expected.lower()
    ):
        raise PiLogToolError(
            f"{identifier} is not eligible: diskutil {key} is {value!r}"
        )


def _positive_integer(value: object, description: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise PiLogToolError(f"diskutil {description} is missing or invalid")
    return value


def _validate_candidate(
    identifier: str,
    record: Mapping[str, Any],
    info: Mapping[str, Any],
) -> CardCandidate:
    if record.get("DeviceIdentifier") != identifier:
        raise PiLogToolError(f"diskutil list record changed for {identifier}")
    if info.get("DeviceIdentifier") != identifier:
        raise PiLogToolError(f"diskutil info returned a different device identifier")
    # `diskutil info -plist` calls this field WholeDisk on current macOS and
    # Whole on older releases. If both are ever present, both must agree.
    _require_bool_alias(
        info,
        ("WholeDisk", "Whole"),
        True,
        identifier=identifier,
    )
    _require_bool(info, "Internal", False, identifier=identifier)
    _require_bool(info, "RemovableMedia", True, identifier=identifier)
    _require_string_if_present(
        info,
        "VirtualOrPhysical",
        "Physical",
        identifier=identifier,
    )
    _require_string_if_present(
        info,
        "DeviceLocation",
        "External",
        identifier=identifier,
    )

    block_bytes = _positive_integer(
        info.get("DeviceBlockSize"),
        "logical block size",
    )
    if block_bytes != LOGICAL_BLOCK_BYTES:
        raise PiLogToolError(
            f"{identifier} has unsupported {block_bytes}-byte logical blocks"
        )
    listed_size = _positive_integer(record.get("Size"), "listed whole-disk size")
    info_size_value = info.get("TotalSize", info.get("DiskSize"))
    info_size = _positive_integer(info_size_value, "whole-disk size")
    if listed_size != info_size:
        raise PiLogToolError(
            f"{identifier} geometry changed between diskutil list and info"
        )
    if info_size % block_bytes:
        raise PiLogToolError(f"{identifier} size is not block aligned")
    if not _has_swiftos_partition_sentinels(record):
        raise PiLogToolError(
            f"{identifier} does not have the SWIFTOS FAT32 plus type-0xDA "
            "layout or A/B v2 layout"
        )
    partitions = record.get("Partitions")
    assert isinstance(partitions, list)
    mounted = [
        partition.get("MountPoint")
        for partition in partitions
        if isinstance(partition, dict)
        and isinstance(partition.get("MountPoint"), str)
        and partition.get("MountPoint")
    ]
    if mounted:
        locations = ", ".join(str(value) for value in mounted)
        raise PiLogToolError(
            f"{identifier} has mounted child partitions ({locations}); run "
            f"`diskutil unmountDisk /dev/{identifier}` yourself and rerun so the "
            "read-only capture cannot overlap filesystem metadata changes"
        )

    expected_node = f"/dev/{identifier}"
    device_node = info.get("DeviceNode", expected_node)
    if device_node != expected_node:
        raise PiLogToolError(
            f"{identifier} diskutil device node does not match {expected_node}"
        )
    media_name = info.get("MediaName")
    protocol = info.get("BusProtocol")
    return CardCandidate(
        identifier=identifier,
        device_path=Path(expected_node),
        raw_device_path=Path(f"/dev/r{identifier}"),
        byte_count=info_size,
        logical_block_bytes=block_bytes,
        media_name=media_name if isinstance(media_name, str) else "unknown media",
        protocol=protocol if isinstance(protocol, str) else "unknown protocol",
    )


def discover_swiftos_card(
    requested_device: str | None = None,
    *,
    runner: CommandRunner = run_bytes,
    diskutil: Path = DISKUTIL,
) -> CardCandidate:
    """Resolve one card from a new external-physical diskutil snapshot."""

    if sys.platform != "darwin":
        raise PiLogToolError(
            "automatic card discovery requires macOS diskutil; use --image for "
            "a regular media image"
        )
    requested_identifier = (
        _whole_identifier(requested_device) if requested_device is not None else None
    )
    executable = str(diskutil)
    listing = _run_plist(
        [executable, "list", "-plist", "external", "physical"],
        runner=runner,
    )
    raw_whole = listing.get("WholeDisks")
    raw_records = listing.get("AllDisksAndPartitions")
    if not isinstance(raw_whole, list) or not isinstance(raw_records, list):
        raise PiLogToolError("diskutil list omitted whole-disk records")
    whole = {
        value for value in raw_whole
        if isinstance(value, str) and re.fullmatch(r"disk[0-9]+", value)
    }
    records = {
        record.get("DeviceIdentifier"): record
        for record in raw_records
        if isinstance(record, dict)
        and isinstance(record.get("DeviceIdentifier"), str)
        and record.get("DeviceIdentifier") in whole
    }
    identifiers = (
        [requested_identifier]
        if requested_identifier is not None
        else sorted(
            identifier for identifier, record in records.items()
            if _has_swiftos_partition_sentinels(record)
        )
    )
    if requested_identifier is not None and requested_identifier not in whole:
        raise PiLogToolError(
            f"{requested_identifier} is not in the fresh external physical disk list"
        )
    if not identifiers:
        raise PiLogToolError(
            "no removable external disk has the SWIFTOS FAT32 plus type-0xDA "
            "layout or A/B v2 layout"
        )

    candidates: list[CardCandidate] = []
    refusals: list[str] = []
    for identifier in identifiers:
        record = records.get(identifier)
        if record is None:
            refusals.append(f"{identifier}: missing whole-disk record")
            continue
        try:
            info = _run_plist(
                [executable, "info", "-plist", f"/dev/{identifier}"],
                runner=runner,
            )
            candidates.append(_validate_candidate(identifier, record, info))
        except PiLogToolError as error:
            refusals.append(str(error))

    if requested_identifier is not None:
        if candidates:
            return candidates[0]
        detail = refusals[0] if refusals else "fresh validation failed"
        raise PiLogToolError(detail)
    if len(candidates) > 1:
        paths = ", ".join(str(candidate.device_path) for candidate in candidates)
        raise PiLogToolError(
            f"multiple eligible SwiftOS cards are connected ({paths}); "
            "select one with --device after checking its identity"
        )
    if len(candidates) == 1:
        return candidates[0]
    detail = "; ".join(refusals) if refusals else "no candidate passed validation"
    raise PiLogToolError(f"no eligible SwiftOS card passed validation: {detail}")


def inspect_card(
    candidate: CardCandidate,
    *,
    inspector: Callable[..., dict[str, object]] = persistent.inspect_path,
) -> dict[str, object]:
    """Inspect a selected raw disk using its independently observed geometry."""

    try:
        report = inspector(
            candidate.raw_device_path,
            expected_byte_count=candidate.byte_count,
        )
    except PermissionError as error:
        raise PiLogToolError(
            "macOS denied read-only raw-disk access. Re-run this same card command "
            "with the privilege mechanism you trust; the tool does not invoke sudo "
            "and will perform fresh discovery again."
        ) from error
    except (media.MediaError, OSError, ValueError) as error:
        raise PiLogToolError(f"persistent-log inspection failed: {error}") from error
    enriched = dict(report)
    enriched["host_card_discovery"] = {
        "method": "fresh-diskutil-external-physical",
        "device_identifier": candidate.identifier,
        "device_path": str(candidate.device_path),
        "raw_device_path": str(candidate.raw_device_path),
        "media_name": candidate.media_name,
        "protocol": candidate.protocol,
        "byte_count": candidate.byte_count,
        "logical_block_bytes": candidate.logical_block_bytes,
        "logical_block_count": candidate.logical_block_count,
        "read_only": True,
    }
    return enriched


def _sequence_summary(report: Mapping[str, object]) -> str:
    metadata = report.get("sequence_metadata")
    persistent_record = (
        metadata.get("persistent_record")
        if isinstance(metadata, dict) else None
    )
    if not isinstance(persistent_record, dict):
        return "unavailable"
    first = persistent_record.get("first_sequence")
    last = persistent_record.get("last_sequence")
    count = persistent_record.get("record_count", 0)
    gaps = persistent_record.get("gap_count", 0)
    resets = persistent_record.get("reset_count", 0)
    if not count:
        return "empty"
    return f"{first}...{last}; {count} records; {gaps} gaps; {resets} resets"


def _report_integer(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def _latest_kernel_epoch(
    report: Mapping[str, object],
) -> tuple[int, int, int, int, Mapping[str, object]] | None:
    metadata = report.get("sequence_metadata")
    kernel = metadata.get("kernel_log") if isinstance(metadata, dict) else None
    epochs = kernel.get("epochs") if isinstance(kernel, dict) else None
    if not isinstance(epochs, list) or not epochs:
        return None
    epoch = epochs[-1]
    if not isinstance(epoch, dict):
        return None
    index = _report_integer(epoch.get("index"))
    first = _report_integer(epoch.get("first_persistent_sequence"))
    last = _report_integer(epoch.get("last_persistent_sequence"))
    count = _report_integer(kernel.get("epoch_count"))
    if (
        index is None
        or first is None
        or last is None
        or count is None
        or index < 0
        or count <= index
        or first <= 0
        or last < first
    ):
        return None
    return index, count, first, last, epoch


def _persistent_gap_in_range(
    report: Mapping[str, object],
    first: int,
    last: int,
) -> bool:
    metadata = report.get("sequence_metadata")
    persistent_record = (
        metadata.get("persistent_record") if isinstance(metadata, dict) else None
    )
    gaps = (
        persistent_record.get("gaps")
        if isinstance(persistent_record, dict) else None
    )
    if not isinstance(gaps, list):
        return False
    for gap in gaps:
        if not isinstance(gap, dict):
            continue
        previous = _report_integer(gap.get("previous_persistent_sequence"))
        following = _report_integer(gap.get("next_persistent_sequence"))
        if (
            previous is not None
            and following is not None
            and first <= previous < following <= last
        ):
            return True
    return False


def latest_kernel_epoch_console(
    report: Mapping[str, object],
) -> dict[str, object] | None:
    """Reconstruct and assess only the newest retained kernel epoch."""

    scope = _latest_kernel_epoch(report)
    records = report.get("persistent_records")
    if scope is None or not isinstance(records, list):
        return None
    index, count, first, last, epoch = scope
    selected: list[tuple[int, Mapping[str, object]]] = []
    for record in records:
        if not isinstance(record, dict):
            continue
        sequence = _report_integer(record.get("sequence"))
        chunk = record.get("console_chunk")
        if (
            sequence is not None
            and first <= sequence <= last
            and isinstance(chunk, dict)
        ):
            selected.append((sequence, chunk))
    selected.sort(key=lambda item: item[0])

    encoded = bytearray()
    malformed_chunk_count = 0
    boundary_issue_count = 0
    message_open = False
    active_source: int | None = None
    for _, chunk in selected:
        encoded_hex = chunk.get("bytes_hex")
        try:
            chunk_bytes = (
                bytes.fromhex(encoded_hex) if isinstance(encoded_hex, str) else b""
            )
        except ValueError:
            chunk_bytes = b""
        expected_bytes = _report_integer(chunk.get("byte_count"))
        if (
            expected_bytes is None
            or expected_bytes <= 0
            or len(chunk_bytes) != expected_bytes
        ):
            malformed_chunk_count += 1
            continue
        encoded.extend(chunk_bytes)

        is_first = chunk.get("is_first") is True
        is_last = chunk.get("is_last") is True
        source = _report_integer(chunk.get("source"))
        if is_first:
            if message_open:
                boundary_issue_count += 1
            message_open = True
            active_source = source
        elif not message_open:
            boundary_issue_count += 1
            message_open = True
            active_source = source
        elif source != active_source:
            boundary_issue_count += 1
            active_source = source
        if is_last:
            message_open = False
            active_source = None
    if message_open:
        boundary_issue_count += 1

    try:
        text = bytes(encoded).decode("utf-8")
        utf8_valid = True
    except UnicodeDecodeError:
        text = bytes(encoded).decode("utf-8", errors="replace")
        utf8_valid = False

    reasons: list[str] = []
    if not encoded:
        reasons.append("no console bytes")
    missing_prefix = _report_integer(epoch.get("missing_prefix_count"))
    if missing_prefix is None or missing_prefix != 0:
        reasons.append("kernel prefix loss")
    missing_between = _report_integer(epoch.get("missing_between_count"))
    if missing_between is None or missing_between != 0:
        reasons.append("kernel sequence gaps")
    if _persistent_gap_in_range(report, first, last):
        reasons.append("persistent sequence gaps")
    if boundary_issue_count:
        reasons.append("message boundary issues")
    if malformed_chunk_count:
        reasons.append("malformed console chunks")
    if not utf8_valid:
        reasons.append("invalid UTF-8")
    return {
        "epoch_index": index,
        "epoch_count": count,
        "first_persistent_sequence": first,
        "last_persistent_sequence": last,
        "byte_count": len(encoded),
        "text": text,
        "is_complete": not reasons,
        "incomplete_reasons": reasons,
    }


def card_summary_lines(report: Mapping[str, object]) -> list[str]:
    source = report.get("source")
    source_path = source.get("path") if isinstance(source, dict) else "unknown"
    capture = report.get("capture_summary")
    status = capture.get("status") if isinstance(capture, dict) else "unknown"
    console = report.get("canonical_console_stream")
    console_bytes = console.get("byte_count", 0) if isinstance(console, dict) else 0
    complete = console.get("is_complete") if isinstance(console, dict) else False
    boot = report.get("boot_epoch_markers")
    boot_count = boot.get("count", 0) if isinstance(boot, dict) else 0
    crosses_epochs = (
        console.get("crosses_kernel_epochs") is True
        if isinstance(console, dict) else False
    )
    latest = latest_kernel_epoch_console(report)
    if crosses_epochs:
        epoch_count = (
            latest.get("epoch_count") if isinstance(latest, dict) else boot_count
        )
        console_line = (
            f"console: {console_bytes} bytes; aggregate complete "
            f"{'yes' if complete else 'no'} (crosses {epoch_count} kernel epochs)"
        )
    else:
        console_line = (
            f"console: {console_bytes} bytes; complete {'yes' if complete else 'no'}"
        )
    lines = [
        f"source: {source_path} (read-only)",
    ]
    media_layout = report.get("media_layout")
    if isinstance(media_layout, dict):
        revision = media_layout.get("revision", "unknown")
        compatibility = media_layout.get("compatibility", "unknown")
        line = f"media layout: revision {revision}; {compatibility}"
        if media_layout.get("requires_whole_card_reflash") is True:
            line += "; whole-card reflash required"
        lines.append(line)
    lines.extend((
        f"data superblocks: {report.get('data_superblock_status', 'unknown')}",
        f"capture: {status}; boot epochs {boot_count}",
        f"sequences: {_sequence_summary(report)}",
        console_line,
    ))
    diagnostic_label = "diagnostic markers"
    if isinstance(latest, dict):
        index = int(latest["epoch_index"]) + 1
        count = int(latest["epoch_count"])
        first = latest["first_persistent_sequence"]
        last = latest["last_persistent_sequence"]
        latest_complete = latest["is_complete"] is True
        completeness = "yes" if latest_complete else "no"
        if not latest_complete:
            reasons = latest.get("incomplete_reasons")
            if isinstance(reasons, list) and reasons:
                completeness += f" ({', '.join(str(reason) for reason in reasons)})"
        lines.append(
            f"newest kernel epoch: {index}/{count}; persistent {first}...{last}; "
            f"{latest['byte_count']} console bytes; complete {completeness}"
        )
        diagnostic_label += f" (newest kernel epoch {index}/{count})"
    diagnostics = diagnostic_console_lines(report)
    if diagnostics:
        lines.append(f"{diagnostic_label}: {len(diagnostics)}")
        lines.extend(f"  {marker}" for marker in diagnostics)
    else:
        lines.append(f"{diagnostic_label}: none")
    return lines


def diagnostic_console_lines(report: Mapping[str, object]) -> list[str]:
    """Return newest-epoch failures with adjacent hardware fault context."""

    result: list[str] = []
    seen: set[str] = set()
    latest = latest_kernel_epoch_console(report)
    console_text = (
        str(latest["text"])
        if isinstance(latest, dict) else canonical_console_text(report)
    )
    rp1_context_names = (
        "RP1_NET_CLOCK_SYS_CTRL",
        "RP1_NET_CLOCK_SYS_DIV_INT",
        "RP1_NET_CLOCK_SYS_SEL",
        "RP1_NET_CLOCK_PLL_SYS_CS",
        "RP1_NET_CLOCK_PLL_SYS_PWR",
        "RP1_NET_CLOCK_PLL_SYS_PRIM",
        "RP1_NET_CLOCK_PLL_SYS_SEC",
        "RP1_NET_CLOCK_STAGE",
        "RP1_NET_CLOCK_METHOD",
        "RP1_NET_CLOCK_RESULT",
        "RP1_NET_CLOCK_INITIAL",
        "RP1_NET_CLOCK_ALIAS_INITIAL",
        "RP1_NET_CLOCK_ALIAS_DRAIN",
        "RP1_NET_CLOCK_FINAL",
        "RP1_NET_CLOCK_POLLS",
        "RP1_NET_CLOCK_ELAPSED_TICKS",
        "RP1_NET_BOARD_STAGE",
        "RP1_NET_BOARD_REGISTER",
        "RP1_NET_BOARD_EXPECTED",
        "RP1_NET_BOARD_OBSERVED",
    )
    usb_fault_context_names = (
        "USB_DEBUG_FAULT_REASON",
        "USB_DEBUG_FAULT_GADGET_STATE",
        "USB_DEBUG_FAULT_CONTROLLER_STATE",
        "USB_DEBUG_FAULT_GLOBAL",
        "USB_DEBUG_FAULT_ENDPOINT",
        "USB_DEBUG_FAULT_BUS_SPEED",
        "USB_DEBUG_FAULT_RX_STATUS",
    )
    rp1_context: dict[str, str] = {}
    usb_fault_context: dict[str, str] = {}

    def append_unique(line: str) -> None:
        if line not in seen:
            seen.add(line)
            result.append(line)

    def append_context(
        names: tuple[str, ...],
        context: Mapping[str, str],
    ) -> None:
        for name in names:
            line = context.get(name)
            if line is not None:
                append_unique(line)

    for raw_line in console_text.splitlines():
        line = raw_line.strip()
        if not line.startswith("SWIFTOS:"):
            continue
        marker = line.removeprefix("SWIFTOS:").split("=", 1)[0]
        if marker in rp1_context_names:
            rp1_context[marker] = line
            continue
        if marker in usb_fault_context_names:
            usb_fault_context[marker] = line
            continue
        suspicious = (
            any(
                token in marker
                for token in (
                    "PANIC",
                    "FAILED",
                    "TIMEOUT",
                    "MISSING",
                    "UNSUPPORTED",
                    "DEFERRED",
                    "MISMATCH",
                    "INVALID",
                    "UNAVAILABLE",
                    "LOST",
                )
            )
            or marker.endswith("_STATE")
            or marker == "USB_DEBUG_FAULT"
        )
        if suspicious and line not in seen:
            if marker in ("RP1_NET_BOARD_FAILED", "RP1_NET_BOARD_TIMEOUT"):
                append_context(rp1_context_names, rp1_context)
                rp1_context.clear()
            elif marker == "USB_DEBUG_FAULT":
                append_context(usb_fault_context_names, usb_fault_context)
                usb_fault_context.clear()
            append_unique(line)
    # A capture may end between a typed fault field and its terminal marker.
    # Preserve the bounded partial snapshot instead of silently hiding it.
    append_context(usb_fault_context_names, usb_fault_context)
    return result


def canonical_console_text(report: Mapping[str, object]) -> str:
    console = report.get("canonical_console_stream")
    if not isinstance(console, dict):
        return ""
    text = console.get("text")
    if isinstance(text, str):
        return text
    encoded = console.get("bytes_hex")
    if not isinstance(encoded, str):
        return ""
    try:
        return bytes.fromhex(encoded).decode("utf-8", errors="replace")
    except ValueError:
        return ""


def write_new_file(path: Path, value: bytes) -> None:
    """Create one evidence file without replacing an earlier capture."""

    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        view = memoryview(value)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("capture write made no progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextmanager
def open_new_capture(path: Path | None) -> Iterator[BinaryIO | None]:
    if path is None:
        yield None
        return
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    stream = os.fdopen(descriptor, "wb", closefd=True)
    try:
        yield stream
        stream.flush()
        os.fsync(stream.fileno())
    finally:
        stream.close()


def save_json_capture(path: Path, report: Mapping[str, object]) -> None:
    value = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode("utf-8")
    write_new_file(path, value)


def load_json_capture(path: Path) -> dict[str, object]:
    """Read one bounded, non-symlink persistent-log evidence file."""

    before = os.lstat(path)
    if stat.S_ISLNK(before.st_mode):
        raise PiLogToolError("saved capture symlinks are forbidden")
    if not stat.S_ISREG(before.st_mode):
        raise PiLogToolError("saved capture is not a regular file")
    if not 0 < before.st_size <= MAXIMUM_SAVED_CAPTURE_BYTES:
        raise PiLogToolError("saved capture size is empty or exceeds the safety bound")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        after = os.fstat(descriptor)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
        ):
            raise PiLogToolError("saved capture changed while it was being opened")
        chunks: list[bytes] = []
        remaining = after.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            if not chunk:
                raise PiLogToolError("saved capture ended before its declared size")
            chunks.append(chunk)
            remaining -= len(chunk)
    finally:
        os.close(descriptor)
    try:
        value = json.loads(b"".join(chunks))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PiLogToolError("saved capture is not valid JSON") from error
    if not isinstance(value, dict):
        raise PiLogToolError("saved capture JSON root is not an object")
    if value.get("format") != "swiftos-persistent-log-capture-v1":
        raise PiLogToolError("saved capture has an unsupported format")
    return value


@dataclass(frozen=True)
class LiveResult:
    last_command: tuple[str, ...]
    byte_count: int
    poll_count: int
    boot_session_id: str | None


@dataclass(frozen=True)
class ValidatedLivePage:
    device_path: str
    boot_session_id: str
    next_sequence: int | None
    more_available: bool
    discontinuity_count: int
    incomplete_message_count: int
    sequence_exhausted: bool


def _live_command(
    swiftosctl: Path,
    *,
    device: str | None,
    timeout_seconds: float,
    starting_sequence: int | None,
    count: int,
) -> list[str]:
    command = [
        str(swiftosctl),
        "console",
        "--timeout",
        str(timeout_seconds),
        "--count",
        str(count),
        "--json",
    ]
    if device is not None:
        command.extend(["--device", device])
    if starting_sequence is not None:
        command.extend(["--start", str(starting_sequence)])
    return command


def _validate_live_request_arguments(
    *,
    timeout_seconds: float,
    starting_sequence: int | None,
    count: int,
    poll_interval_seconds: float,
) -> None:
    if (
        isinstance(timeout_seconds, bool)
        or not isinstance(timeout_seconds, (int, float))
        or not 0.001 <= timeout_seconds <= 3_600
    ):
        raise PiLogToolError("--timeout must be between 0.001 and 3600 seconds")
    if starting_sequence is not None and (
        isinstance(starting_sequence, bool)
        or not isinstance(starting_sequence, int)
        or not 1 <= starting_sequence <= MAXIMUM_SEQUENCE
    ):
        raise PiLogToolError("--start must be between 1 and UInt64.max")
    if (
        isinstance(count, bool)
        or not isinstance(count, int)
        or not 1 <= count <= 4_096
    ):
        raise PiLogToolError("--count must be between 1 and 4096")
    if (
        isinstance(poll_interval_seconds, bool)
        or not isinstance(poll_interval_seconds, (int, float))
        or not 0.05 <= poll_interval_seconds <= 60
    ):
        raise PiLogToolError("--poll-interval must be between 0.05 and 60 seconds")


def _decode_live_report(value: bytes) -> tuple[dict[str, object], bytes]:
    if len(value) > MAXIMUM_LIVE_REPORT_BYTES:
        raise PiLogToolError("swiftosctl returned an unexpectedly large report")
    try:
        report = json.loads(value)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PiLogToolError("swiftosctl console returned invalid JSON") from error
    if not isinstance(report, dict):
        raise PiLogToolError("swiftosctl console JSON root is not an object")
    encoded = report.get("consoleBase64")
    if not isinstance(encoded, str):
        raise PiLogToolError("swiftosctl console report omitted consoleBase64")
    try:
        console = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise PiLogToolError("swiftosctl console returned invalid consoleBase64") from error
    byte_count = report.get("consoleByteCount")
    if isinstance(byte_count, bool) or not isinstance(byte_count, int):
        raise PiLogToolError("swiftosctl console report omitted consoleByteCount")
    if byte_count != len(console):
        raise PiLogToolError("swiftosctl console byte count does not match its payload")
    return report, console


def _live_report_integer(
    report: Mapping[str, object],
    key: str,
    *,
    maximum: int = MAXIMUM_SEQUENCE,
) -> int:
    value = report.get(key)
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < 0
        or value > maximum
    ):
        raise PiLogToolError(f"swiftosctl console returned invalid {key}")
    return value


def _live_report_sequence(
    report: Mapping[str, object],
    key: str,
) -> int | None:
    value = report.get(key)
    if value is None:
        return None
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not 1 <= value <= MAXIMUM_SEQUENCE
    ):
        raise PiLogToolError(f"swiftosctl console returned invalid {key}")
    return value


def _validate_live_page(
    report: Mapping[str, object],
    console: bytes,
    requested_cursor: int | None,
    requested_count: int,
) -> ValidatedLivePage:
    if requested_cursor is not None and not 1 <= requested_cursor <= MAXIMUM_SEQUENCE:
        raise PiLogToolError("live console cursor is outside the UInt64 sequence range")
    if not 1 <= requested_count <= 4_096:
        raise PiLogToolError("live console count is outside the protocol bound")

    device_path = report.get("devicePath")
    if (
        not isinstance(device_path, str)
        or LIVE_DEVICE_PATTERN.fullmatch(device_path) is None
    ):
        raise PiLogToolError("swiftosctl console returned an invalid devicePath")
    boot_session = report.get("bootSessionID")
    if (
        not isinstance(boot_session, str)
        or re.fullmatch(r"[0-9a-f]{32}", boot_session) is None
        or boot_session == "0" * 32
    ):
        raise PiLogToolError("swiftosctl console returned an invalid bootSessionID")

    requested = _live_report_sequence(report, "requestedStartingSequence")
    effective = _live_report_sequence(report, "effectiveStartingSequence")
    next_sequence = _live_report_sequence(report, "nextSequence")
    if requested != requested_cursor:
        raise PiLogToolError("swiftosctl console changed the requested cursor")
    if requested_cursor is not None and effective != requested_cursor:
        raise PiLogToolError("swiftosctl console changed the effective cursor")

    more_available = report.get("moreAvailable")
    if not isinstance(more_available, bool):
        raise PiLogToolError("swiftosctl console returned invalid moreAvailable")

    oldest = _live_report_integer(report, "oldestAvailableSequence")
    newest = _live_report_integer(report, "newestAvailableSequence")
    _live_report_integer(report, "lostEntryCount")
    if (oldest == 0) != (newest == 0) or (oldest != 0 and oldest > newest):
        raise PiLogToolError("swiftosctl console returned an invalid available range")
    console_chunks = _live_report_integer(
        report,
        "consoleChunkCount",
        maximum=4_096,
    )
    non_console = _live_report_integer(
        report,
        "nonConsoleEntryCount",
        maximum=4_096,
    )
    malformed_console = _live_report_integer(
        report,
        "malformedConsoleEntryCount",
        maximum=4_096,
    )
    discontinuities = _live_report_integer(
        report,
        "sequenceDiscontinuityCount",
        maximum=4_096,
    )
    incomplete = _live_report_integer(
        report,
        "incompleteMessageCount",
        maximum=4_096,
    )
    starts_mid_message = report.get("startsMidMessage")
    ends_mid_message = report.get("endsMidMessage")
    if not isinstance(starts_mid_message, bool):
        raise PiLogToolError("swiftosctl console returned invalid startsMidMessage")
    if not isinstance(ends_mid_message, bool):
        raise PiLogToolError("swiftosctl console returned invalid endsMidMessage")
    entry_count = console_chunks + non_console + malformed_console
    if entry_count > requested_count:
        raise PiLogToolError("swiftosctl console exceeded the requested entry count")
    if discontinuities > max(0, entry_count - 1):
        raise PiLogToolError("swiftosctl console returned impossible sequence gaps")
    if incomplete > console_chunks:
        raise PiLogToolError("swiftosctl console returned impossible incomplete messages")
    if (starts_mid_message or ends_mid_message) and incomplete == 0:
        raise PiLogToolError("swiftosctl console returned impossible message state")
    if console_chunks == 0:
        if console:
            raise PiLogToolError("swiftosctl console returned bytes without CONS entries")
        if incomplete != 0 or starts_mid_message or ends_mid_message:
            raise PiLogToolError("swiftosctl console returned impossible message state")
    elif not (
        console_chunks
        <= len(console)
        <= MAXIMUM_CONSOLE_CHUNK_BYTES * console_chunks
    ):
        raise PiLogToolError("swiftosctl console returned invalid CONS chunk bytes")

    sequence_exhausted = False
    if entry_count > 0:
        if effective is None:
            raise PiLogToolError("swiftosctl console omitted the effective cursor")
        if requested_cursor is None and effective != oldest:
            raise PiLogToolError("swiftosctl console omitted the retained log prefix")
        if oldest == 0 or not oldest <= effective <= newest:
            raise PiLogToolError(
                "swiftosctl console effective cursor is outside the available range"
            )
        if next_sequence is not None and next_sequence < effective:
            raise PiLogToolError("swiftosctl console cursor moved backwards")
        if next_sequence == effective:
            raise PiLogToolError("swiftosctl console cursor did not advance")
        if entry_count - 1 > MAXIMUM_SEQUENCE - effective:
            raise PiLogToolError("swiftosctl console entry range overflowed UInt64")
        last_sequence = effective + entry_count - 1
        if newest < last_sequence:
            raise PiLogToolError("swiftosctl console entries exceed the available range")
        if last_sequence == MAXIMUM_SEQUENCE:
            if next_sequence is not None or more_available or newest != MAXIMUM_SEQUENCE:
                raise PiLogToolError("swiftosctl console malformed sequence exhaustion")
            sequence_exhausted = True
        else:
            expected_next = last_sequence + 1
            if next_sequence is None:
                raise PiLogToolError(
                    "swiftosctl console omitted a required nextSequence"
                )
            if next_sequence != expected_next:
                raise PiLogToolError("swiftosctl console cursor did not advance exactly")
            expected_more = last_sequence < newest
            if more_available != expected_more:
                raise PiLogToolError(
                    "swiftosctl console returned inconsistent moreAvailable"
                )
    elif requested_cursor is None:
        if (
            effective is not None
            or next_sequence is not None
            or oldest != 0
            or newest != 0
            or more_available
        ):
            raise PiLogToolError("swiftosctl console malformed an empty initial log")
    else:
        if (
            console
            or effective != requested_cursor
            or next_sequence != requested_cursor
            or more_available
            or newest == MAXIMUM_SEQUENCE
            or requested_cursor != newest + 1
        ):
            raise PiLogToolError("swiftosctl console malformed an idle tail cursor")

    return ValidatedLivePage(
        device_path=device_path,
        boot_session_id=boot_session,
        next_sequence=next_sequence,
        more_available=more_available,
        discontinuity_count=discontinuities,
        incomplete_message_count=incomplete,
        sequence_exhausted=sequence_exhausted,
    )


def run_live_console(
    *,
    swiftosctl: Path,
    device: str | None,
    timeout_seconds: float,
    starting_sequence: int | None,
    count: int,
    follow: bool,
    poll_interval_seconds: float,
    output: Path | None,
    runner: CommandRunner = run_bytes,
    stdout: BinaryIO | None = None,
    stderr: TextIO = sys.stderr,
    sleeper: Callable[[float], None] = time.sleep,
    maximum_polls: int | None = None,
) -> LiveResult:
    """Poll the canonical live-console client and tee exact console bytes."""

    _validate_live_request_arguments(
        timeout_seconds=timeout_seconds,
        starting_sequence=starting_sequence,
        count=count,
        poll_interval_seconds=poll_interval_seconds,
    )
    if not swiftosctl.is_file() or not os.access(swiftosctl, os.X_OK):
        raise PiLogToolError(
            f"{swiftosctl} is not an executable swiftosctl; run `make swiftosctl`"
        )
    if device is not None:
        if LIVE_DEVICE_PATTERN.fullmatch(device) is None:
            raise PiLogToolError(
                "live device must be a macOS /dev/cu.usbmodem* callout path"
            )
    sink = stdout if stdout is not None else sys.stdout.buffer
    cursor = starting_sequence
    selected_device = device
    boot_session: str | None = None
    total_bytes = 0
    polls = 0
    last_command: tuple[str, ...] = ()
    with open_new_capture(output) as capture:
        while True:
            command = _live_command(
                swiftosctl,
                device=selected_device,
                timeout_seconds=timeout_seconds,
                starting_sequence=cursor,
                count=count,
            )
            last_command = tuple(command)
            try:
                completed = runner(command)
            except OSError as error:
                raise PiLogToolError(f"could not execute swiftosctl: {error}") from error
            if completed.stderr:
                stderr.write(completed.stderr.decode("utf-8", errors="replace"))
                stderr.flush()
            if completed.returncode != 0:
                raise PiLogToolError(
                    f"swiftosctl console exited with status {completed.returncode}"
                )
            report, console = _decode_live_report(completed.stdout)
            page = _validate_live_page(report, console, cursor, count)
            report_device = page.device_path
            report_boot = page.boot_session_id
            if selected_device is None:
                selected_device = report_device
                stderr.write(f"live SwiftOS console: {selected_device}\n")
                stderr.flush()
            elif report_device != selected_device:
                raise PiLogToolError("swiftosctl switched CDC devices while following logs")
            if boot_session is None:
                boot_session = report_boot
                stderr.write(f"boot session: {boot_session}\n")
                stderr.flush()
            elif report_boot != boot_session:
                raise PiLogToolError(
                    "SwiftOS rebooted while logs were being followed; restart the "
                    "command to establish the new boot-session cursor"
                )

            if console:
                sink.write(console)
                sink.flush()
                if capture is not None:
                    capture.write(console)
                    capture.flush()
                total_bytes += len(console)
            if page.discontinuity_count or page.incomplete_message_count:
                stderr.write(
                    "warning: live console reports "
                    f"{page.discontinuity_count} sequence discontinuities and "
                    f"{page.incomplete_message_count} incomplete messages\n"
                )
                stderr.flush()

            polls += 1
            cursor = page.next_sequence
            if not follow or (
                maximum_polls is not None and polls >= maximum_polls
            ):
                break
            if page.sequence_exhausted:
                stderr.write("live console sequence space exhausted; follow stopped\n")
                stderr.flush()
                break
            if not page.more_available:
                sleeper(poll_interval_seconds)

    return LiveResult(
        last_command=last_command,
        byte_count=total_bytes,
        poll_count=polls,
        boot_session_id=boot_session,
    )


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    card = commands.add_parser(
        "card",
        help="discover and inspect returned Pi microSD logs read-only",
    )
    source = card.add_mutually_exclusive_group()
    source.add_argument(
        "--device",
        help="select a whole disk, revalidated against a fresh diskutil snapshot",
    )
    source.add_argument(
        "--image",
        type=Path,
        help="inspect a regular SwiftOS media image instead of physical media",
    )
    card.add_argument("--output", type=Path, help="create a full JSON evidence file")
    card.add_argument(
        "--json",
        action="store_true",
        help="print the full JSON report instead of the readable summary/console",
    )
    card.add_argument(
        "--summary-only",
        action="store_true",
        help="omit canonical console text from readable output",
    )

    show = commands.add_parser(
        "show",
        help="summarize a previously saved persistent-log JSON capture",
    )
    show.add_argument("capture", type=Path)
    show.add_argument(
        "--json",
        action="store_true",
        help="print the bounded recognized-format JSON capture",
    )
    show.add_argument(
        "--summary-only",
        action="store_true",
        help="omit canonical console text from readable output",
    )

    live = commands.add_parser(
        "live",
        help="view canonical console logs from a connected Pi over USB CDC/SDBG",
    )
    live.add_argument(
        "--device",
        help="explicit /dev/cu.usbmodem* path; omitted means exact SwiftOS discovery",
    )
    live.add_argument(
        "--swiftosctl",
        type=Path,
        default=DEFAULT_SWIFTOSCTL,
        help="path to the built SwiftOS control client",
    )
    live.add_argument("--timeout", type=float, default=30.0)
    live.add_argument("--start", type=int)
    live.add_argument("--count", type=int, default=4096)
    live.add_argument(
        "--poll-interval",
        type=float,
        default=0.5,
        help="seconds between idle follow requests",
    )
    live.add_argument(
        "--once",
        action="store_true",
        help="pull the retained console once instead of following new entries",
    )
    live.add_argument(
        "--output",
        type=Path,
        help="create an exact live-console transcript alongside terminal output",
    )
    return parser


def _validate_live_arguments(arguments: argparse.Namespace) -> None:
    _validate_live_request_arguments(
        timeout_seconds=arguments.timeout,
        starting_sequence=arguments.start,
        count=arguments.count,
        poll_interval_seconds=arguments.poll_interval,
    )


def main(argv: list[str] | None = None) -> int:
    arguments = argument_parser().parse_args(argv)
    try:
        if arguments.command == "live":
            _validate_live_arguments(arguments)
            run_live_console(
                swiftosctl=arguments.swiftosctl,
                device=arguments.device,
                timeout_seconds=arguments.timeout,
                starting_sequence=arguments.start,
                count=arguments.count,
                follow=not arguments.once,
                poll_interval_seconds=arguments.poll_interval,
                output=arguments.output,
            )
            return 0

        if arguments.command == "show":
            report = load_json_capture(arguments.capture)
        else:
            if arguments.image is not None:
                try:
                    report = persistent.inspect_path(arguments.image)
                except (media.MediaError, OSError, ValueError) as error:
                    raise PiLogToolError(
                        f"persistent-log inspection failed: {error}"
                    ) from error
            else:
                candidate = discover_swiftos_card(arguments.device)
                report = inspect_card(candidate)
            if arguments.output is not None:
                save_json_capture(arguments.output, report)
        if arguments.json:
            print(json.dumps(report, indent=2, sort_keys=True))
        else:
            for line in card_summary_lines(report):
                print(line)
            if not arguments.summary_only:
                text = canonical_console_text(report)
                if text:
                    print("console:")
                    print(text, end="" if text.endswith("\n") else "\n")
                else:
                    print("console: no retained console bytes")
        return 0
    except FileExistsError as error:
        print(
            f"swiftos-pi-logs: refusing to overwrite capture: {error.filename}",
            file=sys.stderr,
        )
        return 1
    except PiLogToolError as error:
        print(f"swiftos-pi-logs: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"swiftos-pi-logs: host I/O failed: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nswiftos-pi-logs: live log follow stopped", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
