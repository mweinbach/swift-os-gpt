# SwiftOS USB Display Viewer

`swiftos-usb-display` is the macOS receiver for SwiftOS's diagnostic display
stream. The Pi enumerates as a CDC ACM device, and the guest sends the versioned
display protocol over CDC data endpoint 2. The viewer opens the resulting
`/dev/cu.usbmodem*` tty; USB-C is the data transport, not a DisplayPort signal.

The viewer is a host tool. AppKit, Foundation, Dispatch, and Darwin are confined
to this directory and never link into the freestanding kernel or userland.

## Build and run

```sh
make usb-display-viewer
.build/swiftos-usb-display --list
.build/swiftos-usb-display
```

With no arguments, the app waits for the first `/dev/cu.usbmodem*`, reconnects
after USB re-enumeration, and opens a scalable AppKit window. To bind it to one
specific device path:

```sh
.build/swiftos-usb-display --device /dev/cu.usbmodemSWIFTOS1
```

Each open configures the tty raw/nonblocking and explicitly pulses DTR low then
high (using Darwin's direct DTR ioctl with its modem-bit fallback). The rising
edge lets the guest restart hello, mode, and full-frame transmission after a
viewer restart instead of depending on bytes buffered before the tty was open.

Run the device-independent receiver/assembler verification with:

```sh
make usb-display-viewer-host-test
```

The test deliberately fragments packets, inserts framing garbage, validates a
semantic reset, assembles a full frame, applies tightly packed damage rows into
a padded scanout stride, and checks the host allocation limit. It needs neither
a Pi nor a window server.

## Presentation behavior

- Resolution and row stride come directly from the validated display-mode
  packet.
- The guest scale numerator/denominator determines the initial logical window
  size. Resizing always preserves the guest aspect ratio.
- PPI and refresh metadata are shown in the window title when supplied.
- Completed frames are coalesced to the advertised refresh cadence; an unknown
  refresh rate presents each completed frame immediately.
- Both supported little-endian `B8G8R8X8` and `B8G8R8A8` modes map directly to a
  Core Graphics image without changing guest pixels.

This is an observation path for completed guest frames; it does not choose or
replace the guest renderer. The current Pi simplefb and headless surfaces are
explicit diagnostic CPU-rendered modes. A future V3D backend can export its
completed CPU-visible presentation surface through the same protocol without
changing the viewer.

## Pi 5 connection check

1. Boot a SwiftOS Pi image packaged with the DWC2 peripheral overlay and USB
   debug gadget enabled.
2. Leave the Pi 5 USB-C connector dedicated to OTG data. Raspberry Pi's Pi 5
   OTG procedure powers the board separately through its 5 V and GND header;
   PoE is another way to free the USB-C connector. Follow the power source's
   safety instructions and never connect competing supplies. A cable from a
   Mac or hub that is also powering the board is not the supported Pi 5 OTG
   arrangement, and the USB-A ports are host-only rather than gadget ports.
3. Confirm macOS enumeration with `--list`. The viewer can be launched before
   the Pi and will wait through re-enumeration.
4. Keep UART10 available during first hardware bring-up. USB cannot report
   failures that occur before the controller attaches. A tty entry proves USB
   enumeration, while the first displayed frame also proves CDC data, wire
   framing, semantic negotiation, and framebuffer export.

The expected UART sequence starts with `SWIFTOS:USB_POWER_READY`,
`SWIFTOS:USB_POWER_UNMANAGED`, or `SWIFTOS:USB_POWER_UNMANAGED_OFF`, followed
by `SWIFTOS:USB_DEBUG_ATTACHED`, `SWIFTOS:USB_DEBUG_CONFIGURED`, then
`SWIFTOS:USB_DEBUG_FRAME`. Configuration follows host enumeration; the frame
marker requires the macOS viewer to open the tty and assert DTR.
`SWIFTOS:GRAPHICS_DIAGNOSTIC` identifies the current Pi renderer honestly; it is
not a native V3D/HVS/HDMI acceleration marker.

The viewer and guest path are covered by host tests and build inspection. They
must not be described as Pi-hardware-verified until this checklist succeeds on
the physical board.

## Recovery and bounds

The stream queue is bounded to 64 maximum-sized packets and performs magic/CRC
resynchronization without retaining arbitrary input. Frame allocation is capped
at 512 MiB (enough for an 8K 32-bit scanout). The existing strict
`USBDebugDisplayReceiver` validates session, sequence, capability, mode, frame,
chunk, and checksum semantics before the assembler commits pixels. Semantic
faults remain sticky until a protocol reset or USB reconnect.
