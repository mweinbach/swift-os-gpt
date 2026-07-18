#!/bin/sh

set -eu

export LC_ALL=C

usage() {
    echo "usage: $0 KERNEL_IMAGE RASPBERRYPI_FIRMWARE_CHECKOUT EMPTY_OUTPUT_DIRECTORY" >&2
    exit 64
}

fail() {
    echo "package-boot: $*" >&2
    exit 1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        fail "sha256sum or shasum is required"
    fi
}

[ "$#" -eq 3 ] || usage

KERNEL_IMAGE=$1
FIRMWARE_CHECKOUT=$2
OUTPUT_DIRECTORY=$3
SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIRMWARE_DTB="$FIRMWARE_CHECKOUT/boot/bcm2712-rpi-5-b.dtb"
SWIFTOS_REPOSITORY=$(git -C "$SCRIPT_DIRECTORY" rev-parse --show-toplevel 2>/dev/null) || \
    fail "board files must be inside the SwiftOS Git checkout"

[ -f "$KERNEL_IMAGE" ] || fail "kernel image not found: $KERNEL_IMAGE"
[ -s "$KERNEL_IMAGE" ] || fail "kernel image is empty: $KERNEL_IMAGE"
[ -f "$FIRMWARE_DTB" ] || fail "Pi 5 DTB not found: $FIRMWARE_DTB"
[ -f "$SCRIPT_DIRECTORY/config.txt" ] || fail "board config.txt is missing"
[ -f "$SCRIPT_DIRECTORY/boot-manifest.txt" ] || fail "board manifest is missing"

FIRMWARE_REVISION=$(git -C "$FIRMWARE_CHECKOUT" rev-parse --verify HEAD 2>/dev/null) || \
    fail "firmware input must be a pinned raspberrypi/firmware Git checkout"
SWIFTOS_REVISION=$(git -C "$SWIFTOS_REPOSITORY" rev-parse --verify HEAD 2>/dev/null) || \
    fail "could not determine the SwiftOS Git revision"
if [ -n "$(git -C "$SWIFTOS_REPOSITORY" status --porcelain --untracked-files=all)" ]; then
    SWIFTOS_DIRTY=true
else
    SWIFTOS_DIRTY=false
fi

case "$FIRMWARE_REVISION" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]* ) ;;
    * ) fail "could not determine firmware Git revision" ;;
esac

FIRMWARE_ORIGIN=$(git -C "$FIRMWARE_CHECKOUT" config --get remote.origin.url 2>/dev/null) || \
    fail "firmware checkout has no remote.origin.url"
case "$FIRMWARE_ORIGIN" in
    https://github.com/raspberrypi/firmware | \
    https://github.com/raspberrypi/firmware.git | \
    git@github.com:raspberrypi/firmware.git | \
    ssh://git@github.com/raspberrypi/firmware.git ) ;;
    * ) fail "firmware checkout is not from raspberrypi/firmware: $FIRMWARE_ORIGIN" ;;
esac

git -C "$FIRMWARE_CHECKOUT" cat-file -e \
    "$FIRMWARE_REVISION:boot/bcm2712-rpi-5-b.dtb" 2>/dev/null || \
    fail "firmware revision does not contain the Pi 5 DTB"
git -C "$FIRMWARE_CHECKOUT" diff --quiet HEAD -- \
    boot/bcm2712-rpi-5-b.dtb || \
    fail "Pi 5 DTB differs from the recorded firmware revision"

if [ -d "$OUTPUT_DIRECTORY" ] && \
   [ -n "$(find "$OUTPUT_DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    fail "output directory must be empty: $OUTPUT_DIRECTORY"
fi

mkdir -p "$OUTPUT_DIRECTORY"

MAGIC_BYTES=$(dd if="$KERNEL_IMAGE" bs=1 skip=56 count=4 2>/dev/null | \
    od -An -tx1 -v | tr -d ' \n')
[ "$MAGIC_BYTES" = "41524d64" ] || \
    fail "kernel image has no AArch64 Image magic at byte 56"

FLAG_BYTES=$(dd if="$KERNEL_IMAGE" bs=1 skip=24 count=8 2>/dev/null | \
    od -An -tx1 -v | tr -d ' \n')
[ "$FLAG_BYTES" = "0200000000000000" ] || \
    fail "kernel image must declare little-endian 4 KiB pages and default placement"

TEXT_OFFSET_BYTES=$(dd if="$KERNEL_IMAGE" bs=1 skip=8 count=8 2>/dev/null | \
    od -An -tx1 -v | tr -d ' \n')
[ "$TEXT_OFFSET_BYTES" = "0000080000000000" ] || \
    fail "kernel image must request the Pi 5 physical entry address 0x80000"

DTB_MAGIC_BYTES=$(dd if="$FIRMWARE_DTB" bs=1 count=4 2>/dev/null | \
    od -An -tx1 -v | tr -d ' \n')
[ "$DTB_MAGIC_BYTES" = "d00dfeed" ] || \
    fail "firmware input is not a flattened Device Tree blob"

cp "$SCRIPT_DIRECTORY/config.txt" "$OUTPUT_DIRECTORY/config.txt"
cp "$KERNEL_IMAGE" "$OUTPUT_DIRECTORY/kernel8.img"
cp "$FIRMWARE_DTB" "$OUTPUT_DIRECTORY/bcm2712-rpi-5-b.dtb"
cp "$SCRIPT_DIRECTORY/boot-manifest.txt" "$OUTPUT_DIRECTORY/BOOT-MANIFEST.txt"
chmod 0644 \
    "$OUTPUT_DIRECTORY/config.txt" \
    "$OUTPUT_DIRECTORY/kernel8.img" \
    "$OUTPUT_DIRECTORY/bcm2712-rpi-5-b.dtb" \
    "$OUTPUT_DIRECTORY/BOOT-MANIFEST.txt"

KERNEL_SHA256=$(sha256_file "$OUTPUT_DIRECTORY/kernel8.img")
DTB_SHA256=$(sha256_file "$OUTPUT_DIRECTORY/bcm2712-rpi-5-b.dtb")

{
    echo "format=swiftos-rpi5-boot-v1"
    echo "board=raspberry-pi-5-model-b"
    echo "hardware_verified=false"
    echo "swiftos_revision=$SWIFTOS_REVISION"
    echo "swiftos_dirty=$SWIFTOS_DIRTY"
    echo "firmware_repository=https://github.com/raspberrypi/firmware.git"
    echo "firmware_repository_revision=$FIRMWARE_REVISION"
    echo "kernel_sha256=$KERNEL_SHA256"
    echo "dtb_sha256=$DTB_SHA256"
} > "$OUTPUT_DIRECTORY/BUILD-METADATA.txt"
chmod 0644 "$OUTPUT_DIRECTORY/BUILD-METADATA.txt"

{
    for FILE_NAME in \
        BOOT-MANIFEST.txt \
        BUILD-METADATA.txt \
        bcm2712-rpi-5-b.dtb \
        config.txt \
        kernel8.img
    do
        printf '%s  %s\n' \
            "$(sha256_file "$OUTPUT_DIRECTORY/$FILE_NAME")" \
            "$FILE_NAME"
    done
} > "$OUTPUT_DIRECTORY/SHA256SUMS"
chmod 0644 "$OUTPUT_DIRECTORY/SHA256SUMS"

echo "Packaged UNVERIFIED Raspberry Pi 5 boot files in $OUTPUT_DIRECTORY"
