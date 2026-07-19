# Hardware roadmap

## Stage 1: deterministic virtual board

QEMU `virt` on AArch64 is the reference board while kernel invariants settle.
The expected devices are PL011 serial, the ARM generic timer, GICv3, virtio-mmio
transports, fw_cfg/ramfb or virtio-gpu, and a flattened device tree. Every driver
is exercised without a host OS inside the guest. The modern VirtIO-MMIO GPU 2D
path now owns a split queue, resource backing, scanout, transfer, and flush, but
still presents CPU-rasterized diagnostic pixels. Separately, the production
boot branch now creates a fenced VirGL context, a format-100 sRGB GPU-only
target, unit-quad geometry, a 112 x 54 format-64 R8 glyph-mask atlas uploaded in
two 112 x 27 strips, and solid, analytic-rounded, and mask-glyph pipeline state.
It builds the first 800 x 600 desktop through the shared retained-scene compiler
into one GPU clear and five quads, including four analytic antialiased rounded
layers, then overlays seven GPU-sampled `SWIFTOS` glyphs and scans out the full
damage result after 18 fenced transactions. The CPU prepares immutable geometry
and coverage assets but no color or scanout pixels. The session is retained for
reusable render-IR submission and damage flush. The installed local QEMU cannot
instantiate a GL-backed VirGL device, so this crossing has source, protocol, and
host-test coverage rather than local hardware exercise. The next graphics gate
is captured accelerated evidence on a capable QEMU build, followed by
sustained frame scheduling, richer lowering, and vblank-capable presentation.
Input, block storage, entropy, and networking remain parallel device work.

## Stage 2: documented physical ARM64 board

A documented board is the first physical target so failures can be separated
between the generic kernel and the board port. Required bring-up evidence is:

- serial boot and panic output;
- timer and interrupt delivery;
- physical allocator and MMU under sustained tests;
- USB keyboard/pointer or board-native input;
- storage with power-loss tests;
- native GPU rendering, synchronized display scanout, and compositor;
- network traffic against an external peer.

Raspberry Pi 5 is the active Stage 2 target. Its first display driver consumes
the firmware-created `simple-framebuffer` through the generic boot-resource,
scanout, and software-managed DMA contracts as a diagnostic bring-up path. That
path is host/static tested but has not yet produced a frame on physical
hardware. Production pixels require native V3D VII rendering plus HVS/IOMMU,
vblank, HDMI modesetting, hotplug/DDC/EDID, clocks, and PHY drivers. The QEMU
backend and planned Pi backend share retained scene, command, memory-domain,
fence, and presentation contracts without sharing device code.

## Stage 3: Apple Silicon research port

Apple Silicon is not equivalent to generic AArch64. A direct boot needs a legal
firmware handoff and drivers for Apple interrupt controllers, timers, DART/IOMMU,
NVMe, USB, display controllers, and power management. A production graphics port
also needs a native GPU backend because CPU rasterization is diagnostic-only;
Apple's Metal framework is not reusable outside Darwin.

The port therefore starts only after the generic kernel has a board interface,
device tree support, DMA ownership rules, and stable GPU command/presentation
contracts. Success means the SwiftOS kernel is executing on the physical CPU and
driving devices; running a window through Metal on macOS does not count.

## Portability contract

Board packages provide described CPU classes/capabilities, physical-memory
domains and proximity, early console discovery, interrupt-controller creation,
timers, DMA constraints, reset/power control, bus enumeration, and display
resources. Generic subsystems consume bounded configurations, classified
allocations, DMA mappings, and resource descriptors rather than board constants.
Driver discovery reserves memory and MMIO before the allocator and final page
tables activate; each backend then implements the same presentation contract.
Graphics backends additionally implement the same render-command, image-domain,
queue, and fence contracts. Scene construction never depends on VirtIO, V3D, or
a particular CPU/memory topology. This keeps the Pi, QEMU, and future Mac ports
from forking the kernel.
