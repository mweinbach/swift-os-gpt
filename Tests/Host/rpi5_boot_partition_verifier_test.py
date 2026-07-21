#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile


REPOSITORY = Path(__file__).resolve().parents[2]
PACKAGER = REPOSITORY / "Boards/RaspberryPi5/package-boot.sh"
MEDIA_TOOL = REPOSITORY / "tools/build_rpi5_media.py"
VERIFIER = REPOSITORY / "tools/verify_rpi5_boot_partition.py"
sys.path.insert(0, str(Path(__file__).parent))
from rpi5_package_contract import make_firmware_checkout, write_image  # noqa: E402


def run(*command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


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


def verify(
    image: Path,
    *,
    partition_image: bool = False,
    slot: str = "both",
    expected_manifest: Path | None = None,
    should_succeed: bool = True,
) -> dict[str, object] | str:
    command = [sys.executable, str(VERIFIER), str(image)]
    if partition_image:
        command.append("--partition-image")
    command.extend(("--slot", slot))
    if expected_manifest is not None:
        command.extend(("--expected-sha256sums", str(expected_manifest)))
    result = run(*command)
    if should_succeed:
        require(result.returncode == 0,
                f"boot verification failed: {result.stdout}")
        return json.loads(result.stdout)
    require(result.returncode != 0, "corrupt boot payload passed verification")
    return result.stdout


def boot_extent(image: Path, slot: str = "a") -> tuple[int, int]:
    with image.open("rb") as source:
        mbr = source.read(512)
    require(mbr[510:512] == b"\x55\xaa", "fixture MBR is invalid")
    offset = 470 if slot == "a" else 486
    return struct.unpack_from("<II", mbr, offset)


def fat_geometry(image: Path, boot_start: int) -> tuple[int, int, int, int]:
    with image.open("rb") as source:
        source.seek(boot_start * 512)
        bpb = source.read(512)
    sectors_per_cluster = bpb[13]
    reserved = struct.unpack_from("<H", bpb, 14)[0]
    fat_count = bpb[16]
    fat_sectors = struct.unpack_from("<I", bpb, 36)[0]
    root_cluster = struct.unpack_from("<I", bpb, 44)[0]
    data_start = boot_start + reserved + fat_count * fat_sectors
    return sectors_per_cluster, reserved, root_cluster, data_start


def cluster_offsets(
    image: Path,
    boot_start: int,
    first_cluster: int,
) -> list[int]:
    sectors_per_cluster, reserved, _, data_start = fat_geometry(
        image,
        boot_start,
    )
    offsets: list[int] = []
    visited: set[int] = set()
    cluster = first_cluster
    with image.open("rb") as source:
        while cluster < 0x0FFF_FFF8:
            require(cluster >= 2 and cluster not in visited,
                    "fixture FAT chain is invalid")
            visited.add(cluster)
            offsets.append(
                (data_start + (cluster - 2) * sectors_per_cluster) * 512
            )
            source.seek((boot_start + reserved) * 512 + cluster * 4)
            encoded = source.read(4)
            require(len(encoded) == 4, "fixture FAT entry is truncated")
            cluster = struct.unpack("<I", encoded)[0] & 0x0FFF_FFFF
    return offsets


def root_directory_offsets(image: Path, boot_start: int) -> list[int]:
    _, _, root_cluster, _ = fat_geometry(image, boot_start)
    return cluster_offsets(image, boot_start, root_cluster)


def add_unrelated_host_metadata(image: Path, boot_start: int) -> None:
    """Mutate FAT bookkeeping and add an untraversable unrelated directory."""

    sectors_per_cluster, _, _, _ = fat_geometry(image, boot_start)
    root_offsets = root_directory_offsets(image, boot_start)
    with image.open("r+b") as target:
        # FAT32 free-cluster counts are advisory and are routinely rewritten by
        # a mounting host. They are deliberately outside semantic verification.
        for fsinfo_sector in (1, 7):
            target.seek((boot_start + fsinfo_sector) * 512 + 488)
            target.write(struct.pack("<I", 12_345))

        root_offset: int | None = None
        root = bytearray()
        insertion: int | None = None
        for candidate_offset in root_offsets:
            target.seek(candidate_offset)
            candidate = bytearray(target.read(sectors_per_cluster * 512))
            for offset in range(0, len(candidate), 32):
                if candidate[offset] == 0:
                    root_offset = candidate_offset
                    root = candidate
                    insertion = offset
                    break
            if insertion is not None:
                break
        require(root_offset is not None and insertion is not None,
                "fixture root directory has no free entry")
        entry = bytearray(32)
        entry[0:11] = b"SPOTLI~1   "
        entry[11] = 0x10
        unrelated_cluster = 60_000
        struct.pack_into("<H", entry, 20, unrelated_cluster >> 16)
        struct.pack_into("<H", entry, 26, unrelated_cluster & 0xFFFF)
        root[insertion:insertion + 32] = entry
        target.seek(root_offset)
        target.write(root)


def corrupt_kernel(image: Path, boot_start: int) -> None:
    sectors_per_cluster, _, _, data_start = fat_geometry(image, boot_start)
    root_offsets = root_directory_offsets(image, boot_start)
    with image.open("r+b") as target:
        first_cluster: int | None = None
        for root_offset in root_offsets:
            target.seek(root_offset)
            root = target.read(sectors_per_cluster * 512)
            for offset in range(0, len(root), 32):
                entry = root[offset:offset + 32]
                if entry[0] == 0:
                    break
                if entry[0:11] == b"KERNEL8 IMG":
                    first_cluster = (
                        struct.unpack_from("<H", entry, 20)[0] << 16
                        | struct.unpack_from("<H", entry, 26)[0]
                    )
                    break
            if first_cluster is not None:
                break
        require(first_cluster is not None, "kernel fixture entry is missing")
        kernel_offset = (
            data_start + (first_cluster - 2) * sectors_per_cluster
        ) * 512
        target.seek(kernel_offset)
        original = target.read(1)
        require(len(original) == 1, "kernel fixture is truncated")
        target.seek(kernel_offset)
        target.write(bytes([original[0] ^ 0xFF]))


def main() -> int:
    with tempfile.TemporaryDirectory(
        prefix="swiftos-rpi5-boot-verifier-"
    ) as temporary:
        root = Path(temporary)
        package = package_fixture(root)
        pristine = root / "pristine.img"
        build(package, pristine)
        boot_start, boot_count = boot_extent(pristine)

        report = verify(
            pristine,
            expected_manifest=package / "SHA256SUMS",
        )
        manifest_entries = (package / "SHA256SUMS").read_text().splitlines()
        require(report["required_file_count"] == len(manifest_entries),
                "verifier did not cover every manifest-listed file")
        require(report["manifest"]["matched_expected_copy"],
                "trusted manifest equality was not reported")
        require(report["unrelated_entries"] == "not-traversed",
                "unrelated-entry policy changed")
        require(report["selected_slots"] == ["A", "B"],
                "whole-media verification did not cover both slots")
        require(
            report["boot_slots"]["A"]["manifest"]["matched_expected_copy"]
            and report["boot_slots"]["B"]["manifest"]["matched_expected_copy"],
            "trusted manifest was not checked against both slots",
        )

        metadata = root / "host-metadata.img"
        shutil.copyfile(pristine, metadata)
        add_unrelated_host_metadata(metadata, boot_start)
        metadata_report = verify(metadata)
        require(metadata_report["required_file_count"] == len(manifest_entries),
                "host metadata hid a required file")

        strict = run(sys.executable, str(MEDIA_TOOL), "inspect", str(metadata))
        require(strict.returncode != 0 and "invalid cluster" in strict.stdout,
                "strict full-image inspection unexpectedly ignored bad extras")

        partition = root / "boot-partition.img"
        with metadata.open("rb") as source, partition.open("wb") as target:
            source.seek(boot_start * 512)
            shutil.copyfileobj(source, target, length=1_024 * 1_024)
            target.truncate(boot_count * 512)
        partition_report = verify(
            partition,
            partition_image=True,
            slot="a",
        )
        require(partition_report["source"]["layout"] == "fat32-partition-image",
                "partition-image mode was not reported")
        require(partition_report["fat32"]["hidden_sectors"] == 0,
                "canonical A/B slot gained partition-specific metadata")

        corrupt = root / "corrupt-required-file.img"
        shutil.copyfile(pristine, corrupt)
        corrupt_kernel(corrupt, boot_start)
        error = verify(corrupt, should_succeed=False)
        require(
            "required-file checksum mismatch: kernel8.img" in error,
            "required-file corruption did not name the failed boot file",
        )

        # A diagnostic may deliberately inspect the known-good slot even when
        # its peer is damaged, while the default whole-media policy must cover
        # and reject either broken slot.
        corrupt_b = root / "corrupt-slot-b.img"
        shutil.copyfile(pristine, corrupt_b)
        slot_b_start, _ = boot_extent(corrupt_b, "b")
        corrupt_kernel(corrupt_b, slot_b_start)
        slot_a_report = verify(corrupt_b, slot="a")
        require(slot_a_report["selected_slots"] == ["A"],
                "slot-specific verification did not remain scoped to A")
        error = verify(corrupt_b, should_succeed=False)
        require(
            "required-file checksum mismatch: kernel8.img" in error,
            "slot B corruption passed whole-media verification",
        )

        wrong_manifest = root / "wrong-SHA256SUMS"
        wrong_manifest.write_bytes(b"not the trusted manifest\n")
        error = verify(
            pristine,
            expected_manifest=wrong_manifest,
            should_succeed=False,
        )
        require("differs from the expected manifest" in error,
                "trusted manifest mismatch was not rejected")

    print("Raspberry Pi 5 boot partition verifier: 6 groups passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
