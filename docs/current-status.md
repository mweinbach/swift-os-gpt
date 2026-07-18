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
  and GIC resources, including multiple `reg` tuples, disabled-node filtering,
  and the range translation required by the current board fixtures.
- Device-tree-selected GICv3 initialization on QEMU, physical timer PPI delivery,
  acknowledgement/end-of-interrupt, rearming, and repeated IRQ evidence. A
  GICv2 implementation is linked for the Pi board contract, but has not been
  exercised on physical Pi hardware.
- Range-based physical-memory ownership derived from all discovered RAM banks,
  minus firmware reservation-map entries, `/reserved-memory`, the DTB, kernel,
  and final-table pool. A fixed-capacity page allocator owns the remaining
  ranges and is covered for overlap, alignment, exhaustion, and allocation.
- Final 4 KiB translation tables with separate executable text, read-only data,
  writable non-executable data, user text/data/stacks, and Device mappings.
  Unmapped guards protect the boot stack, all three secondary stacks, and both
  EL0 stacks. The kernel switches from the bootstrap table to this final root.
- DT-selected PSCI `CPU_ON`, using HVC in the direct-EL1 QEMU configuration and
  SMC in the virtualization/EL2 configuration, brings three secondaries into a
  dedicated assembly entry and then Swift on distinct stacks. CPU0 verifies
  release/acquire online publication for all four selected processors.
- A separately compiled and linked Embedded Swift user image. It executes at
  EL0 with a high virtual alias and two isolated guarded stacks, reports through
  a deliberately narrow SVC ABI, and contains no kernel object dependency.
- Two fixed-capacity CPU0-pinned EL0 threads with complete exception-context
  switching. Physical timer interrupts preempt the threads, and evidence is
  accepted only after both thread identities report and both resume following a
  switch.
- Swift volatile MMIO, PL011 transmit/receive, QEMU `fw_cfg` DMA publication,
  and a linker-owned 800 x 600 XRGB8888 framebuffer with software rasterization.
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

## Verification gates

`make test` requires all of the following:

1. a freestanding source-boundary audit for `Kernel/` and `Userland/`;
2. host tests for FDT parsing, monitor parsing, run-queue behavior, exception
   layout, memory-map/page-allocation foundations, final-table integration,
   preemptive EL0 scheduling, PSCI topology, and SMP publication/runtime logic;
3. separate user-image compilation/link inspection and a parser probe against a
   DTB emitted by the installed QEMU;
4. static ELF inspection proving AArch64 architecture, the expected entry/link
   contract, and no unresolved symbols;
5. three ordered EL1 cold boots plus an EL2-to-EL1 boot in single-CPU mode,
   including final paging, exception/GIC setup, ramfb publication, and timer IRQs;
6. interactive single-CPU monitor and exact framebuffer/render smoke tests;
7. four-CPU SMP/EL0 boots from both EL1 and EL2, requiring ordered evidence for
   owned memory, final tables, three online secondaries, both user threads, SVC
   reporting, context switches, and timer-driven preemption;
8. static Raspberry Pi 5 Image inspection, including its standard header,
   physical entry/reset addresses, 4 KiB page flags, BCM2712 high-MMIO bootstrap
   descriptor, architecture, and unresolved-symbol contract.

The rendered visual artifact is `.build/swiftos-frame.ppm`. It proves a
guest-rendered GUI-shaped frame, not a compositor, window system, or graphical
input stack.

## Not implemented yet

- scheduling user or general kernel work across CPUs other than CPU0, per-CPU
  interrupt/timer scheduling, migration, load balancing, and scheduler locking;
- an executable loader, process creation/destruction, demand paging, copy-on-
  write, signals, or a stable user system library and syscall ABI;
- persistent block storage, VFS, filesystem, permissions, or recovery;
- virtio/RP1 keyboard, pointer, GPU, block, entropy, USB, and network drivers;
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
and unpatched source-DTB contract only. No physical Raspberry Pi 5 boot, UART,
GICv2 timer delivery, PSCI startup, firmware-patched 8 GB allocator exercise,
framebuffer, input, or GUI path has been verified.

## Next coherent milestone

The next crossing should turn the proof scheduler into an operating-system
execution model: per-CPU scheduler state and interrupt interfaces, runnable work
on secondaries, a versioned syscall ABI, executable loading, and a minimal VFS.
Storage and input drivers can then support a real terminal-first user session;
the compositor follows after surface ownership and graphical input are defined.
