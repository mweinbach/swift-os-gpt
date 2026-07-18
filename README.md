# SwiftOS

SwiftOS is a clean-room operating system whose kernel, drivers, graphics stack,
and software are written in Swift and run without macOS, Darwin, or Apple
frameworks underneath them.

This repository is intentionally not a SwiftUI desktop pretending to be an OS.
Its primary artifact is an AArch64 kernel ELF loaded directly by a virtual
machine. The kernel owns its exception level, memory, devices, framebuffer, and
event loop. A host application may eventually be useful as a debugger, but it
will never be the operating system.

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

All operating-system behavior is Swift. A tiny AArch64 assembly entry shim is
unavoidable: a CPU begins executing instructions before a Swift stack or runtime
environment exists. The shim establishes a stack and exception level, clears
zero-initialized memory, then transfers control permanently to Swift. Assembly
will also be used only for privileged instructions Swift cannot emit directly.

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
for the contracts behind those milestones.

## Prerequisites

- Swift 6.2 or newer with Embedded Swift support
- LLVM tools (`clang`, `ld.lld`, and `llvm-objcopy`)
- `qemu-system-aarch64`
- Python 3 for smoke tests

The build is deliberately dependency-light and does not fetch an SDK or reuse a
third-party kernel.

## Build and verify

```sh
make build
make inspect
make smoke
make test
```

Use `make run` for an interactive serial session. The generated kernel is
`.build/swiftos.elf`; it must identify as AArch64 ELF, never Mach-O.

## Honest status

The repository starts at the boot vertical slice. It is not yet a general-
purpose OS and must not be described as one until memory isolation, processes,
storage, input, and native graphics all work in the guest. Each milestone is
expected to leave behind a repeatable boot or unit test rather than a mock UI.

