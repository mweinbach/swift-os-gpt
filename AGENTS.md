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

- Treat first-time media initialization and routine boot updates as different
  operations. Writing `swiftos-rpi5-media.img` to a whole card is destructive;
  it creates both the FAT32 firmware partition and the type-`0xda` SwiftOS data
  partition. Copying `.build/raspberry-pi-5/boot/` onto the mounted FAT32
  partition updates boot files only and must preserve the data partition.
- Before every physical-media operation, power the Pi off, re-run
  `diskutil list external physical`, and resolve the removable whole disk from
  current capacity/device information. Never reuse a cached `/dev/diskN`, never
  substitute a partition node for the whole disk, and never touch a protected
  or unrelated disk. Stop if identity, geometry, or ownership is ambiguous.
- A routine update must target only the verified mounted SwiftOS FAT32 boot
  volume. Do not repartition it, format it, or write the whole-card image. Copy
  the packaged boot tree without deleting unrelated files, verify the mounted
  result against its new `SHA256SUMS`, synchronize, and eject the card before
  removal. Copying files to FAT is not a whole-card flash and cannot create a
  missing SwiftFS/log partition.
- A live USB `SUPD` kernel update is volatile. `COMMITTED` seals the RAM-staged
  image; it does not install that image to microSD. Re-enumeration and a new
  boot identity verify the live handoff, while a persistent update still
  requires the routine FAT32 procedure after powering down.
- Persistent-log claims require a card initialized with the signed type-`0xda`
  partition. Inspect returned media read-only as documented in
  `docs/raspberry-pi-5.md`; a FAT-only update provides no persistent log arena.
