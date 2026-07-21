#!/usr/bin/env python3
"""Cross-language golden for revision-three Raspberry Pi A/B slot identity.

The compact JSON fixture is also consumed by the Swift update-port test. This
side constructs both physical slot byte streams and asks the production media
builder to validate and normalize them. No packaged firmware or prior build
artifact participates in the result.
"""

from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import re
import struct
import sys


REPOSITORY = Path(__file__).resolve().parents[2]
FIXTURE = (
    REPOSITORY
    / "Tests/Fixtures/rpi5_ab_slot_digest_revision3.json"
)
SWIFT_FIXTURE = (
    REPOSITORY
    / "Tests/Fixtures/RaspberryPiABSlotDigestRevision3.swift"
)
sys.path.insert(0, str(REPOSITORY))

from tools import build_rpi5_media as media  # noqa: E402


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def swift_integer(source: str, name: str) -> int:
    match = re.search(
        rf"static let {re.escape(name)}(?:\s*:\s*[^=]+)?\s*=\s*"
        r"(0x[0-9A-Fa-f_]+|[0-9_]+)",
        source,
    )
    require(match is not None, f"Swift fixture is missing {name}")
    return int(match.group(1).replace("_", ""), 0)


def swift_string(source: str, name: str) -> str:
    match = re.search(
        rf"static let {re.escape(name)}(?:\s*:\s*[^=]+)?\s*=\s*"
        r'"([^"]+)"',
        source,
        re.DOTALL,
    )
    require(match is not None, f"Swift fixture is missing {name}")
    return match.group(1)


def swift_integer_array(source: str, name: str) -> list[int]:
    match = re.search(
        rf"static let {re.escape(name)}(?:\s*:\s*[^=]+)?\s*=\s*"
        r"\[([^\]]*)\]",
        source,
    )
    require(match is not None, f"Swift fixture is missing {name}")
    return [int(value.strip().replace("_", ""), 0)
            for value in match.group(1).split(",") if value.strip()]


def require_swift_fixture(fixture: dict[str, object]) -> None:
    source = SWIFT_FIXTURE.read_text(encoding="utf-8")
    hidden = fixture["fat32HiddenSectors"]
    pattern = fixture["contentPattern"]
    expected_integers = {
        "fixtureVersion": fixture["fixtureVersion"],
        "mediaLayoutFingerprint": int(
            fixture["mediaLayoutFingerprint"], 16
        ),
        "logicalBlockByteCount": fixture["logicalBlockByteCount"],
        "slotBlockCount": fixture["slotBlockCount"],
        "slotAStartBlock": fixture["slotAStartBlock"],
        "slotBStartBlock": fixture["slotBStartBlock"],
        "contentPatternMultiplier": pattern["multiplier"],
        "contentPatternIncrement": pattern["increment"],
        "contentPatternModulus": pattern["modulus"],
        "hiddenSectorByteOffset": hidden["byteOffset"],
        "hiddenSectorByteCount": hidden["byteCount"],
    }
    for name, value in expected_integers.items():
        require(
            swift_integer(source, name) == value,
            f"Swift fixture {name} disagrees with JSON",
        )
    require(
        swift_integer_array(source, "hiddenSectorRelativeBlocks")
        == hidden["relativeBlocks"],
        "Swift fixture hidden-sector blocks disagree with JSON",
    )
    require(
        swift_string(source, "hiddenSectorEncoding") == hidden["encoding"],
        "Swift fixture hidden-sector encoding disagrees with JSON",
    )
    require(
        swift_string(source, "normalizedSHA256Hex")
        == fixture["normalizedSHA256"],
        "Swift fixture digest disagrees with JSON",
    )


def load_fixture() -> dict[str, object]:
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    require(fixture["fixtureVersion"] == 1, "unknown digest fixture")
    require(
        int(fixture["mediaLayoutFingerprint"], 16)
        == media.AB_MEDIA_LAYOUT_FINGERPRINT,
        "fixture is not revision-three media",
    )
    require(
        fixture["logicalBlockByteCount"] == media.SECTOR_SIZE,
        "fixture sector size disagrees with the media builder",
    )
    hidden = fixture["fat32HiddenSectors"]
    require(
        tuple(hidden["relativeBlocks"]) == media.AB_SLOT_BOOT_SECTORS,
        "fixture boot-sector replicas disagree with the media builder",
    )
    require(
        hidden["byteOffset"] == media.FAT32_HIDDEN_SECTORS_OFFSET,
        "fixture BPB_HiddSec offset disagrees with the media builder",
    )
    require(
        hidden["byteCount"] == 4
        and hidden["encoding"] == "little-endian-u32",
        "fixture BPB_HiddSec encoding is unsupported",
    )
    require_swift_fixture(fixture)
    return fixture


def slot_bytes(fixture: dict[str, object], start_block: int) -> bytes:
    byte_count = (
        fixture["slotBlockCount"] * fixture["logicalBlockByteCount"]
    )
    pattern = fixture["contentPattern"]
    require(pattern["modulus"] == 256, "unsupported golden byte modulus")
    payload = bytearray(
        (index * pattern["multiplier"] + pattern["increment"])
        % pattern["modulus"]
        for index in range(byte_count)
    )
    hidden = fixture["fat32HiddenSectors"]
    for relative_block in hidden["relativeBlocks"]:
        offset = (
            relative_block * fixture["logicalBlockByteCount"]
            + hidden["byteOffset"]
        )
        struct.pack_into("<I", payload, offset, start_block)
    return bytes(payload)


def build_image(fixture: dict[str, object]) -> io.BytesIO:
    starts = (
        fixture["slotAStartBlock"],
        fixture["slotBStartBlock"],
    )
    end_block = max(starts) + fixture["slotBlockCount"]
    image = io.BytesIO(bytearray(
        end_block * fixture["logicalBlockByteCount"]
    ))
    for start_block in starts:
        image.seek(start_block * fixture["logicalBlockByteCount"])
        image.write(slot_bytes(fixture, start_block))
    return image


def normalized_digest(
    image: io.BytesIO,
    fixture: dict[str, object],
    start_block: int,
) -> bytes:
    return media.sha256_ab_slot_content(
        image,
        start_block,
        fixture["slotBlockCount"],
    )


def raw_digest(
    image: io.BytesIO,
    fixture: dict[str, object],
    start_block: int,
) -> bytes:
    image.seek(start_block * fixture["logicalBlockByteCount"])
    return hashlib.sha256(image.read(
        fixture["slotBlockCount"] * fixture["logicalBlockByteCount"]
    )).digest()


def require_replica_validation(
    fixture: dict[str, object],
    start_key: str,
    relative_block: int,
) -> None:
    image = build_image(fixture)
    start_block = fixture[start_key]
    hidden = fixture["fat32HiddenSectors"]
    offset = (
        (start_block + relative_block)
        * fixture["logicalBlockByteCount"]
        + hidden["byteOffset"]
    )
    image.seek(offset)
    image.write(struct.pack("<I", start_block + 1))
    try:
        normalized_digest(image, fixture, start_block)
    except media.MediaError:
        return
    raise AssertionError(
        f"builder accepted corrupt {start_key} replica {relative_block}"
    )


def main() -> None:
    fixture = load_fixture()
    image = build_image(fixture)
    expected = bytes.fromhex(fixture["normalizedSHA256"])
    start_a = fixture["slotAStartBlock"]
    start_b = fixture["slotBStartBlock"]

    require(
        normalized_digest(image, fixture, start_a) == expected,
        "builder slot-A content digest disagrees with the golden",
    )
    require(
        normalized_digest(image, fixture, start_b) == expected,
        "builder slot-B content digest disagrees with the golden",
    )
    require(
        raw_digest(image, fixture, start_a)
        != raw_digest(image, fixture, start_b),
        "golden does not exercise physical BPB_HiddSec differences",
    )

    for start_key in ("slotAStartBlock", "slotBStartBlock"):
        for relative_block in fixture["fat32HiddenSectors"]["relativeBlocks"]:
            require_replica_validation(fixture, start_key, relative_block)

    print("Raspberry Pi A/B revision-three digest golden: passed")


if __name__ == "__main__":
    main()
