# Hardware roadmap

## Stage 1: deterministic virtual board

QEMU `virt` on AArch64 is the reference board while kernel invariants settle.
The expected devices are PL011 serial, the ARM generic timer, GICv3, virtio-mmio
transports, fw_cfg/ramfb or virtio-gpu, and a flattened device tree. Every driver
is exercised without a host OS inside the guest. The modern VirtIO-MMIO GPU 2D
path now owns a split queue, resource backing, scanout, transfer, and flush; the
next virtual-board device work is input, block storage, entropy, and networking.

## Stage 2: documented physical ARM64 board

A documented board is the first physical target so failures can be separated
between the generic kernel and the board port. Required bring-up evidence is:

- serial boot and panic output;
- timer and interrupt delivery;
- physical allocator and MMU under sustained tests;
- USB keyboard/pointer or board-native input;
- storage with power-loss tests;
- display scanout and compositor;
- network traffic against an external peer.

## Stage 3: Apple Silicon research port

Apple Silicon is not equivalent to generic AArch64. A direct boot needs a legal
firmware handoff and drivers for Apple interrupt controllers, timers, DART/IOMMU,
NVMe, USB, display controllers, and power management. The GPU is a later program
on top of basic display scanout; Apple's Metal framework is not reusable outside
Darwin.

The port therefore starts only after the generic kernel has a board interface,
device tree support, DMA ownership rules, and a framebuffer compositor. Success
means the SwiftOS kernel is executing on the physical CPU and driving devices;
running a window through Metal on macOS does not count.

## Portability contract

Board packages provide described CPU classes/capabilities, physical-memory
domains and proximity, early console discovery, interrupt-controller creation,
timers, DMA constraints, reset/power control, bus enumeration, and display
resources. Generic subsystems consume bounded configurations, classified
allocations, DMA mappings, and resource descriptors rather than board constants.
This keeps the Pi and future Mac ports from forking the kernel.
