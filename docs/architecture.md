# Architecture

## Target system shape

SwiftOS uses a monolithic kernel while memory management, interrupts, drivers,
and process isolation are becoming stable. The code is clean-room freestanding
Embedded Swift; assembly is confined to reset, exception/context veneers,
firmware calls, atomics/barriers, and privileged instructions Swift cannot emit.
SwiftUI, Metal, Darwin, and Apple frameworks are not guest dependencies.

The intended dependency direction remains strict:

```text
Swift applications
    -> Swift system library and versioned syscall ABI
        -> kernel object/capability handles
            -> VFS, scheduler, networking, compositor
                -> device-independent driver protocols
                    -> AArch64 board drivers
                        -> MMIO and privileged instruction veneers
```

No layer points upward. Not every box exists: the current EL0 image has one
proof-oriented report syscall, while the loader, VFS, system library,
networking, compositor, and general driver stack remain future layers.

## Boot and board contract

Firmware or QEMU places the raw AArch64 image at its board link address and
passes the flattened device-tree address in `x0`. `_start` performs only the
work that must precede Swift:

1. retain the DTB pointer and normalize EL2 or EL1 entry to EL1h;
2. install early vectors and a linker-owned boot stack;
3. clear `.bss`, establish the coarse board bootstrap map, and enable the MMU,
   caches, and FP/SIMD access;
4. call `swiftos_main` on the boot CPU.

The kernel validates the DTB, selects a board description, then discovers its
serial, memory, reservations, CPU affinities, PSCI conduit, interrupt controller,
QEMU `fw_cfg`, and bounded driver resources such as `virtio,mmio`, a Pi firmware
mailbox, or `/chosen/simple-framebuffer`. QEMU `virt` is the verified contract.
The Raspberry Pi 5 linker/header/bootstrap descriptors and firmware-framebuffer
driver build and pass host/static inspection, but the resulting image has not
executed on physical hardware.

Secondary CPUs are not allowed to run the primary reset path. After memory,
vectors, and final tables are ready, CPU0 issues PSCI `CPU_ON`. Each selected
secondary enters `_secondary_start`, acquires a unique stack, installs the final
translation regime and vectors, calls Swift, publishes online state with release
semantics, and parks. CPU0 acquire-loads those publications before reporting the
four-core QEMU proof.

## Memory ownership and translation

The bootstrap identity map exists only to reach Swift and early board resources.
The runtime memory path then derives ownership from every enabled DT memory
tuple and subtracts, with checked range arithmetic:

- firmware reservation-map entries and enabled `/reserved-memory` spans;
- the complete kernel/linker image and linker-owned storage;
- DTB pages, after requiring the complete blob to lie in described RAM; and
- the physically contiguous final translation-table pool.

A fixed-capacity range map owns the sanitized result. The live classified
allocator then imports those ranges as the system-memory domain and retains an
active-allocation token ledger. Allocation domain, capabilities, proximity, and
page-table attributes are separate concepts. The same allocator can represent
CPU-inaccessible device-local memory and constrains requests by alignment,
highest address, capabilities, preferred domain, and explicit fallback policy.
It splits and coalesces ranges without a heap and rejects overlap, overflow,
wrong-token release, invalid alignment, and metadata exhaustion. Live allocation
and release are serialized by an IRQ-state-preserving AArch64 lock so future
secondary callers cannot race the shared ledger. Only system DRAM is discovered
at runtime today; additional firmware/device memory domains still need board-
specific discovery. There is not yet a general kernel heap or pageable object
layer.

Early board drivers emit a fixed-capacity `BootDriverResourceSet` before this
allocator activates. A shared resource planner rejects partial RAM overlap and
collisions with the kernel, DTB, or base platform devices; retains RAM-backed
driver memory as explicit reservations; and produces exact normal-memory or
Device mappings for the final tables. This makes adding framebuffer, mailbox,
and future DMA/MMIO drivers a data-driven extension instead of a second Pi- or
QEMU-specific memory path.

The kernel builds a 39-bit, 4 KiB-granule final address space and switches
`TTBR0_EL1` to it with a nonzero ASID. Exact mappings enforce these roles:

- kernel text: privileged read/execute;
- kernel and DTB read-only data: privileged read-only, non-executable;
- kernel mutable/linker storage: privileged read/write, non-executable;
- EL0 text/read-only data: user-readable with execution only on text;
- two EL0 stacks: user read/write and non-executable;
- discovered UART, GIC, QEMU firmware, and VirtIO-MMIO resources: Device
  memory; and
- sanitized free RAM: privileged direct-map memory.

Guard descriptors remain unmapped beneath the boot stack, each of the three
secondary stacks, and each of the two user stacks. The host integration tests
walk the generated tables to verify mappings, permissions, reservations, and
guards rather than accepting only a successful build.

## Exceptions, interrupts, and timer

The EL1 vector table saves a fixed 832-byte `AArch64ExceptionFrame`, including
all integer registers, Q0-Q31, FPCR/FPSR, thread/user stack state, and exception
syndrome registers. Swift performs bounded classification and dispatch; the
assembly veneer restores the selected frame and returns with `eret`.

Platform discovery chooses GICv3 or GICv2 by DT compatibility. Repeating timer
IRQ delivery is proven on QEMU's GICv3 path: CPU0 enables the architectural
physical timer PPI, acknowledges it through the GIC, rearms it, and writes three
ordered delivery markers. The GICv2/Pi implementation is compiled into the Pi
artifact but remains hardware-unverified.

The preemptive proof deliberately schedules only user-mode arrivals. A timer
arriving while CPU0 is in EL1 is rearmed without kernel preemption. Secondary
CPUs do not yet own per-CPU timer scheduling or accept runnable work.

## SMP and scheduling

The DT supplies 64-bit CPU affinities and the PSCI method. A packed, fixed-
capacity Swift topology records affinity, processor class, capability mask,
proximity domain, and startup eligibility while preserving the early 512-byte
storage contract. A separate boot configuration validates requested CPU count
against topology, target, state, and report capacities. It identifies the boot
CPU from all MPIDR affinity fields, selects at most four processors, and records
each `CPU_ON` result. The direct-EL1 QEMU DT selects HVC, while the
virtualization/EL2 QEMU DT and Pi board contract select SMC. Both four-core QEMU
smoke paths require CPU1, CPU2, and CPU3 to independently publish online before
`SWIFTOS:SMP_OK` is accepted. A separate two-core Cortex-A76 smoke proves that a
smaller topology follows the same startup and EL0-preemption path without
assuming the four-core configuration.

The current scheduler is an intentionally narrow first isolation milestone:

- one linked user address space and process identifier;
- two fixed-capacity threads, both pinned to CPU0;
- one complete saved exception frame per thread;
- two independent guarded EL0 stacks and thread-pointer values;
- round-robin switching on physical timer IRQs; and
- SVC report number 1, used only to prove each identity ran and resumed after a
  preemption.

Before `eret` to EL0, the kernel scrubs both NOLOAD user-stack regions and the
entry veneer scrubs registers and FP/SIMD state that must not leak privileged
context. The proof is complete only after both thread identities report and both
have resumed following context switches. This is not yet a multicore scheduler,
a general process manager, or a stable syscall ABI.

## Graphics and monitor model

The renderer owns a validated 32-bit linear surface and performs software
rasterization independently of presentation. Its first retained path is a
fixed-capacity layer tree in deterministic painter order, a bounded logical
damage region, and a software compositor with source-over alpha and four-sample
antialiased rounded rectangles. Animation uses normalized Q16 progress,
overflow-safe integer interpolation, deterministic easing curves, and a
phase-preserving frame pacer driven by the architectural counter. None of these
types contains a QEMU or Pi branch.

A shared logical canvas maps the 800 x 600 coordinate space into each physical
mode with centered integer scaling and letterboxing, then maps logical damage
back to the physical presentation contract. QEMU policy selects modern
VirtIO-MMIO GPU 2D first and ramfb as fallback; the Pi board path can instead
bind a firmware-created simple framebuffer. DMA mappings carry separate
CPU-physical and device-visible addresses, address width, byte extent, and
coherency.

The QEMU VirtIO path requires a DT `dma-coherent` transport. The Pi firmware
scanout is software-managed: the renderer writes its retained normal-memory
mapping and presentation cleans the damaged cache range with an architectural
completion barrier. This exercises the same display/driver resource contracts
without putting Pi conditionals into the renderer.

The VirtIO driver negotiates a modern split queue, fences each control command,
creates a host 2D resource, attaches the Swift-owned framebuffer as backing,
selects a scanout, and performs explicit transfer and flush operations for
monitor updates. The end-to-end smoke removes ramfb and validates both the
initial 800 x 600 desktop and a later command update through QEMU's GPU device.
This is a guest 2D scanout driver, not virgl/Venus 3D acceleration.

The Pi backend consumes a mode already selected by firmware and described by
the runtime-patched Device Tree. It is not native HVS/HDMI modesetting and does
not submit work to VideoCore. Simple framebuffer also carries neither refresh
rate nor physical display dimensions, so pixel-fit scaling is available but
refresh/PPI-aware policy waits for a live EDID/DDC or equivalent metadata
driver. The implementation remains hardware-unverified.

Desktop panels and terminal glyphs are still drawn directly. A retained rounded
status layer exercises mutation, damage repaint, alpha composition, frame
pacing, and partial presentation in the single-CPU monitor. The bootstrap tree
currently holds at most eight solid-color layers; there are no transforms,
textures, paths, shadows, font atlas, window/surface protocol, graphical input
path, or EL0 application surface yet.

With four CPUs, `make run` publishes the ramfb frame and then follows the SMP/EL0
path. `QEMU_CPUS=1 make run` retains the interactive EL1 kernel monitor after
boot. The monitor, framebuffer, and VirtIO scanout are useful diagnostics, not
userland and not evidence of a complete desktop environment.

The eventual user compositor will build on this renderer and own scanout.
Applications will submit owned surfaces and damage rectangles through handles
rather than receiving the scanout mapping. A physical board port implements the
same backend contract through its own display and input drivers; renderer and
animation policy remain shared.

## User ABI direction

The eventual kernel ABI will cover process/thread control, virtual memory,
channels, object handles, clocks, files, sockets, windows, and debug output.
Records will use fixed-width explicit layouts; Swift implementation types will
not cross the boundary directly.

Today only the minimal SVC report call exists. There is no executable loader,
dynamic process creation, checked general user-copy layer, VFS handle namespace,
or stable system library. Those contracts must be designed and tested before the
linked proof image can be described as a general Swift userland.
