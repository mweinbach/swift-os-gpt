# SwiftOS

SwiftOS is a clean-room operating-system project. Its current artifact is a
bootable AArch64 kernel whose long-lived kernel logic, memory ownership,
interrupt handling, scheduling, drivers, renderer, and first user program are
Swift running without macOS, Darwin, or Apple frameworks underneath.

This repository is intentionally not a SwiftUI desktop pretending to be an OS.
Its primary artifact is an AArch64 kernel ELF loaded directly by a virtual
machine. The kernel owns its exception level, GIC and timer interrupts, physical
RAM ranges, final translation tables, PSCI secondary startup, PL011 and fw_cfg
access, and framebuffer. A separately linked Embedded Swift image executes at
EL0. A host application may eventually be useful as a debugger, but it will
never be the operating system.

## Current target

The first hardware contract is QEMU's documented AArch64 `virt` board. That is
a real freestanding CPU/device target, although QEMU emulates the board. It gives
the project a deterministic place to build the kernel before ports to physical
ARM64 systems.

The repository also builds and statically inspects a Raspberry Pi 5
firmware-loadable kernel image. That image has **not** been run on physical
hardware, and neither Pi 5 execution nor a Pi 5 GUI is verified or supported.

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

## Working kernel milestone

The verified QEMU path now includes:

1. full EL1 exception frames, device-tree-selected GICv3 delivery, and repeating
   architectural timer interrupts;
2. range-based RAM ownership with firmware/kernel/DTB/table reservations, a
   fixed-capacity physical-page allocator, final permissioned page tables, and
   unmapped stack guards;
3. PSCI startup of four QEMU CPUs, with three secondaries entering Swift on
   separate stacks and publishing online state;
4. a separately linked Embedded Swift EL0 image, two isolated user stacks, a
   narrow SVC report ABI, and two CPU0-pinned threads preempted by timer IRQs;
5. the existing QEMU ramfb software desktop and single-CPU interactive kernel
   monitor.

This is not yet a general-purpose OS. The next layers include multicore task
scheduling, an executable loader, VFS/storage, input drivers, a compositor,
networking, and a stable system library and syscall ABI.

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
make smp-el0-smoke
make test
```

`make run` boots four CPUs by default and follows the verified SMP/EL0 path after
publishing the QEMU ramfb display. Use `QEMU_CPUS=1 make run` for the interactive
EL1 kernel monitor; type monitor commands in the terminal that launched QEMU,
and PL011 input updates both serial output and the guest terminal window.

The linked artifact is
`.build/swiftos.elf`; it must identify as AArch64 ELF, never Mach-O. QEMU boots
the derived `.build/swiftos.bin` so it follows the AArch64 boot protocol and
passes the device-tree address in `x0`.

The Raspberry Pi 5 artifact has separate static gates:

```sh
make rpi5-inspect
RPI5_FIRMWARE=/path/to/pinned/raspberrypi-firmware make rpi5-package
```

`rpi5-inspect` validates the Image header, link addresses, BCM2712 high-MMIO
bootstrap descriptor, architecture, and unresolved-symbol contract. Packaging
first probes the pinned firmware DTB for the exact UART10, GICv2, PSCI, CPU, and
ATF-reservation contract, then adds it and byte hashes. Neither target executes
the image on a Pi.

## Honest status

The repository boots a freestanding EL1 Swift kernel, replaces its bootstrap map
with owned final mappings, proves IRQ-driven preemption and isolated EL0 Swift
threads, brings four CPUs online through PSCI, and renders its own QEMU desktop.
The scheduler currently runs both user threads only on CPU0; secondary CPUs
publish online state and park. There is no loader, VFS, persistent storage,
graphical input, compositor/window protocol, or stable application ABI. Physical
Raspberry Pi 5 execution remains unverified. Each milestone must leave behind a
repeatable boot or unit test rather than a mock UI.
