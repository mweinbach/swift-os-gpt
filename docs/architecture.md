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

No layer points upward. Not every box exists: the current EL0 image has a
proof-oriented report call and a bounded file-service call. A concrete SwiftFS
provider is mounted at `/Users` on the QEMU VirtIO-block path, and a
transport-neutral input/file-manager state machine exists inside the kernel.
The executable loader, system library, EL0 compositor/window protocol, and
general user-facing driver ABI remain future layers.

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
  preemption, plus a separately dispatched bounded file-service request used by
  the first process.

Before `eret` to EL0, the kernel scrubs both NOLOAD user-stack regions and the
entry veneer scrubs registers and FP/SIMD state that must not leak privileged
context. The proof is complete only after both thread identities report and both
have resumed following context switches. This is not yet a multicore scheduler,
a general process manager, or a stable syscall ABI.

## Graphics and monitor model

The production graphics boundary separates scene construction, GPU
rasterization, and display presentation. CPUs may update a fixed-capacity
retained tree in deterministic painter order, sample normalized Q16 animation,
compute bounded damage, and compile immutable backend-neutral commands. Every
pixel operation in a production frame--including clear, coverage, blending,
composition, scaling, and glyph sampling--must execute on a hardware GPU queue.
The execution policy rejects a production configuration without a hardware
rasterizer; software rasterization is an explicit diagnostic/oracle mode, not a
fallback.

The generic GPU model describes render passes, quads, per-corner radii, blend
mode, and glyph-atlas instances. Bounded command storage, a retained-scene
compiler, frame-slot/fence scheduling, separate rasterizer/presenter and image-
domain capabilities, and an allocation-free graphics-worker mailbox contain no
QEMU or Pi branch. A backend lowers these records to its device protocol, owns
its queue and fences, and reports completion before a render target can be
reused. Presentation remains distinct so a GPU-rendered image can move to a
separate scanout engine without making the scene model device-specific.

A shared logical canvas maps the 800 x 600 coordinate space into each physical
mode with centered integer scaling and letterboxing, then maps logical damage
back to the presentation contract. DMA mappings carry separate CPU-physical and
device-visible addresses, address width, byte extent, and coherency. Memory
domains model both CPU-visible system memory and device-local images, while
queue/fence capabilities describe ownership without assuming a particular CPU
or GPU configuration.

The QEMU GPU backend negotiates modern VirtIO and optional VirGL features, reads
generation-stable GPU configuration, supports separate external control
buffers, validates bounded capsets, and creates a live context when a compatible
VirGL2 device is available. Its production target is a host-private format-100
`B8G8R8A8_SRGB` render/scanout resource; color and scanout pixel backing is
never mapped or uploaded by the CPU. The session creates and uploads an
immutable GPU unit quad plus a 112 x 54 format-64 `R8_UNORM` glyph-mask atlas in
two bounded 112 x 27 coverage strips. The CPU prepares only those immutable
geometry and coverage assets. The session installs solid, analytic-rounded, and
mask-glyph shaders plus the required sampler view and nearest/linear sampler
states. `GPUDesktopScene` builds a five-layer 800 x 600 retained tree and full
damage;
`GPURetainedSceneCompiler` applies the centered integer viewport and emits the
attachment clear, scissor, one solid top bar, and four source-over rounded GPU
quads. A dedicated analytic shader pair evaluates per-corner signed distance
and derivative-based coverage over conservative transformed bounds.
`GPUBootTextScene` then loads the existing attachment and emits seven `SWIFTOS`
glyph draws whose placement, mask sampling, tinting, blending, composition, and
presentation execute on the GPU. The returned full presentation damage is
carried into the fenced flush, with the lifecycle totaling 18 ordered
transactions. The retained context/compiler can lower later immutable IR frames
into the same target and issue a fenced flush for checked damage.

Above that reusable session, the accelerated file-manager policy is also
backend-neutral. It owns a fixed-capacity browser, provider-name arena, window
input router, US keyboard composer, logical pointer scaling, and deterministic
animation invalidation in caller-owned memory. `GPUFileManagerSceneCompiler`
lowers provider-backed rows, window chrome, selection/hover state, text, and the
cursor into ordered chrome and glyph command buffers. The QEMU wrapper allocates
stable records, installs the synchronous canonical-input handler, and batches
both passes into one VirGL submission plus one damage flush. One owner must drain
input before rendering; the current SMP path does not service graphical input.
This file-manager path is host/source tested and its combined boot integration
is underway, but it has not produced local GL-backed VirGL pixels.

The existing end-to-end QEMU smoke still exercises a separate host 2D resource
with CPU-generated diagnostic backing, transfer, flush, and scanout. It is
presentation evidence, not GPU-rasterization evidence. The installed local QEMU
build has no GL-backed VirGL device, so the accelerated source path is covered
by protocol/host tests and a GPU-only dependency audit but has not generated a
locally hardware-exercised frame or screenshot.

The diagnostic QEMU path selects VirtIO-MMIO GPU 2D first and ramfb as fallback.
The diagnostic Pi path can bind a firmware-created simple framebuffer, write a
retained normal-memory surface, and clean damaged cache ranges before firmware
scanout reads them. Both paths remain useful for bring-up and comparison, but a
production configuration may not select them as its rasterizer.

The Pi backend consumes a mode already selected by firmware and described by
the runtime-patched Device Tree. It is not native HVS/HDMI modesetting and does
not submit work to V3D VII. Device-tree discovery now identifies the enabled V3D
hub/core/SMS, HVS, and graphics address-translation requirement and maps their
register resources through the shared boot-resource path. It does not yet
program the V3D MMU or command lists, HVS display lists/IOMMU, HDMI clocks/PHY,
hotplug/DDC/EDID, or vblank. Simple framebuffer also carries neither refresh
rate nor physical display dimensions, so pixel-fit scaling is available but
refresh/PPI-aware policy waits for a live EDID/DDC or equivalent metadata
driver. The implementation remains hardware-unverified.

The production QEMU branch draws its initial retained scene's attachment clear,
top bar, panel, sidebar, accent card, dock, and seven-glyph `SWIFTOS` label on
the GPU. Its bounded lowering supports solid quads, affine Q16 transforms,
clear/load/store, clipping, copy/source-over blend, analytic rounded coverage
that rejects singular or ill-conditioned inverse transforms, and sampling from
one immutable R8 mask atlas. The full diagnostic terminal text and continuous
retained status animation still run only in the explicit diagnostic CPU path.
The new kernel file-manager state supplies bounded focus, hit testing, pointer
capture, scrolling, keyboard navigation/type-ahead, and GPU scene compilation,
but there are no general image textures, dynamic font loading or shaping,
mutable atlas lifecycle, paths, shadows, EL0 window/surface protocol, or EL0
application surface. The local QEMU build still cannot exercise the accelerated
branch.

With four CPUs, `make run` publishes the ramfb frame and then follows the SMP/EL0
path. `QEMU_CPUS=1 make run` retains the interactive EL1 kernel monitor after
boot. The monitor, framebuffer, and VirtIO scanout are useful diagnostics, not
userland and not evidence of a complete desktop environment.

The eventual user compositor will own GPU queues and scanout. Applications will
submit owned surfaces and damage rectangles through handles rather than
receiving scanout or device mappings. QEMU VirGL and native Pi V3D/HVS drivers
will implement the same command, memory-domain, synchronization, and
presentation contracts with separate hardware backends; retained scene and
animation policy remain shared.

## Storage and user ABI direction

SwiftFS sits above the synchronous `BlockDevice` contract rather than VirtIO or
SDHCI directly. It alternates complete metadata/data banks and publishes a
CRC-protected superblock only after the inactive snapshot synchronizes. QEMU
reaches it through a VirtIO-backed signed data volume; the Pi runtime derives a
disjoint SwiftFS range beside the private log arena and exposes the same mounted-
provider seam through stable classified allocations. The Pi transport and mount
remain physical-hardware-unverified.

The first file-service SVC uses fixed-width request/result records, validates
whole EL0 ranges before copying, and confines each process to bounded generation-
tagged handles. Its operation vocabulary is `open`, `read`, `write`, `stat`,
`readdir`, and `close`. It is a real checked crossing, but not a POSIX ABI or a
general system library.

The eventual kernel ABI will cover process/thread control, virtual memory,
channels, object handles, clocks, files, sockets, windows, and debug output.
Records will use fixed-width explicit layouts; Swift implementation types will
not cross the boundary directly.

There is still no executable loader, dynamic process creation, general user-copy
facility outside the bounded file service, or stable system library. The VFS
uses bounded paths, role-based mounts, provider metadata, attenuated rights, and
generation-tagged handles; the explicit 40-byte input record similarly avoids
exposing Swift layout. These narrow crossings do not yet make the linked proof
image a general Swift userland.
