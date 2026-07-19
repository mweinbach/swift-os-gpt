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
  and a linker-owned 800 x 600 XRGB8888 framebuffer with explicitly diagnostic
  software rasterization.
- A modern VirtIO-MMIO GPU 2D driver with split-queue negotiation, fenced
  commands, resource backing, scanout selection, and explicit transfer/flush.
  The current diagnostic renderer uses a backend-independent scanout/DMA
  contract and keeps ramfb as its default fallback.
- A fixed-capacity retained layer tree and damage region, deterministic Q16
  timelines and frame pacing, and a diagnostic software compositor with source-
  over alpha and antialiased rounded rectangles. The single-CPU monitor
  continuously animates one retained status layer and presents only its mapped
  damage.
- A fixed-capacity interactive EL1 kernel monitor in single-CPU mode. `help`,
  `uname`, `status`, `clear`, `about`, and `uptime` use PL011 input/output while
  updating the rendered terminal.
- Bounded, case-sensitive UTF-8 VFS paths and a synthetic root namespace for
  immutable `/System`, mutable `/Users`, ephemeral `/Temporary`, capability-
  gated `/Devices`, and `/Volumes/<name>`. Kernel-only log/raw-media volumes
  cannot mount; exact unmount revokes generation-tagged handles before provider
  teardown. Stable metadata, directory-cookie, and provider I/O contracts are
  host-tested.
- A native modern VirtIO-MMIO block driver and crash-consistent SwiftFS user
  volume on QEMU. The runtime initializes or opens the signed data volume,
  isolates the kernel-log and user ranges, formats or remounts alternating
  copy-on-write SwiftFS banks, seeds `Welcome.txt`, and publishes the concrete
  provider from stable allocator-owned storage.
- A checked EL0 file-service crossing for the mounted `/Users` provider. Its
  versioned request/result records, whole-range user-copy validation, bounded
  per-process handle table, and policy checks support `open`, `read`, `write`,
  `stat`, `readdir`, and `close`. Host tests cover the complete operation set;
  the four-boot QEMU smoke proves format/seed, remount, live EL0
  open/read/write/close under preemption, and post-write remount durability.
- A versioned 40-byte input record, fixed-capacity FIFO with sequence gaps and
  saturating loss/corruption accounting, and allocation-free USB HID boot
  keyboard/mouse decoders. Malformed, duplicate, reserved, and rollover reports
  leave the last good device state unchanged.
- A modern VirtIO-MMIO input transport with one shared split-ring geometry,
  64 pre-posted device-writable eight-byte buffers, generation-stable capability
  discovery, descriptor ownership tracking, evdev-to-HID/pointer translation,
  and `SYN_REPORT` boundaries. In single-CPU monitor mode, QEMU keyboard and
  mouse devices feed the canonical queue; QMP proves A down/up, relative
  `+37/-19` motion, and left-button down/up after guest DMA decoding.
- Backend-neutral accelerated file-manager state with fixed-capacity provider
  loading, stable copied names, stale-cookie restart, bounded truncation,
  pointer scaling and capture, focus/hit testing, scrolling, US keyboard
  navigation/type-ahead, and deterministic animation invalidation. A
  synchronous canonical-event dispatcher keeps transport decoding separate
  from this UI policy.

The QEMU SMP proof means that four processors reached Swift kernel code. It does
not mean user work is balanced across them: the three secondary CPUs publish
online state and park, while both preempted EL0 threads remain pinned to CPU0.

## Implemented QEMU GPU execution path

The production invariant is that CPUs build retained scene state, animation,
damage, and immutable render commands while a hardware GPU produces every
displayed pixel. Software rasterization is retained only as an explicitly
selected diagnostic/reference path; production policy must fail closed when no
hardware rasterizer is available.

The accelerated QEMU boot branch is wired into the guest and attempts VirtIO 3D
before allocating a diagnostic framebuffer. A compatible VirGL2 device follows
this path:

- selects an enabled scanout and validates bounded renderer capabilities,
  including render-target and scanout support for alpha-preserving format 100
  `B8G8R8A8_SRGB` and sampler support for format 64 `R8_UNORM`;
- creates one GPU-only color target, one six-vertex unit-quad buffer, and one
  immutable 112 x 54 R8 glyph-mask atlas, then uploads the atlas as two bounded
  112 x 27 coverage strips;
- creates a VirGL context, surface/framebuffer, solid, analytic-rounded, and
  mask-glyph shader pairs, sampler view, nearest/linear sampler states, vertex
  elements, rasterizer, depth/stencil/alpha state, and copy/source-over blend
  state;
- constructs an 800 x 600 five-layer `RetainedLayerTree`, marks a full logical
  `DamageRegion`, maps it through a centered integer `DisplayViewport`, and
  lowers it through `GPURetainedSceneCompiler` into one GPU clear, one solid
  top bar, and four shader-antialiased rounded GPU quads, then loads that target
  for seven GPU-sampled `SWIFTOS` glyph draws and publishes the compiler-provided
  full presentation damage through set-scanout and flush after 18 ordered
  fenced transactions; and
- preserves the initialized session and compiler so later immutable render-IR
  frames can be lowered, submitted, and flushed with a checked damage rectangle
  without CPU-generated color or scanout backing or uploads. The CPU prepares
  only immutable geometry and R8 coverage assets; visible placement, sampling,
  tinting, blending, composition, and presentation remain GPU work.

The supporting shared infrastructure includes:

- bounded GPU render passes, blended/rounded quad and glyph-atlas commands,
  sealed command storage, an allocation-free mask-atlas writer, boot-text scene
  construction, and a retained-scene compiler;
- separate rasterizer, presenter, image-domain, queue, and fence capabilities,
  plus triple-buffer frame-slot scheduling and a graphics-worker mailbox;
- optional VirtIO 3D feature negotiation, generation-stable device
  configuration, external DMA control buffers, bounded capset/context/resource/
  submit packet definitions, VirGL capability validation, and allocation-free
  VirGL surface/framebuffer/clear/state/shader/sampler/texture/draw/GPU-copy
  encoding and device-neutral IR lowering; and
- Device Tree discovery and final Device-memory mapping for the Pi 5 V3D VII
  hub/core/SMS registers, HVS registers, and graphics address-translation
  requirement.

The deterministic transport tests verify the exact bootstrap packet sequence,
fences, unit-quad upload, exact atlas bytes and two-strip packets, glyph shader
and sampler state, five quad draws plus seven glyph draws, reusable submission,
and damage flush. Scene-builder and lowering tests cover painter order, 1080p
and 4K integer viewport scaling, full-clear presentation damage, four
independent corner radii, transformed padded bounds, shader switching, R8
capability rejection, glyph sampling, and fail-closed inverse validation. A
source audit requires the `GPUDesktopScene`, rounded-shader, mask-atlas, and
`GPUBootTextScene` crossings and rejects software-rasterizer, software-text, and
framebuffer types from accelerated activation and execution. The installed
local QEMU build does not expose a GL-backed VirGL device, however, so the
accelerated markers and pixels have not been observed on a locally exercised
hardware backend and there is no accelerated screenshot evidence yet.

The GPU-only file-manager layer now compiles mounted-provider rows, window
chrome, selection/hover state, text, and the routed cursor into two immutable
ordered command buffers. The QEMU runtime owns its browser/router/animation
state in allocator-backed stable memory and presents both buffers with one
`VirtIOGPU3DSession.renderBatch` submission and one damage flush; it has no
software framebuffer or rasterizer dependency. Focused tests cover routing,
scaled pointer remainders, keyboard type-ahead, animation retirement,
stale-cookie restart, copied provider names, and bounded directory truncation.
The source audit extends the GPU-only rule through this runtime. Combined guest
boot-loop integration is underway, so this is not yet local VirGL pixel or
interactive-desktop evidence.

## Operating modes

`make run` uses four CPUs by default and proceeds through memory activation,
timer IRQ proof, PSCI startup, and the EL0 preemption proof. It attempts the
production VirGL route first and, when no compatible device is present, marks
and publishes the explicit ramfb diagnostic before entering user scheduling.
The polling input runtime is deliberately inactive in this SMP mode until a
kernel service thread or IRQ-dispatch path exists. There is not yet an EL0
window system or live SMP graphical-input service; the bounded kernel-side
file-manager routing model is only host-tested in this mode.

Use `QEMU_CPUS=1 make run` for monitor mode. The single-CPU boot retains the
interactive EL1 monitor after the same memory, exception, GIC, timer, and ramfb
stages. Its architectural-counter-driven status indicator is the current live
retained-compositor proof. When modern VirtIO input devices are present, this
mode also owns their bounded cooperative polling. It intentionally does not
enter the multicore/EL0 acceptance path.

`make virtio-gpu-smoke` runs single-CPU monitor mode without a ramfb device. It
requires the modern VirtIO transport and GPU markers, validates the initial
desktop screenshot, submits a monitor command, waits for a post-presentation
marker, and verifies that the updated scanout differs. The device presents a
CPU-rasterized diagnostic surface. This is QEMU 2D-device evidence only; it is
not a Raspberry Pi or accelerated 3D graphics claim. The installed QEMU lacks
the GL-backed device needed to add the VirGL production branch to this smoke.

`make virtio-input-smoke` adds modern QEMU VirtIO keyboard and mouse devices in
single-CPU monitor mode. QMP injects one A press/release, exact relative motion,
and a left-button press/release. The test accepts only markers emitted after the
guest has consumed eventq DMA, translated evdev codes, encoded the canonical
record, and dequeued it again. It does not prove focus, text composition, a
visible cursor, SMP delivery, USB-host input, or Raspberry Pi hardware.

The accelerated file-manager integration targets the same single-owner loop:
one CPU drains VirtIO input, synchronously routes canonical events, updates UI
state, and then services the GPU session. It is intentionally inactive as an
input path once the SMP/EL0 scheduler owns CPU0. No cross-CPU UI mutation is
claimed.

## Verification gates

`make test` requires all of the following:

1. a freestanding source-boundary audit for `Kernel/` and `Userland/`;
2. host tests for FDT parsing, monitor parsing, run-queue behavior, exception
   layout, unclassified and classified memory allocation, final-table
   integration, boot-driver resource planning, simple-framebuffer safety,
   display scaling/DMA contracts, PSF2 fonts, fixed-point animation, retained
   layers, damage coalescing, diagnostic software composition/rasterization,
   GPU command compilation/policy/frame scheduling/worker publication,
   VirtIO-GPU 2D/3D protocol layouts, VirGL encoding/capability validation,
   device-neutral-to-VirGL IR lowering, GPU-only session lifecycle/damage flush,
   accelerated file-manager scene/state/input routing, VFS path/mount/access/
   handle invariants, SwiftFS format/provider/crash recovery, EL0 file-service
   dispatch, input ABI/queue/HID state machines,
   VirtIO-input queue/configuration/translation, preemptive EL0 scheduling,
   PSCI topology, and SMP publication/runtime logic;
3. separate user-image compilation/link inspection and a parser probe against a
   DTB emitted by the installed QEMU;
4. static ELF inspection proving AArch64 architecture, the expected entry/link
   contract, and no unresolved symbols;
5. three ordered EL1 cold boots plus an EL2-to-EL1 boot in single-CPU mode,
   including final paging, exception/GIC setup, ramfb publication, and timer IRQs;
6. interactive single-CPU monitor, exact ramfb rendering, bounded retained
   animation, modern VirtIO-MMIO GPU scanout/update, QMP-to-guest VirtIO
   keyboard/pointer, and persistent VirtIO-block/SwiftFS remount smoke tests;
7. four-CPU SMP/EL0 boots from both EL1 and EL2, requiring ordered evidence for
   owned memory, final tables, three online secondaries, both user threads, SVC
   reporting, context switches, and timer-driven preemption;
8. static Raspberry Pi 5 Image inspection, including its standard header,
   physical entry/reset addresses, 4 KiB page flags, BCM2712 high-MMIO bootstrap
   descriptor, architecture, and unresolved-symbol contract;
9. an alternate two-Cortex-A76 CPU configuration reaching the same secondary-
   startup and EL0-preemption acceptance markers.

The visual artifacts include `.build/swiftos-frame.ppm`, the low/peak
`.build/swiftos-animation*.ppm` pair, and `.build/swiftos-virtio-gpu.ppm`. They
prove guest CPU-rendered diagnostic frames, a bounded retained compositor
update, and two presentation backends; they do not prove an EL0 window system,
routed file-manager interaction, or GPU rasterization.

## Implemented but hardware-unverified Raspberry Pi display path

The Pi board package requests a firmware-selected HDMI mode and a 32-bit boot
framebuffer. At boot, SwiftOS can discover a firmware-patched
`/chosen/simple-framebuffer`, validate its geometry and supported pixel format,
retain any valid scanout range before allocator activation, and create exact
normal-memory mappings for the supported 32-bit rendering path. The Pi firmware
mailbox aperture is discovered as a separate Device-memory driver resource.

The same diagnostic renderer and terminal used by both QEMU backends draw
through a shared logical canvas. Its integer viewport centers and letterboxes
the 800 x 600 desktop on larger modes, while the Pi presenter cleans damaged
cache ranges before firmware scanout reads them. Unsupported firmware pixel
formats remain reserved rather than being returned to the allocator.

The Pi image also contains a board-neutral, bounded DWC2 device-mode stack. It
powers the USB domain through the discovered firmware property mailbox,
enumerates a CDC ACM plus vendor-debug composite device, and carries a versioned
full-frame/damage stream to the macOS viewer over USB-C. The same completed
simplefb surface is mirrored when HDMI exists; otherwise the kernel owns an
800 x 600 headless diagnostic surface and remains in the monitor loop so the
polled controller progresses. This code and the viewer are host-tested, but
physical USB enumeration remains unverified.

The Pi image also binds the boot-DT's removable `brcm,bcm2712-sdhci` controller
to the shared synchronous block contract. After the local HDMI/USB observation
window, it initializes the card in bounded PIO mode, accepts only an
unambiguous MBR plus signed `SWOSDATA` volume, incrementally recovers the 2 MiB
log arena, and durably appends at most one retained 48-byte kernel event per
cooperative pass. It never rewrites an ambiguous MBR or signed data-volume
layout; once those validate, the disjoint user subrange may be opened or
formatted as blank SwiftFS. Discovery, signature, bounds, or transport failure
drops the relevant write authority. This path is host- and link-tested but has
not written or recovered a record on physical Pi hardware.
The SD controller record, SwiftFS scratch, and provider record use stable
classified allocations. A host-tested policy derives disjoint absolute log and
user-filesystem ranges. A resumable bootstrap performs at most one block
operation, synchronization, or CPU-only validation phase per cooperative pass,
never concurrently with log work, and publishes the same SwiftFS provider seam
as QEMU. No Pi filesystem or raw block mapping is exposed directly to EL0, and
the Pi provider has not mounted on physical hardware.

This is a diagnostic firmware-configured scanout handoff, not a production
graphics path, a native BCM2712 HVS/HDMI modesetting driver, or V3D VII
acceleration. The simple-framebuffer contract does not report refresh rate or
physical panel dimensions, so refresh and PPI remain unknown and current scaling
is based on pixel fit. A bounded PSF2 font parser and rasterizer are host-tested,
but the Pi path has no packaged PSF2 asset, live font selection, or native GPU
atlas. The fixed R8 atlas used by QEMU's VirGL session does not constitute Pi
GPU text support. None of this path has executed on physical Pi hardware yet.

## Not implemented yet

- scheduling user or general kernel work across CPUs other than CPU0, per-CPU
  interrupt/timer scheduling, migration, load balancing, and scheduler locking;
- an executable loader, process creation/destruction, demand paging, copy-on-
  write, signals, or a stable user system library and syscall ABI;
- filesystem growth beyond the bounded whole-snapshot SwiftFS design, EL0
  create/remove/rename operations, process-credential permissions, dynamic
  mounts, a general system library, or broader user-data recovery tooling;
- SMP/IRQ-driven VirtIO input service, RP1 PCIe/xHCI and USB-host HID input,
  entropy, and additional network drivers;
- hardware execution and captured-pixel validation of the VirtIO/VirGL path,
  sustained frame-scheduler/graphics-worker integration, native BCM2712 V3D VII
  MMU/command submission, HVS display lists and IOMMU integration,
  HDMI modesetting/clock/PHY control, live HPD/DDC/EDID ownership, vblank, and
  refresh/PPI-aware output policy;
- an EL0 compositor service, window/surface protocol, graphical applications,
  general textures/paths, or user-process graphical input delivery;
- physical Raspberry Pi 5 execution and a Raspberry Pi 5 GUI;
- an Apple Silicon board port or its machine-specific drivers.

The current SVC contracts are the proof-oriented user-thread report and the
bounded file-service request. They must not be described as a general stable
syscall layer. The retained scene and file-manager foundations remain kernel
bootstrap infrastructure, not an EL0 compositor service or user desktop.

## Raspberry Pi 5 boundary

`make rpi5-inspect` builds and statically validates
`.build/raspberry-pi-5/kernel8.img`. With a caller-supplied pinned firmware
checkout, `make rpi5-package` creates the boot-partition file set and hashes.
Packaging also runs the parser against that checkout's real Pi 5 DTB and requires
UART10 at `0x107d001000`, the GICv2 distributor/CPU-interface resources, PSCI
`smc`, four affinities, and the ATF reservation. These gates prove an artifact
and unpatched source-DTB contract. The package carries the official pinned
`dwc2.dtbo`, applies it in peripheral mode, and records its hash. Platform
discovery host-tests the translated DWC2 MMIO resource and keeps QEMU free of
that Pi-only contract. The kernel retains the DWC2 and mailbox mappings, powers
the USB domain, initializes the controller in polled PIO device mode, and can
export the completed diagnostic desktop through the host-tested CDC/SDDP path.
The kernel also contains a host-tested driver for the runtime-patched firmware
simple framebuffer, a headless USB surface fallback, and a removable-SD binding
that can persist the retained kernel log and bootstrap a disjoint SwiftFS user
range only after signed-volume validation, using stable allocator-owned records.
No physical Raspberry Pi 5 boot, UART, USB enumeration/frame, SD transfer/log
recovery, Ethernet link, GICv2 timer delivery, PSCI startup, firmware-patched
8 GB allocator exercise, HDMI frame, input, or GUI path has been verified.

## Next coherent milestone

The next QEMU graphics milestone is to finish the combined file-manager boot
integration, exercise it on a GL-backed VirGL device, and retain accelerated
frame and interaction evidence. Ongoing frames then need the reusable session,
frame scheduler, and graphics-worker mailbox. The fixed boot atlas must grow
into bounded font loading,
layout/shaping, dynamic atlas management, and batched glyph runs. The Pi backend
independently needs native V3D VII command submission and address translation
plus HVS, vblank, HDMI, HPD/DDC/EDID, clock, PHY, and GPU font paths behind the
same contracts; simplefb remains only a bring-up diagnostic. Pi USB-host input,
richer filesystem policy, entropy, and broader networking remain parallel work.
The proof
scheduler still needs per-CPU state and interrupt interfaces, runnable work on
secondaries, a broader versioned syscall ABI, and executable loading before the
renderer can become a user-facing compositor.
