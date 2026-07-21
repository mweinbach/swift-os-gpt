#!/usr/bin/env python3
from __future__ import annotations

import base64
from contextlib import contextmanager, redirect_stderr
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[2]
TOOLS = REPOSITORY / "tools"
sys.path.insert(0, str(TOOLS))
import swiftos_pi_logs as logs  # noqa: E402


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def expect_error(action, text: str) -> None:
    try:
        action()
    except logs.PiLogToolError as error:
        require(text in str(error), f"unexpected refusal: {error}")
    else:
        raise AssertionError(f"expected refusal containing: {text}")


def partition(
    identifier: str,
    content: str,
    *,
    volume_name: str | None = None,
) -> dict[str, object]:
    result: dict[str, object] = {
        "DeviceIdentifier": identifier,
        "Content": content,
        "Size": 64 * 1024 * 1024,
    }
    if volume_name is not None:
        result["VolumeName"] = volume_name
    return result


def whole_record(
    identifier: str,
    size: int,
    *,
    swiftos: bool,
    ab: bool = False,
) -> dict[str, object]:
    if swiftos and ab:
        partitions = [
            partition(
                f"{identifier}s1",
                "DOS_FAT_12",
                volume_name="SWIFTOS-CTL",
            ),
            partition(
                f"{identifier}s2",
                "DOS_FAT_32",
                volume_name="SWIFTOS-A",
            ),
            partition(
                f"{identifier}s3",
                "DOS_FAT_32",
                volume_name="SWIFTOS-B",
            ),
            partition(f"{identifier}s4", "DA"),
        ]
    else:
        partitions = [
            partition(
                f"{identifier}s1",
                "DOS_FAT_32",
                volume_name="SWIFTOS" if swiftos else "OTHER",
            ),
            partition(
                f"{identifier}s2",
                "DA" if swiftos else "Apple_APFS",
            ),
        ]
    return {
        "DeviceIdentifier": identifier,
        "Content": "FDisk_partition_scheme",
        "Size": size,
        "Partitions": partitions,
    }


def disk_info(
    identifier: str,
    size: int,
    *,
    removable: bool = True,
) -> dict[str, object]:
    return {
        "DeviceIdentifier": identifier,
        "DeviceNode": f"/dev/{identifier}",
        "WholeDisk": True,
        "Internal": False,
        "RemovableMedia": removable,
        "VirtualOrPhysical": "Physical",
        "DeviceLocation": "External",
        "DeviceBlockSize": 512,
        "TotalSize": size,
        "MediaName": "Fake SD Card Reader Media",
        "BusProtocol": "USB",
    }


class FakeDiskutil:
    def __init__(
        self,
        records: list[dict[str, object]],
        infos: dict[str, dict[str, object]],
    ) -> None:
        self.records = records
        self.infos = infos
        self.calls: list[tuple[str, ...]] = []

    def __call__(
        self,
        arguments,
    ) -> subprocess.CompletedProcess[bytes]:
        command = tuple(arguments)
        self.calls.append(command)
        if command[1:] == ("list", "-plist", "external", "physical"):
            value = {
                "WholeDisks": [record["DeviceIdentifier"] for record in self.records],
                "AllDisksAndPartitions": self.records,
            }
        elif len(command) == 4 and command[1:3] == ("info", "-plist"):
            identifier = command[3].removeprefix("/dev/")
            value = self.infos[identifier]
        else:
            raise AssertionError(f"unexpected diskutil invocation: {command}")
        return subprocess.CompletedProcess(
            arguments,
            0,
            stdout=plistlib.dumps(value),
            stderr=b"",
        )


@contextmanager
def darwin_platform():
    with mock.patch.object(logs.sys, "platform", "darwin"):
        yield


def test_fresh_card_discovery_ignores_unrelated_fixed_disk() -> None:
    card_size = 128_177_930_240
    fixed_size = 2_000_398_934_016
    fake = FakeDiskutil(
        [
            whole_record("disk4", card_size, swiftos=True, ab=True),
            whole_record("disk6", fixed_size, swiftos=False),
        ],
        {
            "disk4": disk_info("disk4", card_size),
            "disk6": disk_info("disk6", fixed_size, removable=False),
        },
    )
    with darwin_platform():
        candidate = logs.discover_swiftos_card(
            runner=fake,
            diskutil=Path("/usr/sbin/diskutil"),
        )
    require(candidate.identifier == "disk4", "wrong removable card selected")
    require(candidate.raw_device_path == Path("/dev/rdisk4"), "raw path changed")
    require(candidate.byte_count == card_size, "card size changed")
    require(candidate.logical_block_count == card_size // 512,
            "card block count changed")
    require(len(fake.calls) == 2, "unrelated disk was queried after sentinel filter")
    require(fake.calls[0][1:] == ("list", "-plist", "external", "physical"),
            "discovery did not take a fresh external physical snapshot")
    require(fake.calls[1][-1] == "/dev/disk4", "wrong disk was validated")


def test_ambiguous_cards_and_unrelated_selection_are_refused() -> None:
    size = 64 * 1024 * 1024
    ambiguous = FakeDiskutil(
        [
            whole_record("disk4", size, swiftos=True),
            whole_record("disk5", size, swiftos=True),
        ],
        {
            "disk4": disk_info("disk4", size),
            "disk5": disk_info("disk5", size),
        },
    )
    with darwin_platform():
        expect_error(
            lambda: logs.discover_swiftos_card(runner=ambiguous),
            "multiple eligible SwiftOS cards",
        )

    unrelated = FakeDiskutil(
        [whole_record("disk6", size, swiftos=False)],
        {"disk6": disk_info("disk6", size)},
    )
    with darwin_platform():
        expect_error(
            lambda: logs.discover_swiftos_card(
                "/dev/rdisk6",
                runner=unrelated,
            ),
            "does not have the SWIFTOS FAT32 plus type-0xDA layout",
        )
        expect_error(
            lambda: logs.discover_swiftos_card(
                "/dev/disk99",
                runner=unrelated,
            ),
            "is not in the fresh external physical disk list",
        )
        expect_error(
            lambda: logs.discover_swiftos_card(
                "/dev/disk6s1",
                runner=unrelated,
            ),
            "whole disk",
        )


def test_geometry_and_removability_must_match_fresh_info() -> None:
    size = 64 * 1024 * 1024
    mismatch = FakeDiskutil(
        [whole_record("disk4", size, swiftos=True)],
        {"disk4": disk_info("disk4", size + 512)},
    )
    with darwin_platform():
        expect_error(
            lambda: logs.discover_swiftos_card(runner=mismatch),
            "geometry changed",
        )

    fixed = FakeDiskutil(
        [whole_record("disk4", size, swiftos=True)],
        {"disk4": disk_info("disk4", size, removable=False)},
    )
    with darwin_platform():
        expect_error(
            lambda: logs.discover_swiftos_card(runner=fixed),
            "RemovableMedia must be true",
        )

    legacy_info = disk_info("disk4", size)
    legacy_info["Whole"] = legacy_info.pop("WholeDisk")
    legacy = FakeDiskutil(
        [whole_record("disk4", size, swiftos=True)],
        {"disk4": legacy_info},
    )
    with darwin_platform():
        require(logs.discover_swiftos_card(runner=legacy).identifier == "disk4",
                "legacy diskutil Whole field was rejected")

    contradictory_info = disk_info("disk4", size)
    contradictory_info["Whole"] = False
    contradictory = FakeDiskutil(
        [whole_record("disk4", size, swiftos=True)],
        {"disk4": contradictory_info},
    )
    with darwin_platform():
        expect_error(
            lambda: logs.discover_swiftos_card(runner=contradictory),
            "WholeDisk/Whole must be true",
        )

    mounted_record = whole_record("disk4", size, swiftos=True)
    mounted_record["Partitions"][0]["MountPoint"] = "/Volumes/SWIFTOS"
    mounted = FakeDiskutil(
        [mounted_record],
        {"disk4": disk_info("disk4", size)},
    )
    with darwin_platform():
        expect_error(
            lambda: logs.discover_swiftos_card(runner=mounted),
            "diskutil unmountDisk /dev/disk4",
        )


def candidate() -> logs.CardCandidate:
    return logs.CardCandidate(
        identifier="disk4",
        device_path=Path("/dev/disk4"),
        raw_device_path=Path("/dev/rdisk4"),
        byte_count=128_177_930_240,
        logical_block_bytes=512,
        media_name="Fake SD",
        protocol="USB",
    )


def test_card_inspection_is_read_only_geometry_bounded() -> None:
    calls: list[tuple[Path, dict[str, object]]] = []

    def fake_inspector(path: Path, **options):
        calls.append((path, options))
        return {
            "format": "swiftos-persistent-log-capture-v1",
            "source": {"path": str(path)},
            "data_superblock_status": "healthy",
            "persistent_record_count": 0,
        }

    report = logs.inspect_card(candidate(), inspector=fake_inspector)
    require(calls == [(
        Path("/dev/rdisk4"),
        {"expected_byte_count": 128_177_930_240},
    )], "inspector did not receive exact raw-device geometry")
    discovery = report["host_card_discovery"]
    require(discovery["read_only"] is True, "capture omitted read-only contract")
    require(discovery["logical_block_count"] == 250_347_520,
            "capture block geometry changed")

    def denied(path: Path, **options):
        del path, options
        raise PermissionError("denied")

    expect_error(
        lambda: logs.inspect_card(candidate(), inspector=denied),
        "does not invoke sudo",
    )


def sample_card_report() -> dict[str, object]:
    return {
        "format": "swiftos-persistent-log-capture-v1",
        "source": {"path": "/dev/rdisk4"},
        "data_superblock_status": "healthy",
        "capture_summary": {"status": "records-present"},
        "boot_epoch_markers": {"count": 1},
        "sequence_metadata": {
            "persistent_record": {
                "first_sequence": 1,
                "last_sequence": 8,
                "record_count": 8,
                "gap_count": 0,
                "reset_count": 0,
            }
        },
        "canonical_console_stream": {
            "byte_count": 20,
            "is_complete": True,
            "text": "SWIFTOS:BOOT\r\nREADY\r\n",
        },
    }


def multi_epoch_card_report() -> tuple[dict[str, object], str, int, int]:
    records: list[dict[str, object]] = []
    persistent_sequence = 1

    def append_message(text: str) -> None:
        nonlocal persistent_sequence
        encoded = text.encode("utf-8")
        for offset in range(0, len(encoded), logs.MAXIMUM_CONSOLE_CHUNK_BYTES):
            chunk = encoded[offset:offset + logs.MAXIMUM_CONSOLE_CHUNK_BYTES]
            records.append({
                "sequence": persistent_sequence,
                "console_chunk": {
                    "source": 1,
                    "is_first": offset == 0,
                    "is_last": offset + len(chunk) == len(encoded),
                    "byte_count": len(chunk),
                    "bytes_hex": chunk.hex(),
                },
            })
            persistent_sequence += 1

    old_text = "SWIFTOS:OLD_BOOT_PANIC\r\n"
    append_message(old_text)
    old_last = persistent_sequence - 1
    latest_first = persistent_sequence
    latest_lines = [
        "SWIFTOS:USB_POWER_STATE_MISMATCH",
        "SWIFTOS:INPUT_INVALID",
        "SWIFTOS:DATA_UNAVAILABLE",
        "SWIFTOS:PACKET_LOST",
        "SWIFTOS:RP1_NET_BOARD_STAGE=0x2",
        "SWIFTOS:RP1_NET_BOARD_REGISTER=0x18014",
        "SWIFTOS:RP1_NET_BOARD_EXPECTED=0x800",
        "SWIFTOS:RP1_NET_BOARD_OBSERVED=0x2",
        "SWIFTOS:RP1_NET_BOARD_FAILED",
    ]
    latest_text = "".join(f"{line}\r\n" for line in latest_lines)
    for line in latest_lines:
        append_message(f"{line}\r\n")
    latest_last = persistent_sequence - 1
    aggregate_text = old_text + latest_text
    report: dict[str, object] = {
        "format": "swiftos-persistent-log-capture-v1",
        "source": {"path": "/dev/rdisk4"},
        "data_superblock_status": "healthy",
        "capture_summary": {"status": "records-present"},
        "boot_epoch_markers": {"count": 2},
        "persistent_records": records,
        "sequence_metadata": {
            "persistent_record": {
                "first_sequence": 1,
                "last_sequence": latest_last,
                "record_count": latest_last,
                "gap_count": 0,
                "reset_count": 0,
                "gaps": [],
            },
            "kernel_log": {
                "epoch_count": 2,
                "epochs": [
                    {
                        "index": 0,
                        "first_persistent_sequence": 1,
                        "last_persistent_sequence": old_last,
                        "missing_prefix_count": 0,
                        "missing_between_count": 0,
                    },
                    {
                        "index": 1,
                        "first_persistent_sequence": latest_first,
                        "last_persistent_sequence": latest_last,
                        "missing_prefix_count": 0,
                        "missing_between_count": 0,
                    },
                ],
            },
        },
        "canonical_console_stream": {
            "byte_count": len(aggregate_text.encode("utf-8")),
            "is_complete": False,
            "crosses_kernel_epochs": True,
            "text": aggregate_text,
        },
    }
    return report, latest_text, latest_first, latest_last


def test_card_summary_and_evidence_files_are_stable_and_non_overwriting() -> None:
    report = sample_card_report()
    lines = logs.card_summary_lines(report)
    require(lines == [
        "source: /dev/rdisk4 (read-only)",
        "data superblocks: healthy",
        "capture: records-present; boot epochs 1",
        "sequences: 1...8; 8 records; 0 gaps; 0 resets",
        "console: 20 bytes; complete yes",
        "diagnostic markers: none",
    ], "readable card summary changed")
    require(logs.canonical_console_text(report).endswith("READY\r\n"),
            "canonical console text changed")

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "capture.json"
        logs.save_json_capture(path, report)
        saved = json.loads(path.read_text(encoding="utf-8"))
        require(saved == report, "JSON evidence did not round-trip")
        require(logs.load_json_capture(path) == report,
                "saved JSON capture could not be viewed without media")
        try:
            logs.save_json_capture(path, report)
        except FileExistsError:
            pass
        else:
            raise AssertionError("evidence capture was overwritten")

        symlink = Path(directory) / "capture-link.json"
        symlink.symlink_to(path)
        expect_error(
            lambda: logs.load_json_capture(symlink),
            "symlinks are forbidden",
        )

        unsupported = Path(directory) / "unsupported.json"
        unsupported.write_text('{"format":"future"}\n', encoding="utf-8")
        expect_error(
            lambda: logs.load_json_capture(unsupported),
            "unsupported format",
        )


_DEFAULT_EFFECTIVE = object()


def live_report(
    console: bytes,
    *,
    next_sequence: int | None,
    newest_sequence: int | None = None,
    oldest_sequence: int | None = None,
    requested_sequence: int | None = None,
    effective_sequence: int | None | object = _DEFAULT_EFFECTIVE,
    non_console_entry_count: int | None = None,
    more_available: object = False,
    device: str = "/dev/cu.usbmodemSWIFTOS1",
    boot: str = "00112233445566778899aabbccddeeff",
) -> bytes:
    if newest_sequence is None:
        newest_sequence = 0 if next_sequence is None else next_sequence - 1
    if oldest_sequence is None:
        oldest_sequence = 0 if newest_sequence == 0 else 1
    if effective_sequence is _DEFAULT_EFFECTIVE:
        if requested_sequence is not None:
            effective_sequence = requested_sequence
        elif next_sequence is None and newest_sequence == 0 and not console:
            effective_sequence = None
        else:
            effective_sequence = 1
    console_chunk_count = 1 if console else 0
    if non_console_entry_count is None:
        if isinstance(effective_sequence, int) and next_sequence is not None:
            non_console_entry_count = max(
                0,
                next_sequence - effective_sequence - console_chunk_count,
            )
        else:
            non_console_entry_count = 0
    value = {
        "devicePath": device,
        "bootSessionID": boot,
        "requestedStartingSequence": requested_sequence,
        "effectiveStartingSequence": effective_sequence,
        "oldestAvailableSequence": oldest_sequence,
        "newestAvailableSequence": newest_sequence,
        "lostEntryCount": 0,
        "moreAvailable": more_available,
        "nextSequence": next_sequence,
        "consoleByteCount": len(console),
        "consoleText": console.decode("utf-8"),
        "consoleBase64": base64.b64encode(console).decode("ascii"),
        "consoleChunkCount": console_chunk_count,
        "nonConsoleEntryCount": non_console_entry_count,
        "malformedConsoleEntryCount": 0,
        "sequenceDiscontinuityCount": 0,
        "incompleteMessageCount": 0,
        "startsMidMessage": False,
        "endsMidMessage": False,
    }
    return json.dumps(value).encode("utf-8")


def updated_live_report(value: bytes, **updates: object) -> bytes:
    report = json.loads(value)
    report.update(updates)
    return json.dumps(report).encode("utf-8")


class FakeLiveRunner:
    def __init__(self, responses: list[bytes]) -> None:
        self.responses = list(responses)
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, arguments) -> subprocess.CompletedProcess[bytes]:
        self.calls.append(tuple(arguments))
        require(bool(self.responses), "live wrapper polled beyond its bound")
        return subprocess.CompletedProcess(
            arguments,
            0,
            stdout=self.responses.pop(0),
            stderr=b"",
        )


def executable_fixture(directory: Path) -> Path:
    path = directory / "swiftosctl"
    path.write_bytes(b"#!/bin/sh\nexit 0\n")
    path.chmod(0o700)
    return path


def test_live_follow_polls_cursor_and_tees_exact_console_bytes() -> None:
    with tempfile.TemporaryDirectory() as directory_name:
        directory = Path(directory_name)
        executable = executable_fixture(directory)
        output = directory / "live.log"
        runner = FakeLiveRunner([
            live_report(b"SWIFTOS:BOOT\r\n", next_sequence=5),
            live_report(
                b"SWIFTOS:READY\r\n",
                next_sequence=9,
                requested_sequence=5,
            ),
        ])
        terminal = io.BytesIO()
        diagnostics = io.StringIO()
        sleeps: list[float] = []
        result = logs.run_live_console(
            swiftosctl=executable,
            device=None,
            timeout_seconds=2.0,
            starting_sequence=None,
            count=32,
            follow=True,
            poll_interval_seconds=0.25,
            output=output,
            runner=runner,
            stdout=terminal,
            stderr=diagnostics,
            sleeper=sleeps.append,
            maximum_polls=2,
        )
        expected = b"SWIFTOS:BOOT\r\nSWIFTOS:READY\r\n"
        require(terminal.getvalue() == expected, "terminal transcript changed")
        require(output.read_bytes() == expected, "saved transcript is not exact")
        require(result.byte_count == len(expected) and result.poll_count == 2,
                "live result counts changed")
        require("live SwiftOS console: /dev/cu.usbmodemSWIFTOS1"
                in diagnostics.getvalue(), "automatic device was not reported")
        require("--json" in runner.calls[0], "wrapper did not request stable JSON")
        require("--device" not in runner.calls[0],
                "automatic discovery was bypassed on first connection")
        require(runner.calls[1][-2:] == ("--start", "5"),
                "follow poll did not advance the structured-log cursor")
        require(sleeps == [0.25], "idle polling interval changed")


def test_live_once_validates_device_and_refuses_capture_overwrite() -> None:
    with tempfile.TemporaryDirectory() as directory_name:
        directory = Path(directory_name)
        executable = executable_fixture(directory)
        runner = FakeLiveRunner([
            live_report(
                b"READY\n",
                next_sequence=2,
                requested_sequence=1,
            )
        ])
        result = logs.run_live_console(
            swiftosctl=executable,
            device="/dev/cu.usbmodemSWIFTOS1",
            timeout_seconds=1.0,
            starting_sequence=1,
            count=1,
            follow=False,
            poll_interval_seconds=0.5,
            output=None,
            runner=runner,
            stdout=io.BytesIO(),
            stderr=io.StringIO(),
        )
        require(result.poll_count == 1, "one-shot live pull repeated")
        require("--device" in runner.calls[0], "explicit CDC path was omitted")
        expect_error(
            lambda: logs.run_live_console(
                swiftosctl=executable,
                device="/dev/tty.Bluetooth-Incoming-Port",
                timeout_seconds=1.0,
                starting_sequence=None,
                count=1,
                follow=False,
                poll_interval_seconds=0.5,
                output=None,
                runner=runner,
                stdout=io.BytesIO(),
                stderr=io.StringIO(),
            ),
            "/dev/cu.usbmodem",
        )

        occupied = directory / "occupied.log"
        occupied.write_bytes(b"prior evidence")
        try:
            logs.run_live_console(
                swiftosctl=executable,
                device=None,
                timeout_seconds=1.0,
                starting_sequence=None,
                count=1,
                follow=False,
                poll_interval_seconds=0.5,
                output=occupied,
                runner=runner,
                stdout=io.BytesIO(),
                stderr=io.StringIO(),
            )
        except FileExistsError:
            pass
        else:
            raise AssertionError("live evidence capture was overwritten")
        require(occupied.read_bytes() == b"prior evidence",
                "existing live evidence was modified")


def test_failure_markers_are_promoted_in_capture_order() -> None:
    report = sample_card_report()
    report["canonical_console_stream"] = {
        "byte_count": 120,
        "is_complete": True,
        "text": (
            "SWIFTOS:BOOT\r\n"
            "SWIFTOS:PI_SIMPLE_FB_MISSING\r\n"
            "SWIFTOS:USB_POWER_STATE\r\n"
            "SWIFTOS:RP1_NET_DEFERRED\r\n"
            "SWIFTOS:RP1_NET_BOARD_FAILED\r\n"
            "SWIFTOS:RP1_NET_BOARD_FAILED\r\n"
            "READY\r\n"
        ),
    }
    require(logs.diagnostic_console_lines(report) == [
        "SWIFTOS:PI_SIMPLE_FB_MISSING",
        "SWIFTOS:USB_POWER_STATE",
        "SWIFTOS:RP1_NET_DEFERRED",
        "SWIFTOS:RP1_NET_BOARD_FAILED",
    ], "failure marker triage order or de-duplication changed")
    summary = logs.card_summary_lines(report)
    require("diagnostic markers: 4" in summary,
            "failure count was not promoted into summary")


def test_newest_epoch_diagnostics_include_actionable_context() -> None:
    report, latest_text, latest_first, latest_last = multi_epoch_card_report()
    latest = logs.latest_kernel_epoch_console(report)
    require(latest is not None, "newest kernel epoch was not reconstructed")
    require(latest["text"] == latest_text,
            "newest kernel epoch included bytes from an older boot")
    require(latest["is_complete"] is True,
            "gap-free newest kernel epoch was called incomplete")

    expected = [
        "SWIFTOS:USB_POWER_STATE_MISMATCH",
        "SWIFTOS:INPUT_INVALID",
        "SWIFTOS:DATA_UNAVAILABLE",
        "SWIFTOS:PACKET_LOST",
        "SWIFTOS:RP1_NET_BOARD_STAGE=0x2",
        "SWIFTOS:RP1_NET_BOARD_REGISTER=0x18014",
        "SWIFTOS:RP1_NET_BOARD_EXPECTED=0x800",
        "SWIFTOS:RP1_NET_BOARD_OBSERVED=0x2",
        "SWIFTOS:RP1_NET_BOARD_FAILED",
    ]
    diagnostics = logs.diagnostic_console_lines(report)
    require(diagnostics == expected,
            "newest-epoch failure promotion or RP1 context changed")
    require("OLD_BOOT_PANIC" not in "\n".join(diagnostics),
            "older kernel epoch contaminated current diagnostics")

    summary = logs.card_summary_lines(report)
    aggregate_bytes = report["canonical_console_stream"]["byte_count"]
    require(
        f"console: {aggregate_bytes} bytes; aggregate complete no "
        "(crosses 2 kernel epochs)" in summary,
        "cross-epoch aggregate completeness was not explained",
    )
    require(
        f"newest kernel epoch: 2/2; persistent {latest_first}...{latest_last}; "
        f"{len(latest_text.encode('utf-8'))} console bytes; complete yes" in summary,
        "newest epoch completeness was not reported independently",
    )
    require("diagnostic markers (newest kernel epoch 2/2): 9" in summary,
            "diagnostic scope was not made explicit")

    lossy = json.loads(json.dumps(report))
    lossy["sequence_metadata"]["kernel_log"]["epochs"][-1][
        "missing_between_count"
    ] = 1
    require(
        any(
            "newest kernel epoch:" in line
            and "complete no (kernel sequence gaps)" in line
            for line in logs.card_summary_lines(lossy)
        ),
        "newest-epoch loss reason was not explained",
    )


def test_hardware_fault_snapshots_are_promoted_as_adjacent_groups() -> None:
    report = sample_card_report()
    lines = [
        "SWIFTOS:RP1_NET_CLOCK_SYS_CTRL=0x2",
        "SWIFTOS:RP1_NET_CLOCK_METHOD=0x0",
        "SWIFTOS:RP1_NET_CLOCK_RESULT=0x2",
        "SWIFTOS:RP1_NET_CLOCK_ALIAS_INITIAL=0x0",
        "SWIFTOS:RP1_NET_CLOCK_FINAL=0x2",
        "SWIFTOS:RP1_NET_BOARD_STAGE=0x2",
        "SWIFTOS:RP1_NET_BOARD_EXPECTED=0x2",
        "SWIFTOS:RP1_NET_BOARD_OBSERVED=0x0",
        "SWIFTOS:RP1_NET_BOARD_FAILED",
        "SWIFTOS:USB_DEBUG_FAULT_REASON=0x6",
        "SWIFTOS:USB_DEBUG_FAULT_GADGET_STATE=0x0",
        "SWIFTOS:USB_DEBUG_FAULT_CONTROLLER_STATE=0x2",
        "SWIFTOS:USB_DEBUG_FAULT_GLOBAL=0x10",
        "SWIFTOS:USB_DEBUG_FAULT_ENDPOINT=0x0",
        "SWIFTOS:USB_DEBUG_FAULT_BUS_SPEED=0x0",
        "SWIFTOS:USB_DEBUG_FAULT_RX_STATUS=0xc0080",
        "SWIFTOS:USB_DEBUG_FAULT",
    ]
    report["canonical_console_stream"] = {
        "byte_count": sum(len(line) + 2 for line in lines),
        "is_complete": True,
        "text": "".join(f"{line}\r\n" for line in lines),
    }
    require(
        logs.diagnostic_console_lines(report) == lines,
        "RP1 clock or USB fault context was not promoted in capture order",
    )

    truncated = json.loads(json.dumps(report))
    truncated_lines = lines[:-1]
    truncated["canonical_console_stream"]["text"] = "".join(
        f"{line}\r\n" for line in truncated_lines
    )
    require(
        logs.diagnostic_console_lines(truncated)[-7:] == lines[-8:-1],
        "partial USB fault snapshot was hidden without its terminal marker",
    )


def test_live_report_corruption_and_device_switch_are_refused() -> None:
    with tempfile.TemporaryDirectory() as directory_name:
        executable = executable_fixture(Path(directory_name))
        invalid = FakeLiveRunner([b"not-json"])
        expect_error(
            lambda: logs.run_live_console(
                swiftosctl=executable,
                device=None,
                timeout_seconds=1.0,
                starting_sequence=None,
                count=1,
                follow=False,
                poll_interval_seconds=0.5,
                output=None,
                runner=invalid,
                stdout=io.BytesIO(),
                stderr=io.StringIO(),
            ),
            "invalid JSON",
        )

        switched = FakeLiveRunner([
            live_report(b"A", next_sequence=2),
            live_report(
                b"B",
                next_sequence=3,
                requested_sequence=2,
                device="/dev/cu.usbmodemOTHER",
            ),
        ])
        expect_error(
            lambda: logs.run_live_console(
                swiftosctl=executable,
                device=None,
                timeout_seconds=1.0,
                starting_sequence=None,
                count=1,
                follow=True,
                poll_interval_seconds=0.5,
                output=None,
                runner=switched,
                stdout=io.BytesIO(),
                stderr=io.StringIO(),
                sleeper=lambda _: None,
                maximum_polls=2,
            ),
            "switched CDC devices",
        )


def test_invalid_live_pages_do_not_contaminate_transcripts() -> None:
    with tempfile.TemporaryDirectory() as directory_name:
        directory = Path(directory_name)
        executable = executable_fixture(directory)
        cases = [
            (
                live_report(
                    b"BACKWARD",
                    next_sequence=4,
                    newest_sequence=9,
                    requested_sequence=5,
                    non_console_entry_count=0,
                ),
                5,
                "moved backwards",
            ),
            (
                live_report(
                    b"REPLAY",
                    next_sequence=5,
                    newest_sequence=9,
                    requested_sequence=5,
                    non_console_entry_count=0,
                ),
                5,
                "did not advance",
            ),
            (
                live_report(
                    b"FORWARD",
                    next_sequence=100,
                    newest_sequence=100,
                    requested_sequence=5,
                    non_console_entry_count=0,
                ),
                5,
                "did not advance exactly",
            ),
            (
                live_report(
                    b"",
                    next_sequence=6,
                    newest_sequence=9,
                    requested_sequence=5,
                    non_console_entry_count=0,
                ),
                5,
                "idle tail cursor",
            ),
            (
                live_report(
                    b"REQUEST",
                    next_sequence=5,
                    newest_sequence=9,
                    requested_sequence=4,
                    non_console_entry_count=0,
                ),
                5,
                "changed the requested cursor",
            ),
            (
                live_report(
                    b"EFFECTIVE",
                    next_sequence=5,
                    newest_sequence=9,
                    requested_sequence=5,
                    effective_sequence=4,
                    non_console_entry_count=0,
                ),
                5,
                "changed the effective cursor",
            ),
            (
                live_report(
                    b"BAD-BOOL",
                    next_sequence=6,
                    newest_sequence=9,
                    requested_sequence=5,
                    non_console_entry_count=0,
                    more_available="true",
                ),
                5,
                "invalid moreAvailable",
            ),
            (
                live_report(
                    b"NO-CURSOR",
                    next_sequence=None,
                    newest_sequence=9,
                    requested_sequence=5,
                ),
                5,
                "omitted a required nextSequence",
            ),
            (
                live_report(
                    b"DEVICE",
                    next_sequence=6,
                    newest_sequence=9,
                    requested_sequence=5,
                    non_console_entry_count=0,
                    device="/dev/tty.not-swiftos",
                ),
                5,
                "invalid devicePath",
            ),
            (
                live_report(
                    b"BOOT",
                    next_sequence=6,
                    newest_sequence=9,
                    requested_sequence=5,
                    non_console_entry_count=0,
                    boot="NOT-A-BOOT-ID",
                ),
                5,
                "invalid bootSessionID",
            ),
            (
                live_report(
                    b"PREFIX",
                    next_sequence=3,
                    newest_sequence=2,
                    oldest_sequence=1,
                    effective_sequence=2,
                    non_console_entry_count=0,
                ),
                None,
                "omitted the retained log prefix",
            ),
            (
                live_report(
                    b"TRUNCATED",
                    next_sequence=6,
                    newest_sequence=9,
                    requested_sequence=5,
                    non_console_entry_count=0,
                ),
                5,
                "inconsistent moreAvailable",
            ),
            (
                live_report(
                    b"DONE",
                    next_sequence=6,
                    newest_sequence=5,
                    requested_sequence=5,
                    non_console_entry_count=0,
                    more_available=True,
                ),
                5,
                "inconsistent moreAvailable",
            ),
            (
                updated_live_report(
                    live_report(
                        b"",
                        next_sequence=6,
                        newest_sequence=5,
                        requested_sequence=5,
                        non_console_entry_count=0,
                    ),
                    consoleChunkCount=1,
                ),
                5,
                "invalid CONS chunk bytes",
            ),
            (
                live_report(
                    b"X" * 17,
                    next_sequence=6,
                    newest_sequence=5,
                    requested_sequence=5,
                    non_console_entry_count=0,
                ),
                5,
                "invalid CONS chunk bytes",
            ),
            (
                updated_live_report(
                    live_report(
                        b"X",
                        next_sequence=7,
                        newest_sequence=6,
                        requested_sequence=5,
                        non_console_entry_count=0,
                    ),
                    consoleChunkCount=2,
                ),
                5,
                "invalid CONS chunk bytes",
            ),
            (
                live_report(
                    b"ZERO-BOOT",
                    next_sequence=6,
                    newest_sequence=5,
                    requested_sequence=5,
                    non_console_entry_count=0,
                    boot="0" * 32,
                ),
                5,
                "invalid bootSessionID",
            ),
            (
                live_report(
                    b"INJECT",
                    next_sequence=6,
                    newest_sequence=5,
                    requested_sequence=5,
                    non_console_entry_count=0,
                    device="/dev/cu.usbmodemOK\nESC",
                ),
                5,
                "invalid devicePath",
            ),
            (
                live_report(
                    b"EMPTY-SUFFIX",
                    next_sequence=6,
                    newest_sequence=5,
                    requested_sequence=5,
                    non_console_entry_count=0,
                    device="/dev/cu.usbmodem",
                ),
                5,
                "invalid devicePath",
            ),
            (
                updated_live_report(
                    live_report(
                        b"",
                        next_sequence=5,
                        newest_sequence=4,
                        requested_sequence=5,
                    ),
                    startsMidMessage=True,
                ),
                5,
                "impossible message state",
            ),
            (
                updated_live_report(
                    live_report(
                        b"ONE",
                        next_sequence=6,
                        newest_sequence=5,
                        requested_sequence=5,
                        non_console_entry_count=0,
                    ),
                    sequenceDiscontinuityCount=1,
                ),
                5,
                "impossible sequence gaps",
            ),
            (
                updated_live_report(
                    live_report(
                        b"ONE",
                        next_sequence=6,
                        newest_sequence=5,
                        requested_sequence=5,
                        non_console_entry_count=0,
                    ),
                    endsMidMessage=True,
                ),
                5,
                "impossible message state",
            ),
        ]
        for index, (response, start, message) in enumerate(cases):
            terminal = io.BytesIO()
            capture = directory / f"invalid-{index}.log"
            expect_error(
                lambda response=response, start=start, capture=capture: (
                    logs.run_live_console(
                        swiftosctl=executable,
                        device=None,
                        timeout_seconds=1.0,
                        starting_sequence=start,
                        count=8,
                        follow=False,
                        poll_interval_seconds=0.5,
                        output=capture,
                        runner=FakeLiveRunner([response]),
                        stdout=terminal,
                        stderr=io.StringIO(),
                    )
                ),
                message,
            )
            require(terminal.getvalue() == b"", "invalid report reached terminal")
            require(capture.read_bytes() == b"", "invalid report tainted capture")


def test_live_idle_and_sequence_exhaustion_are_bounded() -> None:
    with tempfile.TemporaryDirectory() as directory_name:
        executable = executable_fixture(Path(directory_name))

        idle_equal = logs.run_live_console(
            swiftosctl=executable,
            device=None,
            timeout_seconds=1.0,
            starting_sequence=5,
            count=8,
            follow=False,
            poll_interval_seconds=0.5,
            output=None,
            runner=FakeLiveRunner([
                live_report(
                    b"",
                    next_sequence=5,
                    newest_sequence=4,
                    requested_sequence=5,
                ),
            ]),
            stdout=io.BytesIO(),
            stderr=io.StringIO(),
        )
        require(idle_equal.byte_count == 0, "idle cursor produced bytes")

        sleeps: list[float] = []
        empty = logs.run_live_console(
            swiftosctl=executable,
            device=None,
            timeout_seconds=1.0,
            starting_sequence=None,
            count=8,
            follow=True,
            poll_interval_seconds=0.25,
            output=None,
            runner=FakeLiveRunner([
                live_report(b"", next_sequence=None, newest_sequence=0),
                live_report(b"", next_sequence=None, newest_sequence=0),
            ]),
            stdout=io.BytesIO(),
            stderr=io.StringIO(),
            sleeper=sleeps.append,
            maximum_polls=2,
        )
        require(empty.poll_count == 2, "empty log did not remain pollable")
        require(sleeps == [0.25], "empty log follow did not use its idle bound")

        terminal = io.BytesIO()
        diagnostics = io.StringIO()
        exhausted = logs.run_live_console(
            swiftosctl=executable,
            device=None,
            timeout_seconds=1.0,
            starting_sequence=logs.MAXIMUM_SEQUENCE,
            count=1,
            follow=True,
            poll_interval_seconds=0.25,
            output=None,
            runner=FakeLiveRunner([
                live_report(
                    b"LAST",
                    next_sequence=None,
                    newest_sequence=logs.MAXIMUM_SEQUENCE,
                    requested_sequence=logs.MAXIMUM_SEQUENCE,
                ),
            ]),
            stdout=terminal,
            stderr=diagnostics,
        )
        require(exhausted.poll_count == 1, "exhausted cursor was polled again")
        require(terminal.getvalue() == b"LAST", "final sequence bytes were lost")
        require("sequence space exhausted" in diagnostics.getvalue(),
                "sequence exhaustion was not reported")


def test_live_keyboard_interrupt_has_clean_cli_exit() -> None:
    error_output = io.StringIO()
    with mock.patch.object(logs, "run_live_console", side_effect=KeyboardInterrupt):
        with redirect_stderr(error_output):
            status = logs.main(["live"])
    require(status == 130, "Control-C did not produce the conventional exit status")
    require("live log follow stopped" in error_output.getvalue(),
            "Control-C did not emit a concise stop message")


def test_live_request_bounds_are_checked_before_execution() -> None:
    with tempfile.TemporaryDirectory() as directory_name:
        executable = executable_fixture(Path(directory_name))
        cases = [
            ({"starting_sequence": 0}, "--start"),
            ({"starting_sequence": logs.MAXIMUM_SEQUENCE + 1}, "--start"),
            ({"count": 0}, "--count"),
            ({"count": 4_097}, "--count"),
            ({"timeout_seconds": 0.0}, "--timeout"),
            ({"poll_interval_seconds": 0.0}, "--poll-interval"),
        ]
        for overrides, message in cases:
            runner = FakeLiveRunner([])
            arguments = {
                "swiftosctl": executable,
                "device": None,
                "timeout_seconds": 1.0,
                "starting_sequence": None,
                "count": 8,
                "follow": False,
                "poll_interval_seconds": 0.5,
                "output": None,
                "runner": runner,
                "stdout": io.BytesIO(),
                "stderr": io.StringIO(),
            }
            arguments.update(overrides)
            expect_error(
                lambda arguments=arguments: logs.run_live_console(**arguments),
                message,
            )
            require(runner.calls == [], "invalid arguments reached swiftosctl")

        error_output = io.StringIO()
        with mock.patch.object(logs, "run_live_console") as run:
            with redirect_stderr(error_output):
                status = logs.main([
                    "live",
                    "--start",
                    str(logs.MAXIMUM_SEQUENCE + 1),
                ])
        require(status == 1, "oversized CLI cursor was accepted")
        require(not run.called, "oversized CLI cursor reached live execution")
        require("--start" in error_output.getvalue(),
                "oversized CLI cursor refusal was not explained")


def main() -> int:
    tests = [
        test_fresh_card_discovery_ignores_unrelated_fixed_disk,
        test_ambiguous_cards_and_unrelated_selection_are_refused,
        test_geometry_and_removability_must_match_fresh_info,
        test_card_inspection_is_read_only_geometry_bounded,
        test_card_summary_and_evidence_files_are_stable_and_non_overwriting,
        test_live_follow_polls_cursor_and_tees_exact_console_bytes,
        test_live_once_validates_device_and_refuses_capture_overwrite,
        test_failure_markers_are_promoted_in_capture_order,
        test_newest_epoch_diagnostics_include_actionable_context,
        test_hardware_fault_snapshots_are_promoted_as_adjacent_groups,
        test_live_report_corruption_and_device_switch_are_refused,
        test_invalid_live_pages_do_not_contaminate_transcripts,
        test_live_idle_and_sequence_exhaustion_are_bounded,
        test_live_keyboard_interrupt_has_clean_cli_exit,
        test_live_request_bounds_are_checked_before_execution,
    ]
    for test in tests:
        test()
    print(f"Raspberry Pi log tool host tests: {len(tests)} groups passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
