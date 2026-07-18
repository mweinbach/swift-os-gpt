# Current status

This file is the line between what the guest demonstrably does and what remains
architecture work. A screenshot is not evidence for a subsystem unless a guest
driver and a repeatable test sit behind it.

## Implemented and verified

- AArch64 ELF and raw boot image produced by Swift 6.2 Embedded Swift.
- Reset entry that accepts EL2 or EL1, parks secondary CPUs, selects EL1h,
  enables FP/SIMD, installs early vectors, clears `.bss`, and owns its stack.
- An enabled 4 KiB-granule identity MMU map with separate Device and Normal
  memory attributes plus instruction and data caches.
- Swift volatile MMIO and PL011 transmit/receive support.
- A bounded, heap-free flattened-device-tree parser that discovers PL011 and
  `fw_cfg`; hand-built fixtures and a live QEMU DTB exercise the same source.
- QEMU `fw_cfg` directory discovery and DMA writes to the writable `etc/ramfb`
  item, with all guest structures serialized explicitly in big-endian format.
- A linker-owned 800 x 600 XRGB8888 framebuffer, software rectangle/text
  rasterizer, bitmap font, desktop chrome, terminal window, and status panels.
- A fixed-capacity terminal buffer and interactive kernel monitor. `help`,
  `uname`, `status`, `clear`, `about`, and `uptime` execute in guest Swift; input
  and output travel through PL011 while the framebuffer updates. This monitor
  is linked into the kernel and executes at EL1; it is not userland.
- Freestanding Swift implementations of the memory primitives currently needed
  by compiler-generated code.

## Verification gates

`make test` currently requires all of the following:

1. every explicit guest import in `Kernel/` is on a minimal allowlist;
2. host tests for malformed/valid FDT parsing and monitor command parsing;
3. parser success against a DTB emitted by the installed QEMU;
4. a static AArch64 ELF at `0x40080000` with no unresolved symbols;
5. three ordered cold boots from EL1 plus one EL2-to-EL1 handoff, all through
   MMU, DTB, ramfb publication, and timer probes;
6. eight interactive monitor operations driven over the emulated PL011 device,
   including editing input across a rendered line wrap;
7. a framebuffer/render smoke test with exact 800 x 600 dimensions, expected
   guest-rendered color regions, and deterministic text glyphs, which rejects
   QEMU's unconfigured black fallback surface and a blank rasterizer.

The last visual artifact is written to `.build/swiftos-frame.ppm`. It proves a
rendered GUI-shaped frame, not a compositor, window system, or graphical input.

## Not implemented yet

- diagnostic exception frames, GIC interrupt delivery, and timer IRQs;
- physical page ownership, a kernel heap, guard pages, and final page tables;
- a preemptive scheduler, SMP, EL0 address spaces, syscalls, or executable loader;
- persistent block storage, a VFS, filesystem recovery, or permissions;
- virtio keyboard, pointer, GPU, block, entropy, and network drivers;
- application processes or a stable system library/ABI;
- a physical-board port, including Apple Silicon boot and device drivers.

The current device-tree resource lookup supports the QEMU `virt` root resources
used by this board contract. It does not yet translate a device address through
non-identity ancestor `ranges`, so nested physical-bus ports must add that before
claiming support.

The status panels deliberately label future work as `NEXT`; they do not claim
that IRQ timers, graphical input, or EL0 tasks already exist.

## Next kernel milestone

The next coherent gate is exceptions plus owned memory:

1. install full EL1 vector veneers that save a typed register frame and report
   ESR/FAR/ELR/SPSR through Swift panic handling;
2. discover and initialize the interrupt controller and ARM generic timer;
3. prove repeated timer IRQ delivery and bounded interrupt dispatch;
4. derive usable RAM from the device tree, reserve every kernel/DTB/DMA range,
   and pass allocator overlap/exhaustion tests;
5. replace the coarse boot map with permissioned final page tables and guard the
   exception and kernel stacks.

Only then should the project add preemptive threads and the first EL0 process.
