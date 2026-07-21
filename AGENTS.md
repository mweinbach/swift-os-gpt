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
  Format v2 has the FAT12 `SWIFTOS-CTL` selector/rescue partition, two
  canonical FAT32 `SWIFTOS-AB` payload slots at MBR entries two and three, and
  type-`0xda` data partition four. The payload slots deliberately share their
  FAT32 identity and must be distinguished by verified partition geometry and
  firmware boot identity, never by volume label. Each slot's primary and backup
  FAT32 boot sectors must record that slot's actual partition start in
  `BPB_HiddSec`; those four-byte fields are the intentional raw-byte difference
  between otherwise equivalent fresh slots. New media images use v2.
  Copying files cannot turn a v1 card into v2.
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
  bytes may change. Before staging, invalidate and read back the inactive
  FAT32 backup boot sector 6 and primary boot sector 0. Copy and verify every
  other sector, then commit sector 6 and sector 0 separately in that order,
  encoding and verifying the inactive slot's actual start LBA in both
  `BPB_HiddSec` fields. Synchronize and read back the complete raw destination,
  and verify its location-neutral content digest after validating and
  normalizing only those two fields, before a one-shot trial boot. The
  selector/rescue partition is immutable during staging and
  trial. Only the transactional update service may rewrite its sole mutable
  partition-relative sector 15 after validating both FAT copies, the root
  directory, rescue manifest, and every rescue-file digest and after the
  candidate proves its boot identity, release digest, trial token, and health.
  Never direct developers to edit `autoboot.txt` or copy files into
  `SWIFTOS-CTL` manually.
- After selector commit, boot the newly confirmed slot normally before copying
  it back into the peer with the same activation-last policy. A failed or hung
  one-shot trial is intended to return through partition zero and the unchanged
  selector to the prior confirmed slot. Preserve the partition-one factory
  rescue (`config.txt`, `kernel8.img`, canonical `bcm2712-rpi-5-b.dtb`, and
  `overlays/dwc2.dtbo`) throughout routine updates. It currently reuses the
  full release kernel, DTB, and pinned USB-C overlay; a future media revision
  should pin a smaller rescue-specific build. Physical Pi tryboot,
  watchdog rollback, rescue fallback, and microSD power-cut behavior remain
  unverified, so never describe this design as unbrickable.
  Tryboot watchdog probation begins after the required initial adoption/service
  kick; no later cooperative kick is allowed until the exact candidate-health
  transition is durable.
  Rescue fallback also requires an exact, recorded EEPROM build/configuration
  with `PARTITION_WALK=1`; physical acceptance must capture that setting, the
  tryboot capability bits, and the observed fallback order rather than
  inferring them from the microSD layout.
- Legacy v1 media remains valid for read-only inspection and historical
  evidence, but its single payload has no A/B rollback. Do not install a v2
  package into that sole FAT32 partition and call it migrated. A dedicated,
  verified migration must preserve the existing type-`0xda` extent byte for
  byte, and must make the MBR transition explicit and recoverable. No physical
  v1 card has yet been migrated or used to verify the v2 boot/rollback path.
- Superseded A/B media whose boot-control journal records layout fingerprint
  revision 2 remains recognizable only by host-side read-only diagnostics. Its
  zero-valued FAT32 `BPB_HiddSec` fields, raw-slot journal identity, and older
  selector manifest are not kernel/update compatible with revision 3. Restore
  it only with an explicitly targeted whole-card reflash; copying current files
  into its slots is not an upgrade and must never grant write authority.
- A live USB `SUPD` kernel update is volatile. `COMMITTED` seals the RAM-staged
  image; it does not install that image to microSD. Re-enumeration and a new
  boot identity verify the live handoff. Boot-time journal recovery and peer
  convergence receive priority in the production SD owner. Candidate or peer
  failures that leave the confirmed selector safe may suspend the transaction
  for a later boot and permit confirmed-data aliases; journal or selector
  durability ambiguity must quarantine later SD work before reset. No supported
  routine v2 updater exists:
  initiating a persistent release still requires a not-yet-integrated full-slot
  capsule and resumable ingress. SHA-256, CRCs, and journal identities provide
  integrity, not authenticity; future ingress must enforce a trusted capsule
  signature, signing-key policy, and authenticated-host policy before granting
  raw inactive-slot write authority.
- Persistent-log claims require a card initialized with the type-`0xda`
  partition's duplicate magic- and CRC-validated superblocks. Inspect returned
  media read-only as documented in
  `docs/raspberry-pi-5.md`; it is partition two on v1 and partition four on v2.
- Raspberry Pi SPI EEPROM bootloader updates are a separate recovery domain
  from SwiftOS microSD A/B payloads. Slot packages keep `bootloader_update=0`
  and must not include `recovery.bin` or `pieeprom` update files. Any future
  EEPROM update design needs its own independently recoverable A/B transaction.
