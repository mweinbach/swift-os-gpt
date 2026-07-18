# Architecture

## System shape

SwiftOS uses a monolithic kernel initially so early drivers, virtual memory, and
the compositor can evolve behind explicit Swift protocols without paying an IPC
tax before process isolation exists. Once EL0 is stable, filesystems and selected
drivers can move behind service processes without changing user-facing handles.

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

No layer points upward. Machine-specific addresses live in one board package and
are replaced by device-tree discoveries as soon as the parser is online.

## Boot contract

QEMU loads the kernel at the linked physical address and passes the flattened
device-tree address in `x0`. `_start` performs only the work needed before Swift:

1. park non-boot CPUs;
2. transition from EL2 to EL1 when necessary;
3. install the boot stack;
4. clear `.bss`;
5. preserve the device-tree pointer and call `swiftos_main`.

Returning from `swiftos_main` is a kernel fault; the assembly tail parks the CPU.

## Kernel safety model

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

The compositor owns a linear, premultiplied 32-bit surface. Applications submit
surfaces and damage rectangles through kernel handles; they do not receive the
scanout mapping. The first backend is QEMU ramfb or virtio-gpu. A physical board
port implements the same scanout protocol.

The desktop is deliberately terminal-first: tiled/floating windows, workspaces,
keyboard navigation, a shell, and inspectable system state. SwiftUI is not part
of the guest rendering stack.

## User ABI direction

The kernel will expose a small versioned syscall surface: process/thread control,
virtual memory, channels, object handles, clocks, and debug output. Files,
sockets, windows, and devices are capabilities referenced through handles rather
than global integer namespaces. ABI records use fixed-width integers and explicit
layout; Swift implementation types never cross the boundary directly.

