# Architecture

## Target system shape

SwiftOS uses a monolithic kernel initially so early drivers, virtual memory, and
the compositor can evolve behind explicit Swift protocols before process
isolation exists. Once EL0 is stable, filesystems and selected drivers can move
behind service processes without changing user-facing handles. The diagram
below is the intended dependency graph, not a claim that every layer exists now.

The dependency direction is strict:

```text
Swift applications
    -> Swift system library and stable syscall ABI
        -> kernel object/capability handles
            -> VFS, scheduler, networking, compositor
                -> device-independent driver protocols
                    -> AArch64 board drivers
                        -> MMIO and privileged instruction veneers
```

No layer points upward. The target board abstraction will contain every
machine-specific address. Today the early console is fixed at the exact QEMU
`virt` PL011 address and then checked against the device tree; all later device
access uses discovered resources.

## Boot contract

QEMU loads the kernel at the linked physical address and passes the flattened
device-tree address in `x0`. `_start` performs the work that must precede Swift:

1. park non-boot CPUs;
2. transition from EL2 to EL1 when necessary;
3. install the boot stack;
4. clear `.bss`;
5. create the coarse boot identity map and enable the MMU and caches;
6. preserve the device-tree pointer and call `swiftos_main`.

Returning from `swiftos_main` is a kernel fault; the assembly tail parks the CPU.

## Target kernel safety model

These are design rules for subsystems as they are added. Fixed-capacity storage,
MMIO, DMA serialization, and the guest/host source boundary are implemented;
allocators, interrupt dispatch, EL0 copying, and general DMA ownership are not.

- Unsafe pointer operations are concentrated in MMIO, allocators, page tables,
  DMA rings, and ABI boundaries.
- Public driver operations validate sizes and ownership before reaching unsafe
  storage.
- Interrupt handlers do bounded acknowledgement/enqueue work. Scheduling and
  allocation happen outside hard-interrupt context.
- Kernel collections use explicit capacity until the heap is proved operational.
- Device DMA memory is page-aligned, pinned, and owned by one driver at a time.
- User pointers are copied through checked address-space helpers; drivers never
  dereference EL0 addresses directly.

## Graphics model

The current renderer owns a linear XRGB8888 surface and performs full software
rasterization into QEMU ramfb. The desktop panels and terminal are drawn directly;
there is not yet a compositor, window protocol, graphical input path, or EL0
application surface.

The target compositor will own scanout. Applications submit surfaces and damage
rectangles through kernel handles; they do not receive the scanout mapping. A
physical board port implements the same backend contract.

The target desktop will remain terminal-first, then add tiled/floating windows,
workspaces, keyboard navigation, and inspectable system state. The current
surface contains only the EL1 kernel monitor and static status panels. SwiftUI
is not part of the guest rendering stack.

## Planned user ABI

The kernel will expose a small versioned syscall surface: process/thread control,
virtual memory, channels, object handles, clocks, and debug output. Files,
sockets, windows, and devices are capabilities referenced through handles rather
than global integer namespaces. ABI records use fixed-width integers and explicit
layout; Swift implementation types never cross the boundary directly.
