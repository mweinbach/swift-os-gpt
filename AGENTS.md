# SwiftOS engineering rules

SwiftOS is a clean-room, bare-metal operating system. The boot artifact must not
link against Darwin or any Apple framework.

## Non-negotiable boundaries

- `Kernel/` and `Userland/` are freestanding Embedded Swift. Do not import
  Foundation, Dispatch, AppKit, UIKit, SwiftUI, Metal, CoreGraphics, or any host
  SDK module there.
- Assembly is limited to the reset vector, exception veneers, context switching,
  and instructions Swift cannot express. Kernel policy, memory management,
  drivers, graphics, filesystem code, and user software belong in Swift.
- Do not copy code from the adjacent `swift-os` repository or another OS. Specs
  may be consulted; implementations must be original to this repository.
- The first supported machine is QEMU `virt` on AArch64. Hardware discovery
  must move toward the device tree rather than spreading fixed addresses.
- Host tools and tests may use macOS APIs, but they must live outside the guest
  source tree and must never be linked into the kernel.

## Change discipline

- Keep the serial boot protocol stable enough for `Tests/Smoke/boot_smoke.py`.
- Run `make test` before completing a change and `make smoke` for boot-path work.
- Inspect the ELF architecture and unresolved symbols as part of verification.
- Commit coherent milestones with an imperative subject and an explanatory body.
- Never claim hardware support that has only been exercised in QEMU.

## Raspberry Pi microSD safety

- Identify the on-card format before every operation. Legacy format v1 has one
  bootable FAT32 `SWIFTOS` partition followed by a type-`0xda` data partition.
  Format v2 has the invariant FAT12 `SWIFTOS-CTL` selector, FAT32
  `SWIFTOS-A` and `SWIFTOS-B` payload slots, and type-`0xda` data partition
  four. New media images use v2. Copying files cannot turn a v1 card into v2.
- Treat first-time media initialization, v1-to-v2 migration, and routine v2
  slot updates as three different operations. Writing
  `swiftos-rpi5-media.img` to a whole card is destructive and creates the full
  v2 layout. A migration changes partition metadata and boot extents even when
  it is designed to retain the data partition at the same blocks; never present
  migration as a routine or risk-free file copy.
- Before every physical-media operation, power the Pi off, re-run
  `diskutil list external physical`, and resolve the removable whole disk from
  current capacity/device information. Never reuse a cached `/dev/diskN`, never
  substitute a partition node for the whole disk, and never touch a protected
  or unrelated disk. Stop if identity, geometry, or ownership is ambiguous.
- A routine v2 update may write only the verified inactive payload slot. It
  must not rewrite the MBR, confirmed/active slot, partition-four extent, log
  arena, or SwiftFS data; only the reserved redundant boot-control journal
  bytes may change. Stage, hash, synchronize, and read back the complete
  candidate before a one-shot trial boot. The selector is immutable during
  staging and trial; only the transactional update service may change its
  confirmed default after the candidate proves its boot identity, release
  digest, and health. Never direct developers to edit `autoboot.txt` or copy
  files into `SWIFTOS-CTL` manually.
- Legacy v1 media remains valid for read-only inspection and historical
  evidence, but its single payload has no A/B rollback. Do not install a v2
  package into that sole FAT32 partition and call it migrated. A dedicated,
  verified migration must preserve the existing type-`0xda` extent byte for
  byte, and must make the MBR transition explicit and recoverable. No physical
  v1 card has yet been migrated or used to verify the v2 boot/rollback path.
- A live USB `SUPD` kernel update is volatile. `COMMITTED` seals the RAM-staged
  image; it does not install that image to microSD. Re-enumeration and a new
  boot identity verify the live handoff, while a persistent update still
  requires the not-yet-integrated transactional slot installer.
- Persistent-log claims require a card initialized with the signed type-`0xda`
  partition. Inspect returned media read-only as documented in
  `docs/raspberry-pi-5.md`; it is partition two on v1 and partition four on v2.
- Raspberry Pi SPI EEPROM bootloader updates are a separate recovery domain
  from SwiftOS microSD A/B payloads. Slot packages keep `bootloader_update=0`
  and must not include `recovery.bin` or `pieeprom` update files. Any future
  EEPROM update design needs its own independently recoverable A/B transaction.
