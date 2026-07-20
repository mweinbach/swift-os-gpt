# Raspberry Pi 5 board target

> **Hardware status: early bring-up verified, target not supported.** One exact
> SwiftOS artifact has booted on a Raspberry Pi 5 8 GB through FDT parsing,
> memory ownership and final paging, GICv2/timers, CPU0 plus three PSCI-started
> secondaries, SD, SwiftFS, and first persistent-log flush. USB enumeration,
> Ethernet link, HDMI,
> native V3D VII/HVS rendering, input, and Pi EL0 scheduling remain unverified.
> See the [2026-07-20 returned-card evidence](hardware-evidence/2026-07-20-pi5-8gb-9e93dac.md).
> No general hardware-support claim is permitted until the validation gate
> below passes.

The initial physical research target is Raspberry Pi 5 Model B with 8 GB RAM.
The board uses BCM2712, four Cortex-A76 cores, and the RP1 I/O controller. The
guest remains freestanding Embedded Swift: Raspberry Pi OS, Linux code, Apple
frameworks, SwiftUI, Metal, and Darwin are not part of the boot artifact.

The board target has its own standard Image header, link address, high-MMIO
bootstrap descriptors, firmware configuration, and packaging contract. Shared
Swift code discovers QEMU GICv3 or Pi GICv2, owns DT-described RAM, builds final
permissioned mappings, and selects HVC or SMC PSCI by the DT. QEMU provides the
repeatable cross-machine proof; the returned-card trace independently confirms
that the BCM2712 FDT, roughly 8 GB memory map, final tables, GICv2 timer path,
and four-core PSCI work executed on the physical board. It does not prove every
driver or the complete support gate.

## Boot partition and firmware handoff

Raspberry Pi 5 keeps its boot firmware in EEPROM. It does not use
`bootcode.bin`, `start*.elf`, or `fixup*.dat`; it does require a non-empty
`config.txt`. The deterministic file set produced by
`Boards/RaspberryPi5/package-boot.sh` is:

| File | Purpose |
| --- | --- |
| `config.txt` | Selects the 64-bit image and debug handoff. |
| `kernel8.img` | Raw SwiftOS AArch64 Image with a 4 KiB-page header. |
| `bcm2712-rpi-5-b.dtb` | Source hardware description, patched by firmware at boot. |
| `overlays/dwc2.dtbo` | Official firmware overlay selecting the USB-C DWC2 controller. |
| `BOOT-MANIFEST.txt` | Human-readable, explicitly unverified manifest. |
| `BUILD-METADATA.txt` | Input hashes, SwiftOS revision/dirty state, and firmware-repository revision. |
| `MEDIA-LAYOUT.txt` | MBR, FAT32 boot, signed data-volume, and arena contract. |
| `SHA256SUMS` | Stable byte-level hashes of all preceding files. |

The firmware normally prefers `kernel_2712.img` on BCM2712 and falls back to
`kernel8.img`. Raspberry Pi documents `kernel8.img` as a BCM2712-capable common
64-bit image, so this package explicitly chooses that name for SwiftOS's 4 KiB
mapping contract. The AArch64 Image header declares the 4 KiB page-size encoding,
and the board linker aligns executable and mapping storage to 4 KiB.

The DTB and DWC2 overlay come from `boot/bcm2712-rpi-5-b.dtb` and
`boot/overlays/dwc2.dtbo` in a caller-supplied, pinned
checkout of [raspberrypi/firmware](https://github.com/raspberrypi/firmware).
The packager verifies both files against that Git revision, records their
individual hashes, and refuses to overwrite a non-empty directory. That value
identifies the `raspberrypi/firmware` file set, not the board's EEPROM bootloader
revision; physical evidence must record the EEPROM build separately. Given
identical kernel bytes, firmware checkout, and board files, the listed file
bytes and `SHA256SUMS` are reproducible. `tools/build_rpi5_media.py` gives the
FAT allocation, timestamps, volume ID, MBR, and signed data headers deterministic
values, so two builds with the same package and geometry are byte-identical.

`config.txt` applies `dwc2,dr_mode=peripheral`. The merged runtime DT can then
publish an enabled `brcm,bcm2835-usb` node, which shared platform discovery
translates through its parent `ranges` into a controller-neutral DWC2 MMIO
resource. If `dr_mode` is present, SwiftOS accepts only `peripheral`; QEMU does
not publish this resource. SwiftOS retains that mapping, requests the legacy
firmware power domain or accepts a well-formed unavailable response as
unmanaged, and binds the same board-neutral DWC2 device controller used by host
tests. Physical enumeration remains unverified.

Build and statically inspect the Pi image with:

```sh
make rpi5-inspect
```

Package it with a pinned firmware checkout:

```sh
RPI5_FIRMWARE=/path/to/pinned/raspberrypi-firmware make rpi5-package
```

This writes both the validated boot directory and
`.build/raspberry-pi-5/swiftos-rpi5-media.img`. The default image is a compact
sparse 1 GiB artifact with a 256 MiB boot partition. For physical media, pass
the exact 512-byte block count so partition two spans the remainder:

```sh
RPI5_FIRMWARE=/path/to/pinned/raspberrypi-firmware \
RPI5_MEDIA_BLOCK_COUNT=EXACT_CARD_BLOCK_COUNT make rpi5-package
python3 tools/build_rpi5_media.py inspect \
  .build/raspberry-pi-5/swiftos-rpi5-media.img
```

The builder refuses existing outputs and every non-regular-file target; it does
not select, unmount, or write a physical disk. Its inspector validates bounded
partition/FAT extents, every packaged file hash, duplicate data superblocks, and
CRC-protected persistent records. Flashing remains a separate explicitly
targeted operation. Do not add Raspberry Pi 4 firmware blobs. `sha256=1` asks
the EEPROM firmware to log
the hashes of loaded files; it does not replace checking `SHA256SUMS` before
writing media.

## Physical media lifecycle and returned-card diagnostics

SwiftOS uses three separate media workflows. Do not describe a boot-partition
copy as flashing a card, and do not describe a live USB update as installed.

Before **every** card operation, power the Pi off, insert the card into the Mac,
and run `diskutil list external physical`. Resolve the removable whole disk
again from current media name, capacity, and partition layout. Verify with
`diskutil info /dev/diskN` that it has the expected exact capacity, a 512-byte
device block size, `Internal: No`, and `Whole: Yes`. Trace any mounted boot
volume back to that same whole disk. Never reuse a disk number from an earlier
insertion, never use `diskNs1` where a whole-disk operation is required, and
never touch a protected or unrelated disk. Stop when identity, geometry, or
ownership is ambiguous.

### First whole-card initialization: destructive

This is the only current workflow that creates the complete media layout. It
overwrites the whole card with an MBR, a FAT32 firmware boot partition, and a
signed type-`0xda` data partition containing the persistent-log arena and
SwiftFS range. It destroys every previous partition and file on that card.

Build the image with that card's exact 512-byte block count, inspect it, and
independently check the default 256 MiB FAT32 boot partition before flashing:

```sh
RPI5_FIRMWARE=/path/to/pinned/raspberrypi-firmware \
RPI5_MEDIA_BLOCK_COUNT=EXACT_CARD_BLOCK_COUNT make rpi5-package
python3 tools/build_rpi5_media.py inspect \
  .build/raspberry-pi-5/swiftos-rpi5-media.img
dd if=.build/raspberry-pi-5/swiftos-rpi5-media.img \
  of=/private/tmp/swiftos-rpi5-boot-fat.img bs=512 skip=2048 count=524288
/sbin/fsck_msdos -n /private/tmp/swiftos-rpi5-boot-fat.img
```

The builder refuses an existing output, so move an earlier boot directory and
media image aside instead of silently overwriting release evidence. For the
initial card write, unmount the verified whole disk and write the exact-card
image to its raw whole-disk node; substitute the freshly resolved `N` in both
commands and check it again before entering the privileged command:

```sh
diskutil unmountDisk /dev/diskN
sudo dd if=.build/raspberry-pi-5/swiftos-rpi5-media.img \
  of=/dev/rdiskN bs=4m
sync
diskutil eject /dev/diskN
```

This full initial write can be slow because the sparse image expands to the
card's exact geometry. After ejection completes, remove the card, place it in
the powered-off Pi, and only then apply power.

### Normal boot-partition update: preserves user data

Once the card has the complete SwiftOS layout, later persistent kernel and
firmware updates normally replace files on partition one only. This procedure
does not change the MBR or type-`0xda` partition, so existing SwiftFS files and
persistent logs remain intact.

Power the Pi down and re-resolve the whole card as above. Mount its FAT32 boot
partition and trace that mount back to the verified whole disk. Before copying,
require the existing volume to contain `BOOT-MANIFEST.txt`,
`MEDIA-LAYOUT.txt`, and `SHA256SUMS`; otherwise stop instead of guessing that an
arbitrary FAT volume is SwiftOS media. Then copy the package contents without a
deleting sync and verify every new packaged byte on the destination:

```sh
BOOT_PACKAGE=.build/raspberry-pi-5/boot
BOOT_VOLUME=/Volumes/SWIFTOS
test -f "$BOOT_VOLUME/BOOT-MANIFEST.txt"
test -f "$BOOT_VOLUME/MEDIA-LAYOUT.txt"
test -f "$BOOT_VOLUME/SHA256SUMS"
(cd "$BOOT_PACKAGE" && shasum -a 256 -c SHA256SUMS)
rsync -rt --checksum --exclude SHA256SUMS "$BOOT_PACKAGE/" "$BOOT_VOLUME/"
rsync -t --checksum "$BOOT_PACKAGE/SHA256SUMS" "$BOOT_VOLUME/SHA256SUMS"
(cd "$BOOT_VOLUME" && shasum -a 256 -c SHA256SUMS)
sync
diskutil unmountDisk /dev/diskN
sudo python3 tools/verify_rpi5_boot_partition.py /dev/rdiskN \
  --expected-block-count EXACT_CARD_BLOCK_COUNT \
  --expected-sha256sums "$BOOT_PACKAGE/SHA256SUMS"
diskutil eject /dev/diskN
```

Substitute the actual verified mount and freshly resolved whole-disk number.
Do not use `dd`, repartition, erase, or format during this workflow. A plain FAT
copy is not a whole-card flash: it cannot create a missing type-`0xda`
partition. A card that was previously prepared as FAT-only therefore still has
no SwiftFS or persistent-log arena after this update; perform a deliberate
whole-card initialization when preserving its old contents is no longer
required. The semantic verifier follows only paths named by the package hash
manifest, so unrelated `.Spotlight-V100`, `.fseventsd`, and AppleDouble files
neither invalidate the boot payload nor expand the verifier's read scope.

### Live USB kernel update: volatile

The bounded USB updater can stage and chainload `kernel8.img` in RAM without
rewriting either partition. A `COMMITTED` response proves sealed staging, not a
microSD installation. Verify the disconnect, re-enumeration, and changed boot
identity for the live handoff. A power cycle returns to the kernel already on
the FAT32 partition. There is no supported guest-side command that installs the
RAM image to microSD; use the normal boot-partition procedure after powering
down when the update must persist.

### Returned-card persistent logs

After a failed physical boot, power down, return the card to the Mac, resolve
the whole disk and exact block count again, unmount it, then extract logs with
the read-only inspector:

```sh
diskutil unmountDisk /dev/diskN
sudo python3 tools/inspect_rpi5_persistent_log.py /dev/rdiskN \
  --expected-block-count EXACT_CARD_BLOCK_COUNT \
  > swiftos-pi5-log-capture.json
```

The inspector rejects partition nodes and symlinks, opens the source
`O_RDONLY`, verifies discovered geometry when the host exposes it, and reads
only the MBR, two signed superblocks, and bounded log arena. Its JSON preserves
structured records and reconstructs retained canonical console bytes in
chronological order. Every initialized volatile log starts with a structured
`BOOT` epoch record containing its initial counter tick, processor affinity,
DTB address, and counter frequency. The inspector reports these under
`boot_epoch_markers` and describes an unused arena explicitly as
`capture_summary.status = "empty"`; an empty console stream is never labelled
complete. The epoch and console records become durable only after the SD/log
service recovers the arena and drains the retained ring. An empty arena means
the boot never reached that crossing; use second-stage UART10 firmware output,
kernel UART10 output, or HDMI evidence for the earlier failure.
If the card never received a destructive whole-card initialization, the signed
type-`0xda` partition does not exist and there are no persistent SwiftOS logs to
inspect, regardless of how recently its FAT boot files were updated.

## SwiftOS data partition

The second MBR entry uses type `0xda` and is accepted only when its `SWOSDATA`
v1 superblock validates. Blocks zero and one are duplicate immutable headers.
The next 4,096 512-byte blocks form the default 2 MiB kernel-log arena; CRCs and
deterministic sequence-to-slot placement permit bounded recovery after a torn
write. The remaining user-data arena now has a host-tested SwiftFS layout and
provider. A pure range policy converts both relative arenas into disjoint,
bounded absolute SD ranges before either service receives authority. The
generic kernel exposes synchronous logical-block I/O and partition-bounded
views, but never maps raw media into EL0.

On Pi, the runtime binds the boot DT's removable `brcm,bcm2712-sdhci` node to a
bounded, default-speed 3.3 V PIO transport. The live SD device, SwiftFS scratch,
and provider records use stable classified allocations so borrowed block views
cannot outlive movable stack state. After the local USB/HDMI observation window,
the runtime initializes the card, requires an unambiguous MBR and at least one
valid signed superblock, then serializes one cooperative owner across log
recovery/appends and SwiftFS bootstrap. The resumable filesystem state machine
performs at most one block read, write, synchronize, or CPU-only validation
phase per pass. Returned media is never implicitly reformatted at the data-
volume layer; the SwiftFS subrange may be formatted only through the same blank-
volume policy used by QEMU. Any discovery,
signature, bounds, or transport failure drops the relevant write authority and
lets Ethernet troubleshooting continue. The published Pi provider has the same
board-neutral identity and seam as the QEMU VirtIO-backed provider.

Discovery now resolves and retains that controller's level-high GIC SPI
`0x111` (architectural INTID `0x131`) through its actual interrupt parent. The
current SDHCI transport remains synchronous and polled; retaining the validated
route is groundwork for an asynchronous driver, not a claim that SD IRQ delivery
has executed.

The first physical trace reached `SD_INIT_READY_BLOCKS`, read the MBR and
validated data superblock, formatted the blank SwiftFS range, and published
`SWIFTFS_READY`. Its recovery scan reported no previous record
(`STORAGE_LOG_RECOVERY_READY=0`) before it durably flushed the current boot.
That proves the bounded polled transport, initial provider path, and first log
persistence for one exact card. It does not prove prior-boot recovery, the
retained SD interrupt route, power-loss behavior during a write, or a subsequent
physical SwiftFS remount. QEMU's native VirtIO-block/SwiftFS multi-boot smoke
remains separate evidence.

## AArch64 Image contract

`ImageHeader.S` supplies the documented 64-byte AArch64 Image header and branches
to the repository's `_start` symbol. `linker.ld` places it at physical
`0x0008_0000`, immediately above the DT-reserved `[0, 0x80000)` ATF region. Its
`text_offset` is `0x80000`, `image_size` covers the linked memory reservation,
and flags select little-endian execution with a 4 KiB kernel page size.

This is the intended direct firmware path: Raspberry Pi firmware documents
uncompressed 64-bit `.img` files, and the standard header requests placement at
`0x80000`; the firmware then calls the first header instruction and supplies the
merged DTB through the Arm64 `x0` convention. In other words, no ELF loader,
Linux, U-Boot, or host shim is part of the artifact. The `9e93dac` returned-card
trace proves this direct handoff booted on one board/EEPROM combination. Its
EEPROM build was not retained, so broader firmware compatibility remains
unverified.

The firmware-to-kernel register contract is:

- `x0`: physical address of the merged DTB, aligned to at least eight bytes;
- `x1`, `x2`, `x3`: reserved and zero;
- interrupts masked;
- MMU off, with the image coherent in memory;
- non-secure EL2 preferred, or EL1;
- `CNTFRQ` initialized and `CNTVOFF` consistent across CPUs.

The entry path preserves `x0` until Swift validates the FDT header and treats
its addresses as physical until board page tables are live. The Pi build uses a
bootstrap-only identity map for `0...8 GiB` so the 8 GB target's firmware may
place the DTB in any RAM bank, plus one identity descriptor for the BCM2712 high
MMIO window containing UART10 and GICv2. `make rpi5-inspect` checks that MMIO
descriptor together with the Image entry/reset addresses, AArch64 identity,
4 KiB flags, and absence of unresolved symbols. The broad normal-memory map is
replaced by owned final tables after DT parsing. The physical trace proves that
transition completed, but it does not retain enough interval detail to account
for every temporarily mapped bootstrap hole or reservation.

The Pi ELF contains the same range-based memory runtime, final permissioned
tables and guards, PSCI startup code, and separately linked EL0 Swift image used
by the QEMU milestone. The returned-card trace proves that the memory, final-map,
and PSCI paths executed on the Pi. It contains no scheduler or EL0 markers, so
the linked user image and cross-core EL0 runtime remain physically unproven.

## Device-tree contract

The firmware loads and tailors the DTB before passing its address in `x0`.
Board bring-up must accept the patched tree as authority and check the root
compatible strings for `raspberrypi,5-model-b` and `brcm,bcm2712` before using
any Pi 5 emergency fallback.

The parser does more than find nodes by name. It currently:

1. reads inherited `#address-cells`, `#size-cells`, and explicit or inherited
   `interrupt-parent` values;
2. translates each selected `reg` tuple through every parent `ranges` level,
   searches every tuple in a multi-window bus, and rejects ambiguous matches;
3. ignores unavailable nodes and ancestors and binds by `compatible` rather
   than unit-address spelling;
4. resolves a unique interrupt-controller phandle, uses that controller's
   `#interrupt-cells` to count tuples, and decodes supported GIC SPI/PPI routes;
   and
5. preserves 64-bit physical addresses throughout discovery and mapping.

The package gate probes the actual pinned Pi DTB and requires translated UART10
at `0x107d001000`, GICD at `0x107fff9000`, GICC at `0x107fffa000`, PSCI `smc`,
four affinities, and the ATF reservation. It also resolves the timer's second
tuple as non-secure physical PPI 14/architectural INTID 30 with a GICv2 processor
mask of `0x0f`, and the removable SDHCI interrupt as SPI `0x111`/architectural
INTID `0x131`. Unsupported interrupt nexuses and `interrupts-extended` fail
closed; `/aliases` plus `/chosen/stdout-path` resolution remains future work.
That parser proof is not hardware execution.

## Eight-gigabyte memory ownership

The source DTS intentionally leaves the `/memory` size for firmware to fill, so
the final ownership model does not assume one contiguous 8 GB range and does not
set `total_mem` in `config.txt`. The shared memory runtime enumerates every
enabled memory tuple as checked `UInt64` ranges, requires the complete DTB span
to lie inside described RAM, subtracts FDT reservation-map and
`/reserved-memory` spans, and reserves the kernel and final-table pool before
publishing pages to its live classified allocator. The initial runtime class is
system DRAM; the allocator independently represents allocation domain,
capabilities, proximity, maximum address, and explicit fallback, with an active
ownership-token ledger. Its tested model can also represent CPU-inaccessible
device-local memory without mapping it as ordinary RAM. The final map gives
text/data/user/device regions distinct permissions and leaves boot, secondary,
and user stack guards unmapped.

Those ownership and table transitions are exercised on QEMU, including host
tests for split ranges, overlap, permissions, and guards. The physical trace
records `USABLE_PAGES=0x1fdb6c`, `PAGING_READY`, and 50 final table pages from a
firmware-patched 8 GB map. It does not yet retain every source and subtracted
interval or prove an allocation above 4 GiB. The distinct-address DMA model and
memory-domain allocator exist, but no Pi peripheral or IOMMU integration has
supplied a non-identity or noncoherent mapping. Full acceptance still requires
accounting for every reported byte with no overflow, alias, or truncation.

## Early serial: BCM2712 UART10 only

The only early-debug route is the PL011-compatible UART10 on Raspberry Pi 5's
dedicated three-pin debug connector. Until alias/stdout-path resolution lands,
Pi discovery enumerates enabled PL011 resources, translates them through DT
`ranges`, and accepts only the UART10 physical address `0x107d001000` with a
sufficient register span. The actual pinned firmware-DTB probe enforces that
translation rather than selecting the first PL011 node.

`enable_uart=1` and `uart_2ndstage=1` are explicit boot preconditions. The
current PL011 driver does not program UART10 clocks, baud, pinmux, or control
registers, so physical serial still depends on firmware leaving the dedicated
debug UART operational. TX-full polling is bounded per byte; the complete
message is retained first and UART emission stops at the first failed byte, so
a dead or uninitialized UART cannot indefinitely block later boot work.
`pciex4_reset=0` preserves the bootloader's internal RP1 PCIe configuration;
SwiftOS then discovers and maps only the DT-described GEM, configuration, power,
and reset resources required by its Ethernet driver. It does not enumerate the
root complex, expose the general RP1 aperture, or claim ownership of unrelated
RP1/PCIe DMA.

RP1 Ethernet board-preparation failures retain four stable diagnostic markers
before the existing `SWIFTOS:RP1_NET_BOARD_FAILED` or `_TIMEOUT` marker:
`RP1_NET_BOARD_STAGE`, `_REGISTER`, `_EXPECTED`, and `_OBSERVED`. Stage values
are `0x1` invalid configuration; `0x2`, `0x3`, and `0x4` SYS, Ethernet, and
timestamp clock-enable readback; `0x5` reset-GPIO layout; `0x6` asserted output;
`0x7` output enable; `0x8` SYS_RIO function selection; `0x9` pad output enable;
`0xa` asserted pad status; `0xb` invalid reset-delay counter; `0xc` reset-delay
timeout; `0xd` deasserted output; and `0xe` deasserted pad status. Register is
zero for validation/counter stages. For MMIO stages it is the translated RP1
address that was read back, while expected and observed preserve the exact
values needed to distinguish a wrong aperture from an ignored clock or GPIO
write.

## USB-C diagnostic display

USB-C is a post-boot debug transport, not the early console and not a
DisplayPort signal. After final mappings are installed, SwiftOS:

1. uses the discovered `brcm,bcm2835-mbox` aperture and property channel 8 to
   request legacy firmware USB device ID 3 with a bounded wait; a well-formed
   `device unavailable` response transfers the decision to the DT-discovered
   DWC2 driver, while malformed or mismatched state still fails closed;
2. validates the DWC2 identity, device-mode endpoint/FIFO capabilities, UTMI
   PHY width, and dynamic FIFO plan before attaching to the host;
3. initializes the core in polled PIO device mode and enumerates one composite
   CDC ACM plus vendor-debug configuration; and
4. streams versioned, sequenced, CRC-protected full frames and damage updates
   over CDC data endpoint 2 only while the host has asserted DTR.

The DT power-domain index for USB is 6, but Raspberry Pi's own power-domain
driver deliberately maps that logical domain to the legacy `SET_POWER_STATE`
USB device ID 3. SwiftOS follows the same split instead of treating those two
number spaces as interchangeable.

The source surface is the same completed diagnostic scanout presented over
HDMI simplefb. If firmware supplies no supported simple framebuffer, the kernel
creates an 800 x 600 XRGB surface and keeps the Pi in its monitor loop so polled
USB and animation continue to advance. Both Pi routes currently use the
diagnostic CPU compositor; USB transport does not make them V3D-rendered.

On macOS, build and launch the repository's host-only AppKit viewer:

```sh
make usb-display-viewer
.build/swiftos-usb-display --list
.build/swiftos-usb-display
```

The viewer waits for `/dev/cu.usbmodem*`, pulses DTR on each open, validates the
SDDP session/mode/frame stream, and presents at the guest's reported resolution,
scale, PPI, and refresh metadata. Unknown Pi simplefb PPI and refresh remain
unknown rather than being invented. AppKit, Foundation, Dispatch, and Darwin
remain confined to `tools/USBDisplay`; none link into the boot artifact.

Expected UART markers are `SWIFTOS:USB_POWER_READY` or
`SWIFTOS:USB_POWER_UNMANAGED`, followed by
`SWIFTOS:USB_DEBUG_ATTACHED`, `SWIFTOS:USB_DEBUG_CONFIGURED`, and
`SWIFTOS:USB_DEBUG_FRAME`. Failures before SD log recovery remain visible only
on UART10; later pre-USB failures can also be recovered from the returned card.
Before activation, the kernel records whether the firmware mailbox, DWC2
controller, and simple framebuffer were discovered, missing, or unsupported.
If DWC2 initialization fails after MMIO becomes accessible, it emits one typed
stage marker plus the read-only pre-reset `GSNPSID` and `GHWCFG1` through
`GHWCFG4` words. Retain those values with the boot identity; they distinguish a
wrong core/resource from AHB-idle, reset, mode, power-programming, and FIFO
timeouts without treating any failed path as hardware support.
The host-test suite covers descriptors, control transactions,
reset/reconnect, DTR restart, frame chunking, CRC, damage assembly, and viewer
bounds, but no physical Pi has passed the complete enumeration sequence yet.
The 2026-07-20 artifact stopped at its former generic `USB_POWER_STATE` marker;
the corrected unmanaged handoff still requires a new physical trace.

## Interrupt controller and timer

BCM2712's DT describes an `arm,gic-400` GICv2, while the QEMU reference board
uses GICv3. Platform discovery now selects the controller by `compatible` and
constructs the matching Swift driver from discovered `reg` resources. The
parser now resolves the timer node's inherited or explicit interrupt parent,
uses the selected controller's `#interrupt-cells`, and selects tuple 1 from the
`arm,armv8-timer` binding. In the pinned Pi DTB this is a level-low GIC PPI 14,
architectural INTID 30, with processor mask `0x0f`; the kernel requires that
mask to cover every one of its four managed processors.

GIC initialization is split into one CPU0 distributor operation and one local
operation per processor. The Pi target therefore programs each core's banked
GICv2 PPI state and GICC interface independently and keeps timer state, hooks,
counters, and fatal diagnostics per dense `TPIDR_EL1` ID. The same shared code
is boot-tested on QEMU GICv2 and GICv3 from both EL1 and EL2, including repeating
secondary-local physical-timer delivery, acknowledgement, EOI, and rearming.
That is QEMU evidence, not BCM2712 evidence.

The first returned-card trace reached `GIC_READY`, then recorded nonzero
processor-local timer IRQ counts on CPUs 1, 2, and 3 and CPU0's repeating timer
milestones. This is physical execution evidence for the selected GICv2/timer
path, but it is not yet the complete register/route trace required by the support
gate. If Pi SMP bring-up fails, `SWIFTOS:SMP_DEFERRED` preserves later
display/USB diagnosis instead of manufacturing success. QEMU's corresponding
smoke proof remains strict and fail-stop.

## Multicore bring-up

The four enabled CPU nodes are Cortex-A76 cores with DT affinity values `0x000`,
`0x100`, `0x200`, and `0x300`, each with `enable-method = "psci"`. The DT's PSCI
node advertises PSCI 1.0/0.2 using the `smc` conduit. The implemented bring-up
contract is:

1. Enumerate enabled CPU nodes and decode each 64-bit `reg` affinity.
2. Match the boot CPU using the affinity fields from `MPIDR_EL1`, not only Aff0.
3. Keep secondaries offline until memory ownership, page tables, vectors, and a
   distinct aligned stack are ready.
4. Invoke the standard PSCI `CPU_ON` call through `smc` for each target affinity,
   passing a SwiftOS-owned physical secondary-entry address and context value.
5. At secondary entry, establish the same translation/coherency regime, install
   the dense PSCI context in `TPIDR_EL1`, acquire a unique stack, enter Swift,
   validate that ID, and initialize the calling core's local GICv2/timer state.
6. Publish online state, consume two prepublished affinity-pinned Swift work
   slots one bounded quantum per local physical-timer IRQ, then disable the timer
   and release-publish results before parking.
7. Time out and report each failed PSCI return; never silently reduce the CPU
   count or assume spin-table release addresses.

The CPU topology now carries packed processor class, capability, proximity, and
startup-eligibility metadata separately from a validated boot-resource limit.
This path is proven in QEMU through the DT-selected HVC conduit for direct EL1
entry and SMC conduit for the virtualization/EL2 scenario, using both GICv3 and
GICv2. CPU0 accepts each secondary only after its two task IDs and deterministic
checksums, unique owned stack, and `SWIFTOS:SMP_CPU{n}_TIMER_IRQS` count validate;
then `SWIFTOS:SMP_WORK_OK` precedes `SWIFTOS:SMP_OK`. A second QEMU smoke uses two
Cortex-A76 CPUs, and an eight-CPU smoke proves the current four-processor policy
cap. The physical Pi trace contains those complete CPU1-through-CPU3 work,
stack, timer, `SMP_WORK_OK`, and `SMP_OK` markers. QEMU also proves the shared
EL0 run queue, preemption, and migration across managed CPUs; the Pi trace does
not enter that layer. Fixed secondary work still does not provide general
kernel-thread admission or load balancing.

## Display and GPU boundary

Production SwiftOS graphics require every displayed pixel to be produced by a
hardware GPU. CPUs build retained scene state, animation, bounded damage, and
backend-neutral render commands; they do not rasterize or composite a production
frame. The software rasterizer remains an explicitly selected diagnostic/oracle
path only.

The generic graphics contracts are no longer tied to ramfb, VirtIO, or Pi. They
separate a GPU rasterizer, display presenter, image-memory domain, command queue,
fences, frame-slot lifetime, and scene publication. The shared retained-scene
compiler now feeds the QEMU VirGL boot session; a future native Pi V3D VII
backend must consume the same commands without duplicating UI policy. The shared
policy now also includes a bounded provider-backed file-manager state machine,
keyboard/pointer routing, animation invalidation, and a GPU file-manager scene
compiler. Its QEMU boot loop is wired through provider load, first frame,
terminal transition, and serialized single-CPU input redraw; it is compiled and
host/source validated but has not produced local GL-backed VirGL pixels. The
native Pi GPU route does not exist yet.

QEMU can boot without ramfb through a Swift modern VirtIO-MMIO GPU 2D driver;
that smoke remains CPU-rasterized diagnostic evidence. A separate production
QEMU branch now creates a format-100 sRGB VirGL target, GPU unit quad, and a
112 x 54 format-64 R8 glyph-mask atlas uploaded in two 112 x 27 strips. It
installs solid, analytic-rounded, and mask-glyph pipelines, renders one clear,
five quads, and seven GPU-sampled `SWIFTOS` glyphs, and publishes scanout after
18 ordered fenced transactions. The CPU prepares immutable geometry and R8
coverage, not color or scanout pixels, and the session remains reusable for
GPU-only IR submission and damage flush. The installed local QEMU lacks a
GL-backed VirGL device, so this route has source, protocol, and host-test
coverage but is not locally hardware-exercised. None of it implements or
validates Raspberry Pi 5's V3D VII GPU, HVS, HDMI controllers, firmware
interfaces, display clocks, or GPU font path.

The packaged Pi configuration sets `disable_fw_kms_setup=0`, requests a 32-bit
legacy framebuffer, and leaves firmware to read HDMI EDID and choose the boot
mode. If firmware publishes a valid `/chosen/simple-framebuffer`, the Swift Pi
driver:

1. validates its address, size, width, height, stride, and pixel format;
2. reserves the page-normalized scanout span before the physical allocator can
   reuse it, including when its format is not yet renderable;
3. adds an exact normal-memory mapping to the final tables and separately maps
   the firmware mailbox aperture as Device memory;
4. binds supported 32-bit XRGB/ARGB modes to the shared scanout backend; and
5. cleans each presented damage range from the data cache with a system-scope
   completion barrier.

This simplefb path shares retained-layer/damage, terminal, display-mode, DMA-
mapping, and driver-resource contracts with QEMU, but it uses the diagnostic
CPU compositor. The logical desktop is 800 x 600: a 1920 x 1080 scanout uses
centered 1x rendering, while 3840 x 2160 uses centered 3x rendering. Letterbox
pixels are cleared by the diagnostic canvas. The Pi image rasterizes the
retained indicator's initial state before the first full-frame presentation.
The returned-card trace reached `ANIMATION_FRAME_OK` and `ANIMATION_PEAK_OK` in
the Pi monitor loop. It does not prove sustained or vblank-driven animation,
and the Pi did not enter EL0.

Device-tree discovery now identifies enabled `brcm,2712-v3d` hub, core, and SMS
register tuples, the HVS register resource, and the graphics address-translation
requirement. Boot-resource planning maps those MMIO regions as Device memory.
This proves bounded discovery and mapping only. It does not program V3D VII
command lists or its MMU, an HVS display list or IOMMU, HDMI clocks/controllers/
PHY, hotplug/DDC/EDID, or vblank.

The first production Pi graphics backend must lower the shared commands to V3D
VII, render into GPU-owned offscreen targets, use GPU copy/composition for
damaged regions, synchronize through hardware fences, and present through a
native HVS/HDMI pipeline. Live EDID/DDC supplies mode timing, refresh, physical
dimensions, and therefore the inputs for refresh- and PPI-aware scale policy.
Simple framebuffer supplies none of those contracts and cannot satisfy the
production invariant. A bounded PSF2 loader and diagnostic glyph rasterizer are
host-tested, but the Pi path has no packaged font asset, native GPU glyph atlas,
GPU upload/sampling path, or live font selection. QEMU's fixed VirGL mask atlas
does not constitute Pi support. When no supported diagnostic framebuffer is
present, the Pi can render the same diagnostic desktop into its kernel-owned
USB surface; if USB activation also fails, no external display transport is
verified, leaving attempted UART output plus the returned-card log path.
There is no dynamic font loader/shaper/atlas, EL0 window server, or Pi GPU text
path. The Pi executed the headless diagnostic-render path, but the firmware
reported no simple framebuffer; USB enumeration and HDMI output remain
unverified.

## Hardware validation gate

The target remains **unsupported** until one exact build passes all of the
following on an 8 GB Raspberry Pi 5 Model B. The first returned-card capture
satisfies a meaningful subset but not the gate. Retain the complete
serial log, exact SwiftOS commit and dirty state, firmware-repository revision,
separate EEPROM bootloader build, image/DTB hashes, and test build revision.

- Cold-boot firmware log names and hashes the expected kernel and DTB.
- `_start` validates the DTB passed in `x0` before using any discovered address.
- The log records `x0`, the full DTB span, every discovered memory/reservation
  interval, actual secondary MPIDRs, dense `TPIDR_EL1` IDs, stack addresses,
  `CNTFRQ_EL0`, and repeated IRQ counts.
- UART10 prints stable stage markers before and after enabling the 4 KiB MMU.
- The parsed memory report accounts for every byte as usable, reserved, or owned,
  including all RAM above 4 GiB, with no overlap or arithmetic truncation.
- The firmware-patched tree resolves the non-secure physical timer as level-low
  PPI 14/INTID 30 with processor mask `0x0f`, and the removable SDHCI route as
  level-high SPI `0x111`/INTID `0x131`; the retained log records those decoded
  values before either driver uses them.
- GICv2 distributor/CPU-interface discovery, one global distributor setup, and
  four processor-local PPI/GICC initializations pass repeating architectural-
  timer acknowledgement/EOI tests without an exception loop.
- CPU0 plus three PSCI-started secondaries come online with unique stacks and
  dense per-CPU IDs.
  For each `n` in 1, 2, and 3, retain ordered
  `SWIFTOS:SMP_CPU{n}_ONLINE`, `SWIFTOS:SMP_CPU{n}_TASK1_OK`,
  `SWIFTOS:SMP_CPU{n}_TASK1_CHECKSUM=0x...`,
  `SWIFTOS:SMP_CPU{n}_TASK2_OK`,
  `SWIFTOS:SMP_CPU{n}_TASK2_CHECKSUM=0x...`,
  `SWIFTOS:SMP_CPU{n}_STACK=0x...`, and
  `SWIFTOS:SMP_CPU{n}_TIMER_IRQS=0x...` markers. `SWIFTOS:SMP_WORK_OK` must then
  precede `SWIFTOS:SMP_OK`; those markers are emitted only after the kernel
  validates both results, stack ownership/uniqueness, and enough local timer
  IRQs for all work quanta.
- CPU0 subsequently reaches `SWIFTOS:SCHEDULER_READY`, `SWIFTOS:EL0_OK`,
  `SWIFTOS:THREADS_OK`, `SWIFTOS:PREEMPT_OK`,
  `SWIFTOS:EL0_PREEMPTION_PROVEN`, and `SWIFTOS:EL0_MIGRATION_PROVEN` in order.
  Every managed CPU must retain `EL0_CPU{n}_ONLINE`, `_REPORT`, and `_TIMER_IRQ`
  evidence, and at least one lease-attributed thread identity must report from
  multiple CPUs. Migration may not be inferred from fixed secondary-work
  markers.
- Allocator stress crosses the 4 GiB boundary without corrupting the DTB, image,
  page tables, DMA buffers, or reserved regions.
- The runtime-patched framebuffer remains reserved and mapped, and the serial
  log reaches `SWIFTOS:SIMPLE_FB_OK`, `SWIFTOS:PLATFORM_FB_OK`, and
  `SWIFTOS:FRAMEBUFFER_READY` in order.
- HDMI capture shows the diagnostic Swift-rendered desktop at the firmware-
  selected mode; the captured mode, reported refresh, display EDID, viewport
  scale, and visible letterbox bounds are retained with the boot evidence.
- With and without HDMI attached, the log reaches `SWIFTOS:USB_POWER_READY` or
  the valid Pi 5 fallback `SWIFTOS:USB_POWER_UNMANAGED`,
  `SWIFTOS:USB_DEBUG_ATTACHED`, `SWIFTOS:USB_DEBUG_CONFIGURED`, and
  `SWIFTOS:USB_DEBUG_FRAME`; macOS reports VID `0x1209`, PID `0x5a17`, and a
  `/dev/cu.usbmodem*` node, while the viewer validates hello, mode, full-frame,
  CRC, damage, DTR-close, and DTR-reopen behavior.
- A boot with Ethernet connected reaches `SWIFTOS:SD_INIT_READY_BLOCKS`,
  `SWIFTOS:STORAGE_SUPERBLOCK_READY`, `SWIFTOS:RP1_NET_STARTING`, and a specific
  link/DHCP outcome; after power-off, the read-only host inspector reconstructs
  those same markers from CRC-valid persistent records without reading outside
  the declared log arena.
- The same card preserves the disjoint log and SwiftFS ranges, emits a bounded
  `SWIFTOS:SWIFTFS_FORMATTED` or `SWIFTOS:SWIFTFS_REMOUNTED` result followed by
  `SWIFTOS:SWIFTFS_READY`, and survives a power-cycle remount without modifying
  the kernel-log arena.
- At least three power-cycle boots and three warm resets produce the same staged
  serial protocol.
- ELF inspection confirms AArch64, no Darwin load commands or framework symbols,
  and only reviewed freestanding unresolved symbols.

Native display modesetting, vblank-driven animation, USB input, richer
filesystem/userland policy, full RP1 ownership, networking, and native GPU
rendering are later gates that must pass before a production GUI claim. A firmware-framebuffer image
establishes early diagnostic display output and can run the software oracle; it
is not a user window system or GPU-capable Raspberry Pi release. The production
GPU gate must add retained serial/fence evidence for V3D VII rendering,
HVS/vblank presentation, IOMMU/address-translation ownership, HDMI HPD/DDC/EDID
timing, measured refresh, physical dimensions/PPI, and captured output at the
selected native mode.

## Primary sources

- [Raspberry Pi `config.txt` reference](https://www.raspberrypi.com/documentation/computers/config_txt.html)
- [Raspberry Pi EEPROM release notes](https://github.com/raspberrypi/rpi-eeprom/blob/master/firmware-2712/release-notes.md)
- [Linux simple-framebuffer Device Tree binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/display/simple-framebuffer.yaml)
- [Raspberry Pi mailbox property interface](https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface)
- [Raspberry Pi mailbox register interface](https://github.com/raspberrypi/firmware/wiki/Mailboxes)
- [Raspberry Pi Linux power-domain mapping](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/drivers/pmdomain/bcm/raspberrypi-power.c)
- [DWC2 Device Tree binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/usb/dwc2.yaml)
- [Raspberry Pi boot files, Device Tree, and UART documentation](https://www.raspberrypi.com/documentation/computers/configuration.html)
- [Raspberry Pi 5 hardware documentation](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-5)
- [Raspberry Pi BCM2712 documentation](https://www.raspberrypi.com/documentation/computers/processors.html#bcm2712)
- [Raspberry Pi RP1 overview](https://www.raspberrypi.com/documentation/computers/io-controllers.html)
- [Raspberry Pi RP1 peripherals specification](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf)
- [Arm64 Image boot protocol in the Linux kernel documentation](https://www.kernel.org/doc/html/next/arch/arm64/booting.html)
- [Upstream BCM2712 SoC Device Tree source](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/broadcom/bcm2712.dtsi)
- [Upstream Raspberry Pi 5 Model B Device Tree source](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dts)
- [Upstream RP1 bus Device Tree source](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/broadcom/rp1-common.dtsi)
- [Raspberry Pi downstream Pi 5 Device Tree source](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dts)
- [Raspberry Pi downstream Pi-family Device Tree source](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm64/boot/dts/broadcom/bcm2712-rpi.dtsi)
- [Raspberry Pi downstream RP1 Device Tree source](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm64/boot/dts/broadcom/rp1.dtsi)
- [PSCI Device Tree binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/arm/psci.yaml)
- [PL011 Device Tree binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/serial/pl011.yaml)
- [Arm architectural timer Device Tree binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/timer/arm%2Carch_timer.yaml)
- [Arm GIC Device Tree binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/interrupt-controller/arm%2Cgic.yaml)
