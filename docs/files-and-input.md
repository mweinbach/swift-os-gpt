# Files and input foundation

SwiftOS keeps file policy and input policy above physical transports. An SD
card, a VirtIO block device, a RAM-backed provider, and a future network volume
must all enter the same namespace contracts. Likewise, VirtIO input, USB HID,
and future board-native controllers must all produce the same checked event
records before focus, text, pointer, or window policy sees them.

## Namespace and storage roles

The first namespace is deliberately small and role-based:

- `/System` contains boot-critical OS and shared software content. It is
  read-only through ordinary VFS operations; an authenticated updater must use
  a separate update path.
- `/Users` contains durable user-created files and application state. This is
  the only default persistent namespace eligible for ordinary create, write,
  and remove authority when a provider implements those operations.
- `/Temporary` contains mutable scratch data with no persistence promise.
- `/Devices` contains capability-checked, kernel-mediated device objects. It is
  not a raw block-device namespace.
- `/Volumes/<name>` contains explicitly mounted additional namespace volumes.
  The root and `/Volumes` themselves are synthetic VFS directories.

Kernel log arenas, journals, swap, update staging, and raw media descriptors are
kernel-only volumes. They cannot be mounted into the user namespace. The
existing signed Pi data partition therefore keeps two distinct ownership
domains: its bounded kernel-log arena remains private, while a disjoint user-
data arena backs SwiftFS. QEMU applies the same separation to its VirtIO block-
backed data volume. Neither path exposes raw blocks through the namespace.

Paths are bounded, absolute, case-sensitive UTF-8. Normalization removes
repeated and trailing separators but rejects `.` and `..` instead of resolving
them. Mount selection compares complete path components, so `/Users-old` cannot
be captured by a `/Users` mount.

Filesystem providers publish stable volume/node identifiers, typed metadata,
directory entries with restartable cookies, and bounded byte-range I/O. The VFS
issues generation-tagged handles with attenuated rights. Closing and reusing a
slot changes its generation, making a stale file-manager reference fail instead
of silently naming a different object.

## SwiftFS and the first EL0 file service

SwiftFS is the first concrete persistent `/Users` provider. It is an original,
allocation-free format over any synchronous SwiftOS block device. Each mutation
writes a complete copy-on-write snapshot to the inactive metadata/data bank,
synchronizes it, and only then publishes the next CRC-protected superblock.
Mount chooses the newest structurally valid snapshot and can fall back to the
older committed bank after a torn publication. CRC-32 provides accidental-
corruption and torn-write detection, not authentication or hostile-media
protection. The initial volume has a fixed 32-node capacity.

On QEMU, the native modern VirtIO-MMIO block driver opens or initializes a
signed data volume, reserves its kernel-log prefix, opens or formats SwiftFS in
the remaining user range, and retains both transport and mounted provider in
stable allocator-owned records. The provider is mounted at `/Users` behind a
borrowed-provider backend; filesystem code contains no VirtIO addresses.

The versioned EL0 file request/result ABI supports `open`, partial `read` and
`write`, `stat`, restartable `readdir`, and `close`. The service validates whole
user ranges before copying, uses a bounded per-process generation-tagged handle
table, and rechecks mount, node, and requested-access policy. Host tests cross
all six operations. The QEMU multi-boot smoke separately proves blank format
and seed, a second-boot remount, live EL0 open/read/write/close while the
scheduler continues preempting two threads, and a final remount that observes
the EL0-written contents.

The Raspberry Pi storage runtime reaches the same SwiftFS format and mounted-
provider seam through a partition-bounded view of the removable SD device. Its
allocator-owned SD record, filesystem scratch, and provider record remain
stable for every borrowed view. A host-tested policy derives disjoint absolute
kernel-log and SwiftFS ranges. Its resumable bootstrap performs at most one
block read, write, synchronize, or CPU-only validation phase per cooperative
pass, and never shares that pass with log recovery/appends. No Pi SD transfer,
SwiftFS mount, or recovery has been observed on physical hardware.

The remaining limitations are meaningful: there is no executable loader,
pathname-creating EL0 API, general process-credential model, POSIX compatibility
layer, dynamic mount service, or EL0 file-manager application. SwiftFS currently
commits whole bounded snapshots and is a correctness-first filesystem rather
than a scalable general disk format.

## Input records and devices

The input core uses one fixed-width event vocabulary for keyboard usages,
modifier changes, relative pointer motion, pointer buttons, and scrolling.
Transport drivers attach stable device identifiers and timestamps, then enqueue
events in a fixed-capacity FIFO. The queue assigns monotonic sequence numbers
and counts dropped events so user-space input dispatch can detect loss and
resynchronize device state.

USB boot-protocol keyboard and mouse decoders are allocation-free state
machines. A keyboard report is accepted only after its reserved byte, usage
set, rollover state, and duplicate keys have all been validated. Malformed
reports emit no events and do not replace the last known-good state. Mouse
reports preserve signed relative motion, button transitions, and an optional
wheel byte.

The explicit little-endian event codec, rather than Swift's in-memory layout,
is the future user/kernel ABI boundary. Transport decoders intentionally omit
UI policy. Above them, a synchronous canonical-event dispatcher and backend-
neutral accelerated file-manager state now provide US keyboard composition,
type-ahead, selection/navigation, pointer scaling, hit testing, capture, focus,
scrolling, cursor shape, and paced hover/selection animation. These are bounded
kernel bootstrap primitives, not a general input server or EL0 window protocol.

## Driver crossings

On QEMU `virt`, `virtio-keyboard-device`, `virtio-mouse-device`, and
`virtio-tablet-device` are modern VirtIO-MMIO device ID 18. SwiftOS now shares
one split-ring geometry between network and input, then applies input-specific
ownership: eventq 0 receives 64 pre-posted, independent, device-writable
eight-byte event records; statusq 1 remains unconfigured until LED feedback has
an owner. Configuration reads are generation-stable, descriptor IDs cannot be
completed twice before recycling, and unknown event types are ignored without
leaking evdev codes into the canonical ABI.

The first runtime is intentionally polling and single-CPU. A QMP smoke injects
A down/up, relative `+37/-19` motion, and left-button down/up. Its proof marker
is emitted only after the guest consumes DMA, translates the records, writes
the canonical queue ABI, and dequeues those events. Default SMP boots do not
poll input yet; they need a kernel service thread or registered VirtIO IRQ path.
The accelerated file-manager runtime installs a synchronous handler and is
designed so one owner drains input before mutating the same UI state for a GPU
frame. Its routing and GPU-only source boundaries are host-tested, while the
combined accelerated boot loop is still being integrated. The existing QMP
smoke remains transport evidence, not proof of rendered interaction.

On Raspberry Pi 5, the same event service will sit above a USB host-controller
and HID transport. The current DWC2 implementation is a USB-C device-mode debug
gadget, not a USB host stack, so it cannot enumerate a keyboard or mouse. No Pi
input hardware support should be claimed until host-controller ownership, HID
enumeration, report delivery, and physical-device evidence all exist.

The transport contract follows [OASIS VirtIO 1.2 input device section
5.8](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html). The smoke
uses QEMU's documented
[`input-send-event`](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html)
command; host injection is only the stimulus, while guest queue markers are the
acceptance evidence.
