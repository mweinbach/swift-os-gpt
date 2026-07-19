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

1. full EL1 exception frames, device-tree-selected GICv3 delivery, and repeating
   architectural timer interrupts;
2. range-based RAM ownership with firmware/kernel/DTB/table reservations, a
   live fixed-capacity classified allocator for distinct memory domains,
   final permissioned page tables, and unmapped stack guards;
3. bounded processor descriptions and startup configurations, with four
   Cortex-A72 QEMU CPUs or two Cortex-A76 CPUs entering the same Swift path;
4. a separately linked Embedded Swift EL0 image, two isolated user stacks, a
   narrow SVC report ABI, and two CPU0-pinned threads preempted by timer IRQs;
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
   discovery and mapping.

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

This is not yet a general-purpose OS. The next layers include sustained
GPU-frame scheduling and richer GPU primitives, accelerated QEMU execution
evidence, a native Pi V3D/HVS/HDMI path, multicore task scheduling, an
executable loader, VFS/storage, input drivers, a user-facing surface/window
protocol, networking, and a stable system library and syscall ABI.

See [Architecture](docs/architecture.md), [Renderer foundation](docs/renderer.md),
and [Hardware roadmap](docs/hardware-roadmap.md) for the contracts behind those
milestones. [Current status](docs/current-status.md) separates working guest code
from the next kernel frontiers.

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
make smp-el0-smoke
make cpu-config-smoke
make test
```

`make run` boots four CPUs by default and follows the verified SMP/EL0 path after
publishing the QEMU ramfb display. Use `QEMU_CPUS=1 make run` for the interactive
EL1 kernel monitor; type monitor commands in the terminal that launched QEMU,
and PL011 input updates both serial output and the guest terminal window.
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
ATF-reservation, removable SDHCI, and RP1 GEM resource contracts, then adds it
and the official `dwc2.dtbo` from that same revision with byte hashes. It also
produces a sparse MBR media image with
a populated FAT32 boot partition and a signed type-0xda data partition. Set
`RPI5_MEDIA_BLOCK_COUNT` to the exact target-card block count when the data
partition should consume the remaining card. The packaged `config.txt` enables DWC2
peripheral mode for USB-C debugging and asks Pi firmware to select an HDMI mode
from EDID and retain a 32-bit boot framebuffer. It also pins the expanded DTB
to a bounded 48 MiB window, outside both the reserved restart destination and
the high-memory upload workspace. The kernel discovers and maps
the translated DWC2 and firmware-mailbox resources, powers the USB domain,
initializes DWC2 in bounded polled device mode, and exposes a CDC ACM diagnostic
display stream. It can mirror a firmware framebuffer or use a kernel-owned
800 x 600 surface when HDMI is absent. Build and run the macOS receiver with
`make usb-display-viewer` and `.build/swiftos-usb-display`; see the
[USB display viewer](tools/USBDisplay/README.md).

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
shutdown succeeds. Future busy secondary workloads must service the same
restart checkpoint from a bounded scheduler or interrupt path. See the
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
The scheduler currently runs both user threads only on CPU0; secondary CPUs
publish online state and park. There is no loader, VFS, mounted user filesystem,
graphical input, user compositor/window protocol, or stable application ABI.
The board-neutral block, MBR, signed data-volume, and bounded persistent-log
formats are host-tested. The Pi target now binds them to the removable,
DT-discovered BCM2712 SDHCI controller and incrementally drains the retained
kernel log into the signed `0xda` partition. That binding and its PIO transport
remain physical-hardware-unverified, and QEMU has no VirtIO block binding yet.
The remainder of the data partition is reserved for a user filesystem, but no
VFS or filesystem exists and raw data blocks are never exposed to EL0.
Physical Raspberry Pi 5 execution remains unverified. The Pi path currently
consumes a firmware-configured scanout; it does not yet own native HVS/HDMI
modesetting or V3D VII rendering. It can also export that completed diagnostic
surface, or a headless kernel-owned surface, over its USB-C device controller to
the host viewer. USB-C carries a versioned pixel stream here, not DisplayPort,
and the current Pi pixels are still produced by the diagnostic CPU compositor.
The QEMU session builds and uploads a fixed built-in 5 x 7 ASCII mask atlas for
its `SWIFTOS` boot label, but there is no PSF2 asset loader, shaping/layout
stack, dynamic atlas, or Pi GPU font path. The retained scene and diagnostic
compositor remain kernel-side bootstrap infrastructure, not an EL0 window
system. Each milestone must leave behind a repeatable boot or unit test rather
than a mock UI.
