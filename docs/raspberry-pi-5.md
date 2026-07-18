# Raspberry Pi 5 board target

> **Hardware status: unverified and not supported.** SwiftOS now builds and
> statically inspects a Raspberry Pi 5 firmware image, but that image has not
> booted on a Raspberry Pi 5. Physical execution and a Pi GUI remain unverified;
> native V3D VII rendering, HVS/HDMI scanout, EDID, refresh, and PPI handling are
> not active. No hardware-support claim is permitted until the validation gate
> below passes.

The initial physical research target is Raspberry Pi 5 Model B with 8 GB RAM.
The board uses BCM2712, four Cortex-A76 cores, and the RP1 I/O controller. The
guest remains freestanding Embedded Swift: Raspberry Pi OS, Linux code, Apple
frameworks, SwiftUI, Metal, and Darwin are not part of the boot artifact.

The board target has its own standard Image header, link address, high-MMIO
bootstrap descriptors, firmware configuration, and packaging contract. Shared
Swift code discovers QEMU GICv3 or Pi GICv2, owns DT-described RAM, builds final
permissioned mappings, and selects HVC or SMC PSCI by the DT. Those mechanisms
are proven by QEMU tests only; compiling them into `kernel8.img` is not evidence
that BCM2712 UART, GICv2, timer, PSCI, or 8 GB memory behavior works on hardware.

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
| `BOOT-MANIFEST.txt` | Human-readable, explicitly unverified manifest. |
| `BUILD-METADATA.txt` | Input hashes, SwiftOS revision/dirty state, and firmware-repository revision. |
| `SHA256SUMS` | Stable byte-level hashes of all preceding files. |

The firmware normally prefers `kernel_2712.img` on BCM2712 and falls back to
`kernel8.img`. Raspberry Pi documents `kernel8.img` as a BCM2712-capable common
64-bit image, so this package explicitly chooses that name for SwiftOS's 4 KiB
mapping contract. The AArch64 Image header declares the 4 KiB page-size encoding,
and the board linker aligns executable and mapping storage to 4 KiB.

The DTB comes from `boot/bcm2712-rpi-5-b.dtb` in a caller-supplied, pinned
checkout of [raspberrypi/firmware](https://github.com/raspberrypi/firmware).
The packager records its exact repository commit and refuses to overwrite a
non-empty directory. That value identifies the `raspberrypi/firmware` file set,
not the board's EEPROM bootloader revision; physical evidence must record the
EEPROM build separately. Given identical kernel bytes, DTB checkout, and board
files, the listed file bytes and `SHA256SUMS` are reproducible. A reproducible
FAT or disk image must additionally normalize allocation order, timestamps, and
volume ID.

Build and statically inspect the Pi image with:

```sh
make rpi5-inspect
```

Package it with a pinned firmware checkout:

```sh
RPI5_FIRMWARE=/path/to/pinned/raspberrypi-firmware make rpi5-package
```

Copy the resulting directory contents to an empty FAT boot partition. Do not
add Raspberry Pi 4 firmware blobs. `sha256=1` asks the EEPROM firmware to log
the hashes of loaded files; it does not replace checking `SHA256SUMS` before
writing media.

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
Linux, U-Boot, or host shim is part of the artifact. Acceptance on the actual
EEPROM/board combination remains an unverified validation item, not a completed
boot claim.

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
replaced by owned final tables after DT parsing; it still maps holes and reserved
areas during bootstrap and therefore remains a physical-hardware validation item.

The Pi ELF contains the same range-based memory runtime, final permissioned
tables and guards, PSCI startup code, and separately linked EL0 Swift image used
by the QEMU milestone. Their presence proves the freestanding link contract only;
none of those paths, including the two CPU0-pinned preempted user threads, has
executed on a Pi.

## Device-tree contract

The firmware loads and tailors the DTB before passing its address in `x0`.
Board bring-up must accept the patched tree as authority and check the root
compatible strings for `raspberrypi,5-model-b` and `brcm,bcm2712` before using
any Pi 5 emergency fallback.

The required parser work is broader than finding nodes by name:

1. Read inherited `#address-cells`, `#size-cells`, and `interrupt-parent` values.
2. Resolve `/aliases` and `/chosen/stdout-path`.
3. Translate each `reg` tuple through every parent `ranges` mapping, including
   the nested BCM2712 and PCI/RP1 buses.
4. Ignore disabled nodes and bind by `compatible`, not by unit-address spelling.
5. Preserve 64-bit physical addresses throughout discovery and mapping.

The current parser handles enabled-node filtering, compatibility and device-type
matching, multi-tuple `reg`, memory/reservation enumeration, CPU affinities, and
recursive translation using the first `ranges` tuple on each traversed bus. The
package gate probes the actual pinned Pi DTB and requires translated UART10 at
`0x107d001000`, GICD at `0x107fff9000`, GICC at `0x107fffa000`, PSCI `smc`, four
affinities, and the ATF reservation. It does not yet resolve `/aliases` plus
`/chosen/stdout-path`, support every tuple in a multi-window bus, or decode the
complete interrupt-parent/specifier graph. That parser proof is not hardware
execution.

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
tests for split ranges, overlap, permissions, and guards. They have not been run
against a firmware-patched 8 GB Pi memory map and have not allocated above 4 GiB
on Pi. The distinct-address DMA model and memory-domain allocator exist, but no
Pi peripheral or IOMMU integration has supplied a non-identity or noncoherent
mapping. Hardware acceptance still requires proving every reported byte is
usable, reserved, or owned with no overflow, alias, or truncation.

## Early serial: BCM2712 UART10 only

The only early-debug route is the PL011-compatible UART10 on Raspberry Pi 5's
dedicated three-pin debug connector. Until alias/stdout-path resolution lands,
Pi discovery enumerates enabled PL011 resources, translates them through DT
`ranges`, and accepts only the UART10 physical address `0x107d001000` with a
sufficient register span. The actual pinned firmware-DTB probe enforces that
translation rather than selecting the first PL011 node.

`enable_uart=1` and `uart_2ndstage=1` are explicit boot preconditions. The
current PL011 driver does not program UART10 clocks, baud, pinmux, or control
registers and has no bounded timeout when TX remains full, so physical bring-up
still depends on firmware leaving the dedicated debug UART operational. RP1
UART/PCIe preservation is deliberately disabled: the bootstrap and final tables
do not map the RP1 aperture, and SwiftOS does not yet own or quiesce RP1/PCIe DMA.

## Interrupt controller and timer

BCM2712's DT describes an `arm,gic-400` GICv2, while the QEMU reference board
uses GICv3. Platform discovery now selects the controller by `compatible` and
constructs the matching Swift driver from discovered `reg` resources. Repeating
architectural physical-timer PPI delivery, acknowledgement, EOI, and rearming
are proven on QEMU GICv3.

The Pi GICv2 path is linked but hardware-unverified. The current timer contract
uses architectural PPI 30; complete Pi validation still requires decoding the
timer interrupt tuple through its resolved interrupt parent, checking `CNTFRQ`,
and proving repeating delivery through the real distributor and CPU interface.
Reusing QEMU addresses or treating the linked GICv2 path as executed evidence
would be an invalid support claim.

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
5. At secondary entry, establish the same translation/coherency regime and a
   unique stack, enter Swift, then publish an online flag with release semantics.
6. Time out and report each failed PSCI return; never silently reduce the CPU
   count or assume spin-table release addresses.

The CPU topology now carries packed processor class, capability, proximity, and
startup-eligibility metadata separately from a validated boot-resource limit.
This path is proven in QEMU through the DT-selected HVC conduit for direct EL1
entry and SMC conduit for the virtualization/EL2 scenario: CPU1-CPU3 enter Swift,
publish independently, and then park. The Pi SMC path and Pi affinity values are
present in the artifact but have not run on a Pi. A second QEMU smoke uses two
Cortex-A76 CPUs to prove a smaller configuration, but it does not reproduce
BCM2712 firmware or topology. There is no per-secondary GIC/timer scheduling
yet, and both preempted EL0 threads remain pinned to CPU0; four online CPUs is
not a multicore scheduler.

## Display and GPU boundary

Production SwiftOS graphics require every displayed pixel to be produced by a
hardware GPU. CPUs build retained scene state, animation, bounded damage, and
backend-neutral render commands; they do not rasterize or composite a production
frame. The software rasterizer remains an explicitly selected diagnostic/oracle
path only.

The generic graphics contracts are no longer tied to ramfb, VirtIO, or Pi. They
separate a GPU rasterizer, display presenter, image-memory domain, command queue,
fences, frame-slot lifetime, and scene publication. The shared retained-scene
compiler can therefore feed the QEMU VirGL backend or native Pi V3D VII backend
without duplicating UI policy. Neither backend's accelerated execution session
is active in the current boot path.

QEMU can boot without ramfb through a Swift modern VirtIO-MMIO GPU 2D driver,
including resource backing, scanout, transfer, and flush, but its current pixels
are still CPU-rasterized diagnostics. The VirtIO 3D configuration, capability,
context/resource/submit, VirGL command, frame-scheduling, and graphics-worker
foundations are host-tested but not yet submitted during boot. The QEMU device
has no relationship to Raspberry Pi 5's V3D VII GPU, HVS, HDMI controllers,
firmware interfaces, or display clocks.

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
Continuous animation is currently exercised only by the single-CPU QEMU
monitor, not by the Pi multicore/EL0 path.

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
host-tested, but no font asset, GPU glyph atlas, or live font-selection path is
packaged yet. When no supported diagnostic framebuffer is present, current boot
remains serial-only. Physical execution and HDMI output remain unverified.

## Hardware validation gate

The target remains **unverified and unsupported** until one exact build passes
all of the following on an 8 GB Raspberry Pi 5 Model B. Retain the complete
serial log, exact SwiftOS commit and dirty state, firmware-repository revision,
separate EEPROM bootloader build, image/DTB hashes, and test build revision.

- Cold-boot firmware log names and hashes the expected kernel and DTB.
- `_start` validates the DTB passed in `x0` before using any discovered address.
- The log records `x0`, the full DTB span, every discovered memory/reservation
  interval, actual secondary MPIDRs and stack addresses, and repeated IRQ counts.
- UART10 prints stable stage markers before and after enabling the 4 KiB MMU.
- The parsed memory report accounts for every byte as usable, reserved, or owned,
  including all RAM above 4 GiB, with no overlap or arithmetic truncation.
- GICv2 distributor/CPU interface discovery and a repeating architectural-timer
  interrupt pass acknowledgement/EOI tests without an exception loop.
- PSCI brings all four cores online with unique stacks and per-CPU identifiers.
- Allocator stress crosses the 4 GiB boundary without corrupting the DTB, image,
  page tables, DMA buffers, or reserved regions.
- The runtime-patched framebuffer remains reserved and mapped, and the serial
  log reaches `SWIFTOS:SIMPLE_FB_OK`, `SWIFTOS:PLATFORM_FB_OK`, and
  `SWIFTOS:FRAMEBUFFER_READY` in order.
- HDMI capture shows the diagnostic Swift-rendered desktop at the firmware-
  selected mode; the captured mode, reported refresh, display EDID, viewport
  scale, and visible letterbox bounds are retained with the boot evidence.
- At least three power-cycle boots and three warm resets produce the same staged
  serial protocol.
- ELF inspection confirms AArch64, no Darwin load commands or framework symbols,
  and only reviewed freestanding unresolved symbols.

Native display modesetting, vblank-driven animation, USB input, storage, RP1
ownership, networking, and native GPU rendering are later gates that must pass
before a production GUI claim. A firmware-framebuffer image establishes early
diagnostic display output and can run the software oracle; it is not a user
window system or GPU-capable Raspberry Pi release. The production GPU gate must
add retained serial/fence evidence for V3D VII rendering, HVS/vblank presentation,
IOMMU/address-translation ownership, HDMI HPD/DDC/EDID timing, measured refresh,
physical dimensions/PPI, and captured output at the selected native mode.

## Primary sources

- [Raspberry Pi `config.txt` reference](https://www.raspberrypi.com/documentation/computers/config_txt.html)
- [Raspberry Pi EEPROM release notes](https://github.com/raspberrypi/rpi-eeprom/blob/master/firmware-2712/release-notes.md)
- [Linux simple-framebuffer Device Tree binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/display/simple-framebuffer.yaml)
- [Raspberry Pi mailbox property interface](https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface)
- [Raspberry Pi mailbox register interface](https://github.com/raspberrypi/firmware/wiki/Mailboxes)
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
