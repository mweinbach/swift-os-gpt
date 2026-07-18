# Current status

This file is the line between what the guest demonstrably does and what remains
architecture work. A serial marker or screenshot is not subsystem evidence
unless a guest implementation and a repeatable test sit behind it.

## Implemented and verified on QEMU `virt`

- A static AArch64 ELF and raw boot image produced by Swift 6.2 Embedded Swift,
  with no Darwin or Apple-framework dependency.
- Reset entry from EL1 or EL2, EL1h setup, FP/SIMD enablement, `.bss` clearing,
  bootstrap translation, cache enablement, and linker-owned boot/per-CPU stacks.
- Full EL1 vector veneers and typed 832-byte exception frames preserving general
  registers, FP/SIMD state, ELR/SPSR/ESR/FAR, `SP_EL0`, and `TPIDR_EL0` before
  bounded dispatch in Swift.
- Device-tree discovery of memory, reservations, CPUs, PL011, `fw_cfg`, PSCI,
  GIC, and VirtIO-MMIO resources, including multiple `reg` tuples, disabled-
  node filtering, DMA-coherency presence, and the range translation required by
  the current board fixtures.
- Device-tree-selected GICv3 initialization on QEMU, physical timer PPI delivery,
  acknowledgement/end-of-interrupt, rearming, and repeated IRQ evidence. A
  GICv2 implementation is linked for the Pi board contract, but has not been
  exercised on physical Pi hardware.
- Range-based physical-memory ownership derived from all discovered RAM banks,
  minus firmware reservation-map entries, `/reserved-memory`, the DTB, kernel,
  and final-table pool. A live fixed-capacity classified allocator owns the
  remaining system-memory ranges with capability/proximity metadata and an
  allocation-token ledger. Its model also covers CPU-inaccessible device-local
  domains, constrained addresses, explicit fallback, and checked release. Live
  operations share an IRQ-state-preserving lock and compatibility range release
  resolves the original token under that lock.
- Final 4 KiB translation tables with separate executable text, read-only data,
  writable non-executable data, user text/data/stacks, and Device mappings.
  Unmapped guards protect the boot stack, all three secondary stacks, and both
  EL0 stacks. The kernel switches from the bootstrap table to this final root.
- DT-selected PSCI `CPU_ON`, using HVC in the direct-EL1 QEMU configuration and
  SMC in the virtualization/EL2 configuration, brings three secondaries into a
  dedicated assembly entry and then Swift on distinct stacks. CPU0 verifies
  release/acquire online publication for all four selected processors.
- Packed processor descriptions separate affinity, scheduling class,
  capabilities, proximity, and startup eligibility from a validated boot-
  resource configuration. In addition to the four Cortex-A72 proofs, a
  two-Cortex-A76 QEMU path reaches the same isolated EL0 preemption milestone.
- A separately compiled and linked Embedded Swift user image. It executes at
  EL0 with a high virtual alias and two isolated guarded stacks, reports through
  a deliberately narrow SVC ABI, and contains no kernel object dependency.
- Two fixed-capacity CPU0-pinned EL0 threads with complete exception-context
  switching. Physical timer interrupts preempt the threads, and evidence is
  accepted only after both thread identities report and both resume following a
  switch.
- Swift volatile MMIO, PL011 transmit/receive, QEMU `fw_cfg` DMA publication,
  and a linker-owned 800 x 600 XRGB8888 framebuffer with software rasterization.
- A modern VirtIO-MMIO GPU 2D driver with split-queue negotiation, fenced
  commands, resource backing, scanout selection, and explicit transfer/flush.
  The renderer uses a backend-independent scanout/DMA contract and keeps ramfb
  as the default fallback.
- A fixed-capacity interactive EL1 kernel monitor in single-CPU mode. `help`,
  `uname`, `status`, `clear`, `about`, and `uptime` use PL011 input/output while
  updating the rendered terminal.

The QEMU SMP proof means that four processors reached Swift kernel code. It does
not mean user work is balanced across them: the three secondary CPUs publish
online state and park, while both preempted EL0 threads remain pinned to CPU0.

## Operating modes

`make run` uses four CPUs by default and proceeds through memory activation,
timer IRQ proof, PSCI startup, and the EL0 preemption proof. The ramfb desktop is
published before entering user scheduling, but there is not yet an EL0 window
system or graphical input path.

Use `QEMU_CPUS=1 make run` for monitor mode. The single-CPU boot retains the
interactive EL1 monitor after the same memory, exception, GIC, timer, and ramfb
stages; it intentionally does not enter the multicore/EL0 acceptance path.

`make virtio-gpu-smoke` runs single-CPU monitor mode without a ramfb device. It
requires the modern VirtIO transport and GPU markers, validates the initial
desktop screenshot, submits a monitor command, waits for a post-presentation
marker, and verifies that the updated scanout differs. This is QEMU 2D-device
evidence only; it is not a Raspberry Pi or accelerated 3D graphics claim.

## Verification gates

`make test` requires all of the following:

1. a freestanding source-boundary audit for `Kernel/` and `Userland/`;
2. host tests for FDT parsing, monitor parsing, run-queue behavior, exception
   layout, unclassified and classified memory allocation, final-table
   integration, boot-driver resource planning, simple-framebuffer safety,
   display scaling/DMA contracts, PSF2 fonts, VirtIO-GPU protocol layouts,
   preemptive EL0 scheduling, PSCI topology, and SMP publication/runtime logic;
3. separate user-image compilation/link inspection and a parser probe against a
   DTB emitted by the installed QEMU;
4. static ELF inspection proving AArch64 architecture, the expected entry/link
   contract, and no unresolved symbols;
5. three ordered EL1 cold boots plus an EL2-to-EL1 boot in single-CPU mode,
   including final paging, exception/GIC setup, ramfb publication, and timer IRQs;
6. interactive single-CPU monitor, exact ramfb rendering, and modern
   VirtIO-MMIO GPU scanout/update smoke tests;
7. four-CPU SMP/EL0 boots from both EL1 and EL2, requiring ordered evidence for
   owned memory, final tables, three online secondaries, both user threads, SVC
   reporting, context switches, and timer-driven preemption;
8. static Raspberry Pi 5 Image inspection, including its standard header,
   physical entry/reset addresses, 4 KiB page flags, BCM2712 high-MMIO bootstrap
   descriptor, architecture, and unresolved-symbol contract;
9. an alternate two-Cortex-A76 CPU configuration reaching the same secondary-
   startup and EL0-preemption acceptance markers.

The ramfb and GPU visual artifacts are `.build/swiftos-frame.ppm` and
`.build/swiftos-virtio-gpu.ppm`. They prove guest-rendered GUI-shaped frames and
presentation, not a compositor, window system, or graphical input stack.

## Implemented but hardware-unverified Raspberry Pi display path

The Pi board package requests a firmware-selected HDMI mode and a 32-bit boot
framebuffer. At boot, SwiftOS can discover a firmware-patched
`/chosen/simple-framebuffer`, validate its geometry and supported pixel format,
retain any valid scanout range before allocator activation, and create exact
normal-memory mappings for the supported 32-bit rendering path. The Pi firmware
mailbox aperture is discovered as a separate Device-memory driver resource.

The same renderer and terminal used by both QEMU backends draw through a shared
logical canvas. Its integer viewport centers and letterboxes the 800 x 600
desktop on larger modes, while the Pi presenter cleans damaged cache ranges
before firmware scanout reads them. Unsupported firmware pixel formats remain
reserved rather than being returned to the allocator, and the kernel falls back
to serial-only operation.

This is a firmware-configured scanout handoff, not a native BCM2712 HVS/HDMI
modesetting driver and not VideoCore 3D acceleration. The simple-framebuffer
contract does not report refresh rate or physical panel dimensions, so refresh
and PPI remain unknown and current scaling is based on pixel fit. A bounded PSF2
font parser and rasterizer are host-tested, but no font asset or live boot-font
selection is wired into the desktop. None of this path has executed on physical
Pi hardware yet.

## Not implemented yet

- scheduling user or general kernel work across CPUs other than CPU0, per-CPU
  interrupt/timer scheduling, migration, load balancing, and scheduler locking;
- an executable loader, process creation/destruction, demand paging, copy-on-
  write, signals, or a stable user system library and syscall ABI;
- persistent block storage, VFS, filesystem, permissions, or recovery;
- virtio/RP1 keyboard, pointer, block, entropy, USB, and network drivers;
- accelerated VirtIO 3D, native BCM2712 HVS/HDMI modesetting, VideoCore GPU
  submission, live EDID/DDC ownership, and IOMMU-backed device address
  translation;
- a compositor, window/surface protocol, graphical applications, or graphical
  input routing;
- physical Raspberry Pi 5 execution and a Raspberry Pi 5 GUI;
- an Apple Silicon board port or its machine-specific drivers.

The only current SVC contract is the proof-oriented user-thread report call. It
must not be described as a general syscall layer. The current renderer and EL1
monitor must not be described as a compositor or user desktop.

## Raspberry Pi 5 boundary

`make rpi5-inspect` builds and statically validates
`.build/raspberry-pi-5/kernel8.img`. With a caller-supplied pinned firmware
checkout, `make rpi5-package` creates the boot-partition file set and hashes.
Packaging also runs the parser against that checkout's real Pi 5 DTB and requires
UART10 at `0x107d001000`, the GICv2 distributor/CPU-interface resources, PSCI
`smc`, four affinities, and the ATF reservation. These gates prove an artifact
and unpatched source-DTB contract. The kernel also contains a host-tested driver
for the runtime-patched firmware simple framebuffer and mailbox resources. No
physical Raspberry Pi 5 boot, UART, GICv2 timer delivery, PSCI startup,
firmware-patched 8 GB allocator exercise, HDMI frame, input, or GUI path has
been verified.

## Next coherent milestone

The next work is driver-first: physically validate the Pi firmware-framebuffer
handoff and then add bounded EDID/display metadata, input, block storage,
entropy, and networking drivers behind shared resource and DMA contracts. In
parallel, the proof scheduler still needs per-CPU state and interrupt
interfaces, runnable work on secondaries, a versioned syscall ABI, executable
loading, and a minimal VFS. A compositor follows after surface ownership and
graphical input are defined.
