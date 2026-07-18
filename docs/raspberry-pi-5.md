# Raspberry Pi 5 board target

> **Hardware status: unverified and not supported.** This is a clean-room board
> contract and packaging scaffold. It has not booted on a Raspberry Pi 5, and
> no hardware-support claim is permitted until the validation gate below passes.

The initial physical research target is Raspberry Pi 5 Model B with 8 GB RAM.
The board uses BCM2712, four Cortex-A76 cores, and the RP1 I/O controller. The
guest remains freestanding Embedded Swift: Raspberry Pi OS, Linux code, Apple
frameworks, SwiftUI, Metal, and Darwin are not part of the boot artifact.

This package deliberately does not alter the QEMU target. The current reset
path maps QEMU `virt` RAM and MMIO, assumes its GICv3 topology, parks all
secondary CPUs, and reaches a QEMU-specific early UART. Those are known blockers,
not Raspberry Pi 5 implementations.

## Boot partition and firmware handoff

Raspberry Pi 5 keeps its boot firmware in EEPROM. It does not use
`bootcode.bin`, `start*.elf`, or `fixup*.dat`; it does require a non-empty
`config.txt`. The deterministic file set produced by
`Boards/RaspberryPi5/package-boot.sh` is:

| File | Purpose |
| --- | --- |
| `config.txt` | Selects the 64-bit image and debug handoff. |
| `kernel8.img` | Raw SwiftOS AArch64 Image with a 4 KiB-page header. |
| `bcm2712-rpi-5-b.dtb` | Firmware-patched hardware description. |
| `BOOT-MANIFEST.txt` | Human-readable, explicitly unverified manifest. |
| `BUILD-METADATA.txt` | Input hashes and exact firmware Git revision. |
| `SHA256SUMS` | Stable byte-level hashes of all preceding files. |

The firmware normally prefers `kernel_2712.img` on BCM2712 and falls back to
`kernel8.img`. Raspberry Pi documents `kernel8.img` as a BCM2712-capable common
64-bit image, so this package explicitly chooses that name for SwiftOS's 4 KiB
mapping contract. The AArch64 Image header declares the 4 KiB page-size encoding,
and the board linker aligns executable and mapping storage to 4 KiB.

The DTB comes from `boot/bcm2712-rpi-5-b.dtb` in a caller-supplied, pinned
checkout of [raspberrypi/firmware](https://github.com/raspberrypi/firmware).
The packager records its exact commit and refuses to overwrite a non-empty
directory. Given identical kernel bytes, DTB checkout, and board files, the
listed file bytes and `SHA256SUMS` are reproducible. A reproducible FAT or disk
image must additionally normalize allocation order, timestamps, and volume ID.

Example packaging flow after a future Pi 5 link target produces the raw image:

```sh
Boards/RaspberryPi5/package-boot.sh \
  .build/raspberry-pi-5/kernel8.img \
  /path/to/pinned/raspberrypi-firmware \
  .build/raspberry-pi-5/boot
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

The entry path must preserve `x0` until Swift can validate the FDT header and
must treat every address in it as physical until board page tables are live.
The current boot assembly already preserves `x0`, but its one-table QEMU map
cannot reach BCM2712's high MMIO addresses and must not be used for this target.

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

The current parser does not yet implement the complete nested-range and
interrupt-controller contract. A parse success on QEMU does not clear this Pi 5
blocker.

## Eight-gigabyte memory ownership

The source DTS intentionally leaves the `/memory` size for firmware to fill.
SwiftOS must not hard-code an 8 GB contiguous range and must not set `total_mem`
in `config.txt`. Instead, it must:

- decode every enabled `/memory` `reg` tuple using the root's two address and
  two size cells;
- retain addresses and lengths as checked `UInt64` values, including RAM above
  4 GiB and split banks;
- subtract the FDT reservation map and enabled `/reserved-memory` children,
  including the no-map ATF region;
- reserve the kernel's full `[__image_start, __image_end)` span, DTB bytes,
  bootstrap tables, per-CPU stacks, and DMA allocations before publishing pages;
- reject overflow, overlap, truncation, and a DTB outside described usable RAM;
- allocate DMA only within constraints declared by each device and bus.

The 4 KiB page-table implementation should begin with the smallest safe identity
map: executing image, bootstrap stack/tables, validated DTB pages, UART10, GIC,
and timer resources. It should then construct owned mappings from the sanitized
memory map. Identity-mapping all reported 8 GB as a bootstrap shortcut would
hide aliasing and reserved-memory mistakes.

## Early serial: BCM2712 and RP1

The primary early-debug route is the PL011-compatible UART10 on Raspberry Pi
5's dedicated three-pin debug connector. Discovery order is:

1. Read `/chosen/stdout-path` (the board DT selects `serial10:115200n8`).
2. Resolve `serial10` through `/aliases`.
3. Require an enabled PL011-compatible node.
4. Translate its `reg` through the parent `ranges` chain and map it as device
   memory before the first access.

Raspberry Pi documents `0x107d001000` at 115200 as the Pi 5 debug-header early
console address. That constant is allowed only as a narrowly gated emergency
fallback after matching the Pi 5 compatible string; the normal path must obtain
the same address from the firmware DT.

The second route is RP1 UART0 on GPIO14/15. In the checked Pi 5 DT composition,
RP1 UART0's internal `0xc0_4003_0000` resource translates through the RP1 and
PCIe `ranges` windows to CPU physical `0x1f_0003_0000`. `enable_rp1_uart=1` asks
firmware to initialize it to 115200, while `pciex4_reset=0` preserves the
bootloader's RP1 PCIe setup. This is inherited early-debug state, not an RP1
driver. SwiftOS must still calculate and verify `0x1f_0003_0000` from the patched
DT/assigned BAR before access, then eventually own RP1 reset, PCIe enumeration,
clocks, pinmux, and UART configuration. It must never treat an RP1-internal
register offset as a fixed BCM2712 physical address.

## Interrupt controller and timer

BCM2712's DT describes an `arm,gic-400` GICv2, while the QEMU reference board
uses GICv3. The board implementation must select the controller by `compatible`,
translate all `reg` regions, respect `#interrupt-cells`, and create a GICv2
driver instance. Reusing the QEMU addresses or GICv3 system-register path is an
invalid port.

The architectural timer node is compatible with `arm,armv8-timer`. SwiftOS must
decode its PPI tuples through the resolved interrupt parent rather than compile
in Linux interrupt numbers. It must verify `CNTFRQ`, program a per-CPU physical
or virtual timer consistently with the entry EL, register the chosen PPI with
the discovered GIC, and prove interrupt acknowledgement and end-of-interrupt.

## Multicore bring-up

The four enabled CPU nodes are Cortex-A76 cores with DT affinity values `0x000`,
`0x100`, `0x200`, and `0x300`, each with `enable-method = "psci"`. The DT's PSCI
node advertises PSCI 1.0/0.2 using the `smc` conduit. The clean bring-up contract
is:

1. Enumerate enabled CPU nodes and decode each 64-bit `reg` affinity.
2. Match the boot CPU using the affinity fields from `MPIDR_EL1`, not only Aff0.
3. Keep secondaries offline until memory ownership, page tables, vectors, and a
   distinct aligned stack are ready.
4. Invoke the standard PSCI `CPU_ON` call through `smc` for each target affinity,
   passing a SwiftOS-owned physical secondary-entry address and context value.
5. At secondary entry, establish the same translation/coherency regime, install
   per-CPU state and timer/GIC interface, then publish an online flag with the
   required barriers.
6. Time out and report each failed PSCI return; never silently reduce the CPU
   count or assume spin-table release addresses.

The current `_start` parks any non-boot CPU forever and has no PSCI call surface.
Until that changes and all four cores report independently, Pi 5 SMP is absent.

## Hardware validation gate

The target remains **unverified and unsupported** until one exact build passes
all of the following on an 8 GB Raspberry Pi 5 Model B. Retain the serial log,
firmware revision, image/DTB hashes, and test build revision as evidence.

- Cold-boot firmware log names and hashes the expected kernel and DTB.
- `_start` validates the DTB passed in `x0` before using any discovered address.
- UART10 prints stable stage markers before and after enabling the 4 KiB MMU.
- The parsed memory report accounts for every byte as usable, reserved, or owned,
  including all RAM above 4 GiB, with no overlap or arithmetic truncation.
- GICv2 distributor/CPU interface discovery and a repeating architectural-timer
  interrupt pass acknowledgement/EOI tests without an exception loop.
- PSCI brings all four cores online with unique stacks and per-CPU identifiers.
- Allocator stress crosses the 4 GiB boundary without corrupting the DTB, image,
  page tables, DMA buffers, or reserved regions.
- At least three power-cycle boots and three warm resets produce the same staged
  serial protocol.
- ELF inspection confirms AArch64, no Darwin load commands or framework symbols,
  and only reviewed freestanding unresolved symbols.

Display, USB input, storage, RP1 ownership, networking, and accelerated graphics
are later gates. A serial/timer/SMP success would establish core board bring-up,
not a GUI-capable Raspberry Pi release.

## Primary sources

- [Raspberry Pi `config.txt` reference](https://www.raspberrypi.com/documentation/computers/config_txt.html)
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
