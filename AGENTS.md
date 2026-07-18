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

