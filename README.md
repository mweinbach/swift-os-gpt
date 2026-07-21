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
firmware-loadable kernel image. Its board package can retain a firmware-created
Device Tree `simple-framebuffer` and map it into the final address space for an
explicit diagnostic renderer. Device-tree discovery also identifies and maps
the Pi 5 V3D VII renderer, HVS scanout, and required address-translation
resources behind backend-neutral graphics contracts. No native Pi GPU, HVS,
HDMI, IOMMU, EDID, or vblank driver is active yet. The image has **not** been
run on physical hardware, so Pi 5 execution and HDMI output remain unverified
and unsupported.

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

1. full EL1 exception frames; inherited or explicit Device Tree interrupt-parent
   resolution using each controller's `#interrupt-cells`; and DT-selected GICv3
   or GICv2 delivery of the non-secure EL1 physical-timer tuple, with global
   distributor setup separated from each processor's local PPI/interface setup;
2. range-based RAM ownership with firmware/kernel/DTB/table reservations, a
   live fixed-capacity classified allocator for distinct memory domains,
   final permissioned page tables, and unmapped stack guards;
3. bounded processor descriptions and startup configurations, with dense
   `TPIDR_EL1` logical IDs and four Cortex-A72 QEMU CPUs or two Cortex-A76 CPUs
   entering the same Swift path. Each selected secondary completes two affinity-
   pinned bounded Swift kernel-work slots, one quantum per local physical-timer
   IRQ, before publishing task/checksum, unique-stack, and timer-count evidence;
4. a separately linked Embedded Swift EL0 image in one shared immutable address-
   space layout, five guarded user stacks and five complete saved context frames,
   and a narrow SVC report ABI. One IRQ-safe locked global run queue supports
   up to four managed CPUs and starts `processorCount + 1` fixed threads (at
   most five);
   processor-local timer IRQs preempt them, and lease-attributed SVC reports
   prove that complete userspace contexts really migrate between CPUs;
5. a backend-independent diagnostic software surface presented through QEMU
   ramfb or a native Swift modern VirtIO-MMIO GPU 2D driver, a centered
   integer-scaled logical desktop for arbitrary scanout sizes, and a retained
   scene foundation with bounded damage, source-over alpha, antialiased rounded
   layers, fixed-point easing, and paced animation in the single-CPU monitor;
6. a production QEMU GPU path that negotiates VirGL, creates a host-private
   format-100 `B8G8R8A8_SRGB` render/scanout target, GPU unit-quad buffer, and
   112 x 54 format-64 `R8_UNORM` glyph-mask atlas, uploads that atlas in two
   bounded 112 x 27 strips, and installs solid, analytic-rounded, and
   mask-glyph pipelines. It builds the 800 x 600 boot desktop as five retained
   logical layers, compiles full logical damage into one GPU clear, one solid
   quad, and four analytic antialiased rounded quads at a centered integer
   scale, then overlays seven GPU-sampled `SWIFTOS` glyphs and publishes
   scanout only after 18 ordered fenced transactions. The initialized session
   also accepts reusable GPU-only render-IR submissions and flushes their
   declared damage; and
7. shared GPU foundations around that path: bounded render commands and
   retained-scene compilation, frame-slot/fence scheduling, a graphics-worker
   mailbox, strict production execution policy, and Pi V3D/HVS resource
   discovery and mapping; and
8. a crash-consistent SwiftFS provider over a native Swift VirtIO block driver.
   QEMU formats or remounts a magic- and CRC-validated data volume, publishes
   the provider through a stable allocator-owned record, mounts it at `/Users`,
   and exposes checked EL0 `open`, `read`, `write`, `stat`, `readdir`, and
   `close` operations. The
   block smoke proves blank-media format and seed, remount, EL0 read/write while
   preemption continues, and another remount that observes the EL0 write; and
9. a versioned input ABI, loss-aware queue, USB HID boot decoders, and a real
   single-CPU QEMU VirtIO keyboard/pointer path exercised through QMP and guest-
   owned DMA. Above that transport, backend-neutral file-browser state now
   handles bounded directory loading, focus, pointer capture, scrolling, US-key
   composition, type-ahead, selection, scaling, and paced animation. A GPU-only
   file-manager scene compiler and QEMU VirtIO 3D runtime batch chrome and text
   through the retained GPU session. The live guest path loads the mounted
   provider, presents the first frame, completes the opening transition, and in
   single-CPU mode serializes input draining with GPU redraws. This path is
   compiled, host-tested, and source-audited, but it has not been exercised
   locally through a GL-backed VirGL device or captured as accelerated pixels.

The production graphics invariant is now strict: CPUs may update retained scene
state, compute animation and damage, and compile backend-neutral command buffers,
but hardware GPU queues must produce every displayed pixel. The software
rasterizer remains only as an explicit diagnostic path and reference oracle.
The QEMU boot path now crosses that boundary when a compatible VirGL2 device is
available: it uploads no CPU-generated color or scanout pixels. The CPU prepares
only immutable geometry and R8 glyph coverage; placement, sampling, tinting,
blending, composition, and presentation execute in VirGL. A session failure
parks the kernel instead of falling back to software. Ramfb and VirtIO-GPU 2D
remain explicitly marked diagnostic modes. The installed local QEMU build
cannot instantiate a VirGL GL device, so the accelerated path has source,
protocol, and host-test coverage but its pixels have not been exercised locally
on a hardware-accelerated QEMU backend. The statically inspected Pi image has
not crossed the boundary: Pi simplefb is diagnostic only, and V3D VII/HVS/HDMI
support remains discovery, mapping, and roadmap work.

This is not yet a general-purpose OS. The next layers include accelerated QEMU
pixel evidence, richer GPU primitives and font loading, a native Pi
V3D/HVS/HDMI path, dynamic process/thread admission, independent process address
spaces and process migration, general kernel preemption and load balancing, an
executable loader, broader filesystem mutation and credential policy, Pi USB-
host input, a user-facing surface/window protocol, networking, and a stable
system library and syscall ABI.

See [Architecture](docs/architecture.md), [Renderer foundation](docs/renderer.md),
[Files and input](docs/files-and-input.md), and
[Hardware roadmap](docs/hardware-roadmap.md) for the contracts behind those
milestones. [Current status](docs/current-status.md) separates working guest
code from the next kernel frontiers.

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
make animation-smoke
make virtio-gpu-smoke
make virtio-input-smoke
make virtio-block-swiftfs-smoke
make smp-el0-smoke
make cpu-config-smoke
make test
```

`make run` boots four CPUs by default and follows the verified SMP/EL0 path after
publishing the QEMU ramfb display. Before CPU0 publishes the shared EL0 scheduler,
each secondary initializes its local interrupt state and completes two bounded,
affinity-pinned Swift work slots paced by that CPU's physical-timer IRQs. All
managed CPUs then enter the fixed migratable userspace pool. `make smp-el0-smoke`
exercises both GICv3 and GICv2 from EL1 and EL2; `make cpu-config-smoke` adds a
two-core Cortex-A76 configuration and, on both controller versions, proves that
an eight-CPU DT is deliberately capped at four managed CPUs. Use
`QEMU_CPUS=1 make run` for the interactive EL1
kernel monitor; type monitor commands in the terminal that launched QEMU, and
PL011 input updates both serial output and the guest terminal window.
`make virtio-gpu-smoke` removes ramfb and proves the same surface plus a later
monitor update through a modern VirtIO-MMIO GPU scanout. This is a real guest
2D display driver against QEMU's device model, but the pixels in this smoke are
still produced by the diagnostic CPU rasterizer. It is not 3D acceleration or
evidence of a Raspberry Pi display driver.

At boot, SwiftOS attempts the separate VirGL production route before selecting
that diagnostic path. A compatible device reaches `SWIFTOS:VIRTIO_GPU_3D_OK`
and `SWIFTOS:GPU_FRAME_READY` only after the GPU command stream has completed
and the target has been scanned out and flushed. The currently installed QEMU
does not expose the required GL-backed VirtIO-GPU device, so those accelerated
markers and pixels are not part of the local smoke evidence yet.

On a host whose QEMU exposes a GL-backed `virtio-gpu-gl-device`, the strict
opt-in acceptance gate is:

```sh
make virtio-gpu-3d-acceptance
```

It requires a mounted SwiftFS provider; ordered accelerator, file-manager
ready, first-frame, and steady-frame markers; a valid nonuniform 800 x 600 GPU
screenshot; exact injected relative pointer motion; an interaction-frame
marker; and at least 16 changed pixels in a second screenshot. Capability
absence makes the underlying probe exit with status 77; `make` reports that as
a failed target. The installed macOS QEMU takes that unavailable path because
it lacks `virtio-gpu-gl-device`; this hardware-dependent gate is intentionally
outside `make test` and its absence must not count as rendered evidence.

`make animation-smoke` captures two paced guest frames and proves that a
retained rounded layer is alpha-composited while presentation remains confined
to its mapped damage rectangle. The live loop currently runs in the single-CPU
EL1 monitor; the same retained-scene and diagnostic-renderer contracts compile
for every display backend.

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
first probes the pinned firmware DTB for the exact UART10, GICv2, PSCI, CPU,
ATF-reservation, removable SDHCI, and RP1 GEM resource contracts. The same probe
requires the timer's non-secure physical PPI and the removable SD controller's
SPI to resolve through their inherited or explicit interrupt parent before it
adds the DTB and official `dwc2.dtbo` from that revision with byte hashes. It also
produces a sparse format-v2 MBR media image with a small invariant FAT12
selector/rescue environment, complete 128 MiB FAT32 A and B payload slots, and
a type-`0xda` data partition with duplicate magic- and CRC-validated
superblocks. Fresh slots have one canonical
`SWIFTOS-AB` FAT32 identity and byte-identical raw contents; logical A/B
identity comes from verified partition geometry and the firmware-reported boot
partition. The data superblocks seed two CRC-protected replicas of the initial
stable-A boot-control record. Set `RPI5_MEDIA_BLOCK_COUNT` to the exact target-
card block count when the data partition should consume the remaining card.
The packaged `config.txt` disables Linux-specific firmware image checking and
implicit Pi SPI EEPROM updates, enables DWC2 peripheral mode for USB-C
debugging, and asks Pi firmware to select an HDMI mode from EDID and retain a
32-bit boot framebuffer. It also pins the expanded DTB to a bounded 48 MiB
window, outside both the reserved restart destination and the high-memory
upload workspace. The kernel discovers and maps
the translated DWC2 and firmware-mailbox resources, powers the USB domain,
initializes DWC2 in bounded polled device mode, and exposes a CDC ACM diagnostic
display stream. It can mirror a firmware framebuffer or use a kernel-owned
800 x 600 surface when HDMI is absent. Build and run the macOS receiver with
`make usb-display-viewer` and `.build/swiftos-usb-display`; see the
[USB display viewer](tools/USBDisplay/README.md).

The Pi scheduler handoff accepts only the exact processor count returned by
`KernelSMP` after every selected secondary has both published online and
completed its bounded work proof. A failed Pi bring-up leaves that result absent;
the later launch path never substitutes the raw Device Tree CPU count.

On Pi 5, the USB-C OTG connector must be reserved for the data connection and
the board powered separately through a supported path. The USB-A connectors
belong to the RP1 host controller and cannot be used as gadget ports. This
physical requirement is checked before treating a missing macOS CDC device as
a driver or kernel failure.

`make swiftosctl` builds the automation-oriented macOS control client. Its
`discover`, `doctor`, and `wait-ready` commands use IOKit to match only
SwiftOS's `1209:5a17` identity and associate the exact CDC tty; `--json` makes
the same state available to scripts and agents without scraping System
Profiler output.

### Raspberry Pi microSD lifecycle

Legacy format-v1 media and new format-v2 media have different safety
contracts:

| Media/operation | Persistence and data effect |
| --- | --- |
| New v2 whole-card initialization | Destructively writes `swiftos-rpi5-media.img`, creating the `SWIFTOS-CTL` selector/rescue, two MBR-positioned `SWIFTOS-AB` slots, and type-`0xda` partition four for the seeded update journal, persistent logs, and SwiftFS. |
| Planned routine v2 release update (not yet supported) | No repository command can initiate this update yet. Its transaction contract must make only the inactive slot non-bootable, write and verify it with FAT32 sectors 6 then 0 committed last, trial it once, and change only the selector's dedicated sector after the candidate proves its identity, digest, token, and health. The confirmed slot, rescue payload, logs, and SwiftFS remain intact; only partition four's reserved boot-control journal bytes change. After a normal boot into the new default, the service converges the peer using the same ordering. |
| Legacy v1 card | Has one `SWIFTOS` FAT32 payload plus type-`0xda` partition two. It remains readable and log-capable but has no A/B rollback. Copying a v2 package into it is not a migration. |
| One-time v1-to-v2 migration | Changes the MBR and boot extents. The default v2 geometry deliberately retains the v1 data extent, but no physical card has been migrated and no supported migration command exists yet. Back up user data before any future migration. |
| Live USB kernel update | Stages and chainloads a verified kernel in RAM. It is volatile; a power cycle returns to the selector's confirmed microSD slot. |

For every card operation, power the Pi off and re-resolve the current removable
whole disk; never reuse an earlier `/dev/diskN` or touch an unrelated disk. On
v2, the selector is immutable during candidate staging and trial; do not edit
its `autoboot.txt` or use a manual file copy as a substitute for the
transaction. Partition one also holds a digest-checked rescue `config.txt`,
`kernel8.img`, and `rescue.dtb`; only the 512-byte `autoboot.txt` data sector is
writable through the strict selector service. The rescue is currently a
capacity-constrained snapshot of the full release kernel and DTB, not a
separately pinned minimal recovery image. The production Pi SD owner now gives
boot-control reconciliation priority before publishing SwiftFS or persistent-log
aliases. It can recover the current boot, cooperatively hash slots, repair an
authorized selector from rescue, enforce a health-gated tryboot watchdog, reset
to the confirmed default, and resume activation-last peer convergence.
Candidate or peer failures that leave the confirmed selector safe may suspend
the transaction for a later boot and then permit confirmed-data aliases; journal
or selector durability ambiguity instead quarantines later SD work before reset.
The port deliberately
refuses new candidate staging: no supported routine v2 updater exists, and the
distinct persistent full-slot capsule plus resumable USB/network ingress have
not been integrated. No trusted capsule signature, signing-key policy, or
authenticated-host policy exists for that future path; SHA-256, CRCs, and
journal identities provide integrity, not authenticity. The volatile `SUPD` RAM
chainloader is not that installer. The physical Pi power-cut, rescue, and A/B
boot paths also remain unverified. This reduces update risk; it is not an
unbrickability claim. Existing returned-card evidence describes legacy v1 media
and does not imply that card was migrated. Raspberry Pi SPI EEPROM updates
remain a separate recovery domain and are disabled and excluded from SwiftOS
slot packages.

See the
[Pi media lifecycle and returned-card diagnostics](docs/raspberry-pi-5.md#physical-media-lifecycle-and-returned-card-diagnostics)
for exact safety checks and the currently supported operations.

The guest-side control foundation is transport-neutral. `SDBG` frames carry a
full 128-bit boot-session identity, 64-bit request identity, bounded payload,
and CRC-32 over USB CDC today and future serial or network adapters. A fixed,
caller-owned kernel log ring and board-neutral status snapshot preserve the
evidence that those transports expose without importing host APIs or allocating
inside the kernel.

The same CDC stream accepts bounded `SUPD` kernel updates. Build the uploader
with `make usb-update`, validate with `--dry-run`, close the display viewer so
only one process owns the tty, then pass the explicit `/dev/cu.usbmodem*` path.
The guest stages at most 16 MiB above 64 MiB, verifies frame CRCs, whole-image
SHA-256 and CRC32, and the Pi Image header before it acknowledges COMMIT. It
then chainloads only when the complete 32 MiB destination was reserved at boot,
the current CPU is Pi CPU0, parked managed secondaries enter PSCI CPU_OFF,
firmware reports every other described CPU OFF, and bounded USB plus interrupt
shutdown succeeds. The shared EL0 scheduler's processor-local timer path also
services this restart request. A busy secondary saves its complete live EL0
frame and relinquishes its queue lease under the scheduler lock, drops the lock,
and only then attempts PSCI CPU_OFF. A successful power-off therefore leaves no
stale running owner. If firmware returns instead, the CPU safely leases a ready
context and rearms its local timer before returning to EL0. See the
[USB kernel updater](tools/USBUpdate/README.md). This is a volatile development
update: a power cycle loads the microSD image again, and integrity hashes do not
authenticate the connected host. COMMITTED confirms sealed staging, not the
subsequent policy handoff; verify the disconnect, re-enumeration, and new boot
identity. The path is host-tested but has not run on a physical Pi, so it is
not a hardware-support claim.

## Honest status

The repository boots a freestanding EL1 Swift kernel, replaces its bootstrap map
with owned final mappings, proves IRQ-driven preemption and isolated EL0 Swift
threads, brings multiple described CPUs online through PSCI, and renders and
presents its diagnostic QEMU desktop through two display backends. It also
contains a production VirGL boot route whose first desktop is built from
retained scene state and full damage, then compiled into one GPU clear, five GPU
quads—including four shader-antialiased rounded layers—and seven GPU-sampled
`SWIFTOS` glyphs. The CPU uploads immutable geometry and R8 coverage data, not
color or scanout pixels. The local QEMU build cannot hardware-exercise that
accelerated route.
The scheduler now runs `processorCount + 1` fixed EL0 threads across the verified
two- and four-CPU QEMU configurations through one IRQ-safe locked global run
queue, with fixed capacity for up to four managed CPUs. Every managed CPU has
its own exception hooks and physical timer, while an exclusive queue lease keeps
one saved context from running on two CPUs at once. `SWIFTOS:EL0_MIGRATION_PROVEN`
is emitted only after all active threads report, timer preemption is established,
and at least one thread reaches the report SVC under leases attributed to more
than one CPU. The preceding secondary-work proof remains distinct: each selected
secondary first runs exactly two affinity-pinned bounded Swift kernel-work slots,
one quantum per processor-local timer IRQ, and CPU0 validates their checksums,
owned stacks, and timer counts before publishing the shared EL0 scheduler. This
is real cross-core userspace scheduling and context migration, but it is not
dynamic thread admission, independent process address spaces or process
migration, general kernel preemption, or load balancing. QEMU
now mounts a concrete crash-consistent
SwiftFS provider at `/Users` over VirtIO block. Its checked EL0 file service
implements `open`, `read`, `write`, `stat`, `readdir`, and `close`; host tests
cover the complete operation surface, while the multi-boot smoke proves live
open/read/write/close and remount durability. This is still a bounded first
service, not an executable loader, general POSIX layer, process-credential
model, stable application ABI, or EL0 file-manager application.
The input core now has a fixed-width ABI, a loss-aware queue, and USB HID boot
keyboard/mouse decoders. In single-CPU monitor mode, modern VirtIO-MMIO keyboard
and mouse devices feed that same queue; a QMP smoke proves A down/up, relative
motion, and left-button transitions after guest DMA decoding. This polling path
does not run in the default SMP/EL0 mode yet and is not Raspberry Pi input.
The board-neutral block, MBR, magic/CRC-validated data-volume, bounded
persistent-log, and SwiftFS formats are host-tested. The Pi target now retains
its removable, DT-discovered BCM2712 SDHCI controller in allocator-owned stable
memory and retains its resolved GIC SPI route rather than assuming a board
interrupt ID,
derives disjoint kernel-log and user-filesystem ranges from the validated `0xda`
layout, and can publish the same SwiftFS provider seam used by QEMU. The log
service and filesystem share one serialized SD owner; raw blocks are never
exposed to EL0. Each initialized retained ring starts with a structured `BOOT`
epoch, and the read-only media inspector distinguishes an unused arena from a
complete console capture. Four physical Pi 5 power-cycle epochs now prove the
PIO SD path, type-`0xda` layout, SwiftFS remount, and gap-free persistent-log
recovery; this remains a bounded bring-up result, not general storage support.
A clean SwiftOS artifact has executed on a Raspberry Pi 5 8 GB through final
paging, GICv2 timer delivery, four-core PSCI work, SD persistence, and the
headless diagnostic renderer. The firmware-patched DT resolved the non-secure
physical timer as GIC PPI 14 (architectural INTID 30) with a four-interface
mask and the removable SDHCI route as SPI `0x111` (architectural INTID
`0x131`). USB reached a DWC2 bus reset and high-speed enumeration-done but
faulted on EP0 before descriptor/configuration completion; RP1 Ethernet stopped
on SYS-clock alias divergence before any clock write or PHY traffic. HDMI,
native GPU, input, and Pi EL0 migration remain unverified. The Pi path currently
consumes a firmware-configured scanout; it does not yet own native HVS/HDMI
modesetting or V3D VII rendering. It can also export that completed diagnostic
surface, or a headless kernel-owned surface, over its USB-C device controller to
the host viewer. USB-C carries a versioned pixel stream here, not DisplayPort,
and the current Pi pixels are still produced by the diagnostic CPU compositor.
The QEMU session builds and uploads a fixed built-in 5 x 7 ASCII mask atlas. Its
new kernel-side file-manager runtime can compile provider-backed rows, window
chrome, selection/hover animation, and the routed pointer into GPU-only command
passes. `KernelMain` now loads the mounted provider, presents the first frame,
drives the opening transition to its terminal frame, and serializes input-driven
redraw in the single-CPU loop. That path is compiled and host/source validated,
but local GL-backed VirGL pixels remain unexercised. There is no dynamic font
loader/shaper/atlas, native Pi GPU font path, EL0 surface protocol, or user
window server. Each milestone must leave behind a repeatable boot or unit test
rather than a mock UI.
