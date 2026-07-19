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
domains: its bounded kernel-log arena remains private, while its user-data arena
may later back a filesystem provider mounted at `/Users`.

Paths are bounded, absolute, case-sensitive UTF-8. Normalization removes
repeated and trailing separators but rejects `.` and `..` instead of resolving
them. Mount selection compares complete path components, so `/Users-old` cannot
be captured by a `/Users` mount.

Filesystem providers publish stable volume/node identifiers, typed metadata,
directory entries with restartable cookies, and bounded byte-range I/O. The VFS
issues generation-tagged handles with attenuated rights. Closing and reusing a
slot changes its generation, making a stale file-manager reference fail instead
of silently naming a different object.

This foundation does not yet implement an on-disk user filesystem, pathname
lookup across a concrete provider, VFS syscalls, permissions tied to process
credentials, or an EL0 file-manager application. Those layers will consume the
contracts here; they will not expose raw blocks to user space.

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
is the future user/kernel ABI boundary. Key mapping, text composition, keyboard
layout, pointer acceleration, focus, gestures, and delivery to windows are
higher-level services and are intentionally absent from transport decoders.

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
