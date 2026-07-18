# SwiftOS

SwiftOS is a clean-room operating-system project. Its current artifact is a
bootable kernel prototype whose long-lived kernel logic, drivers, renderer, and
monitor are Swift running without macOS, Darwin, or Apple frameworks underneath.

This repository is intentionally not a SwiftUI desktop pretending to be an OS.
Its primary artifact is an AArch64 kernel ELF loaded directly by a virtual
machine. The kernel owns its exception level, fixed linker-reserved regions,
PL011 and fw_cfg access, framebuffer, and event loop. It does not yet have a
physical page allocator. A host application may eventually be useful as a
debugger, but it will never be the operating system.

## Current target

The first hardware contract is QEMU's documented AArch64 `virt` board. That is
a real freestanding CPU/device target, although QEMU emulates the board. It gives
the project a deterministic place to build the kernel before ports to physical
ARM64 systems.

Apple Silicon is a separate future board port. Booting directly on a modern Mac
requires machine-specific firmware handoff, interrupt-controller, timer,
display, storage, USB, and SoC drivers. Apple Metal is a macOS graphics API and
cannot exist beneath an independent kernel; SwiftOS will drive display hardware
through its own driver stack.

## Language boundary

All long-lived kernel subsystems are intended to be Swift. A small AArch64
assembly boundary is unavoidable: a CPU begins executing before a Swift stack or
runtime environment exists. It establishes bootstrap architectural state,
including the exception level, stack, boot page table, MMU/cache controls, and
zero-initialized memory. Assembly is otherwise reserved for exception/context
veneers and privileged instructions Swift cannot emit.

## Milestones

1. Boot an Embedded Swift kernel and prove serial output, exception level, and
   timer progress.
2. Establish exceptions, physical/virtual memory, heap ownership, and a
   preemptive scheduler.
3. Discover devices from the flattened device tree and implement interrupt,
   input, storage, and network drivers.
4. Render a native compositor to a guest framebuffer, with a terminal-first
   Linux-like desktop and keyboard/pointer input.
5. Define an EL0 process ABI, executable loader, VFS, Swift system library, and
   first-party Swift userland.
6. Add physical ARM64 board ports, with Apple Silicon treated as a dedicated
   reverse-engineered hardware program rather than a build flag.

See [Architecture](docs/architecture.md) and [Hardware roadmap](docs/hardware-roadmap.md)
for the contracts behind those milestones. [Current status](docs/current-status.md)
separates working guest code from the next kernel frontiers.

## Prerequisites

- Swift 6.2 with the bare-metal `aarch64-none-none-elf` Embedded Swift standard
  library (some newer Xcode toolchains do not install this target)
- LLVM tools (`clang`, `ld.lld`, and `llvm-objcopy`)
- `qemu-system-aarch64`
- Python 3 for smoke tests

The build is deliberately dependency-light and does not fetch an SDK or reuse a
third-party kernel. `make toolchain-check` performs a real cross-compile probe so
an incompatible selected `swiftc` fails before stale build output can hide it.

## Build and verify

```sh
make build
make inspect
make smoke
make monitor-smoke
make frame-smoke
make test
```

Use `make run` to open the guest ramfb display. Type monitor commands in the
terminal that launched QEMU; PL011 input updates both serial output and the guest
terminal window. The linked artifact is
`.build/swiftos.elf`; it must identify as AArch64 ELF, never Mach-O. QEMU boots
the derived `.build/swiftos.bin` so it follows the AArch64 boot protocol and
passes the device-tree address in `x0`.

## Honest status

The repository now boots a freestanding EL1 Swift kernel, discovers devices,
publishes a linker-owned framebuffer, renders its own desktop, and runs an
interactive kernel monitor written in Swift. It is a real bootable kernel, not
yet a general-purpose or self-hosting OS: interrupts, a physical allocator,
preemptive tasks, EL0 isolation, storage, and graphical keyboard/pointer drivers
remain. Each milestone must leave behind a repeatable boot or unit test rather
than a mock UI.
