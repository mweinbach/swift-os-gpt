# Renderer foundation

SwiftOS rendering is guest-owned Swift code. It does not call SwiftUI, Metal,
CoreGraphics, a host window server, or a Linux graphics stack. QEMU and
Raspberry Pi drivers lower the same retained scene and backend-neutral GPU
command contract into their own hardware protocols.

## Production invariant

Production graphics are GPU-only. A CPU may update retained scene state, sample
animations, compute and coalesce damage, compile immutable render commands, and
submit queue work. It must not clear, shade, blend, composite, scale, draw text,
or otherwise manufacture pixels that reach a production scanout. Those jobs
belong to a hardware GPU backend.

The software rasterizer and compositor remain in the tree as an explicitly
selected diagnostic path and a deterministic reference oracle for geometry,
clipping, blending, and damage tests. A production boot must reject a graphics
configuration without a hardware rasterizer rather than silently falling back
to CPU pixels. Presentation is a separate responsibility: a GPU may render into
offscreen images while VirtIO scanout or a native HVS/HDMI driver displays the
completed result.

## Current diagnostic frame path

The live QEMU boot artifact has not yet been wired to the GPU execution path,
and the statically inspected Pi display path is the same in this respect. Both
still select the diagnostic CPU renderer:

One animated frame follows this pipeline:

1. `AnimationTimeline` samples the architectural counter into normalized Q16
   progress and applies a deterministic curve.
2. `FramePacer` decides whether a 30 Hz frame boundary was crossed and accounts
   for late frames without shifting the cadence.
3. A `RetainedLayer` value is replaced in `RetainedLayerTree`; the mutation
   reports both old and new visible bounds.
4. `DamageRegion` clips and coalesces those bounds in the logical desktop.
5. the explicitly diagnostic `SoftwareLayerCompositor` clears only damaged
   pixels and repaints intersecting layers in stable back-to-front order.
6. `LinearFramebuffer` performs integer source-over blending and four-sample
   antialiasing for rounded corners.
7. `ScaledFramebufferCanvas` maps logical pixels and damage into the active
   physical mode.
8. `ActiveDisplayBackend` presents that physical damage through ramfb,
   VirtIO-GPU 2D, or the Pi firmware framebuffer.

All frame-state structures use inline bounded storage and no allocator. The
bootstrap tree currently supports eight solid-color layers. This deliberately
small diagnostic contract keeps clipping, ordering, overflow, and presentation
behavior testable while the production GPU executor is brought online.

`make virtio-gpu-smoke` proves a native guest VirtIO-MMIO 2D resource, transfer,
flush, and scanout path. It does not prove GPU rasterization: the source pixels
for that smoke are still produced by the CPU. Pi simplefb is likewise an early
diagnostic scanout handoff, not a production renderer.

## GPU-first shared path

The platform-independent path now includes:

- retained layers, fixed-point animation, and bounded logical damage;
- backend-neutral render-pass, quad, rounded-corner, blend, and glyph-atlas
  command records;
- an allocation-free retained-scene compiler and sealed command storage;
- distinct rasterizer, presenter, image-domain, queue, and fence capabilities;
- a triple-buffer frame scheduler that prevents reuse before GPU completion;
  and
- an allocation-free scene mailbox for publishing work to a dedicated graphics
  CPU without sharing mutable scene storage.

The QEMU backend foundations negotiate optional VirtIO 3D features, read stable
device configuration, enumerate and validate bounded VirGL capability sets,
encode context/resource/transfer/submit control messages, and encode VirGL
surface, framebuffer, clear, fixed-state, shader, draw, and GPU-to-GPU copy
commands. These components are host-tested, but there is not yet a live context
session submitting them during boot.

The Pi backend uses the same generic commands and scheduling contracts. Device
tree discovery identifies the enabled V3D VII hub/core/SMS regions, HVS scanout
registers, and the requirement for graphics address translation; boot-resource
planning maps those MMIO regions as Device memory. Discovery and mapping do not
constitute V3D command submission or HDMI output.

The production frame path will keep three offscreen GPU render targets and a
separate persistent scanout image. After a frame fence completes, the GPU copies
only the damaged region into scanout before presentation. This avoids reusing a
render target while the display engine may still read the visible front image.
QEMU and Pi implement that model with different queue and display drivers, not
different UI semantics.

## Verified proof

`make animation-smoke` boots one QEMU CPU, captures a low-opacity diagnostic
frame, waits for the retained indicator to reach its peak, captures a second
frame, and requires every changed pixel to remain inside the layer's 12 x 12
damage bounds. Host tests separately cover timeline wraparound, frame pacing,
mutation order, damage overflow, clipping, alpha, rounded coverage, and
compositor repaint.

The live animation loop currently belongs to the single-CPU EL1 monitor. The Pi
image and multicore QEMU path rasterize the same retained component's initial
state through the diagnostic path, but they enter the EL0 scheduler instead of
running the monitor loop. Physical Pi output and accelerated QEMU rendering
remain unverified.

## Next renderer increments

- Wire the bounded VirtIO/VirGL context session through capability selection,
  resource creation, a fenced GPU-generated clear, scanout, and flush; publish
  accelerated evidence only after pixels are generated by that queue.
- Lower the shared quad, rounded-corner, blend, and glyph-atlas commands to the
  VirtIO/VirGL backend, then execute the frame scheduler and graphics mailbox in
  the live boot path.
- Add retained image, glyph-run, border, gradient, shadow, and transform content
  while preserving old/new damage reporting and GPU-only pixel production.
- Package a PSF2 asset, then separate parsing, layout, shaping, atlas allocation,
  and GPU glyph sampling behind a bounded font-face contract.
- Define kernel-owned surfaces and immutable frame submissions for EL0 clients;
  applications must never map scanout directly.
- Move frame scheduling to a compositor thread driven by a display/vblank event,
  with counter pacing retained as a tested fallback.
- Implement native Pi V3D VII command submission, graphics address translation,
  HVS display lists, vblank, HDMI hotplug/DDC/EDID, clocking, and PHY control
  behind the same contracts.
- Add input hit testing, focus, window lifetime, and surface synchronization only
  after object handles and checked user-copy exist.

This is the base of a modern UI renderer, not yet a window server: there are no
EL0 surfaces, transforms, textures, paths, live font atlas, input routing, or
GPU-rendered frames in the current boot artifact.
