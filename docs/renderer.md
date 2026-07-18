# Renderer foundation

SwiftOS rendering is guest-owned Swift code. It does not call SwiftUI, Metal,
CoreGraphics, a host window server, or a Linux graphics stack. The same retained
model and raster policy sit above QEMU and Raspberry Pi display drivers.

## Current frame path

One animated frame follows this pipeline:

1. `AnimationTimeline` samples the architectural counter into normalized Q16
   progress and applies a deterministic curve.
2. `FramePacer` decides whether a 30 Hz frame boundary was crossed and accounts
   for late frames without shifting the cadence.
3. A `RetainedLayer` value is replaced in `RetainedLayerTree`; the mutation
   reports both old and new visible bounds.
4. `DamageRegion` clips and coalesces those bounds in the logical desktop.
5. `SoftwareLayerCompositor` clears only damaged pixels and repaints intersecting
   layers in stable back-to-front order.
6. `LinearFramebuffer` performs integer source-over blending and four-sample
   antialiasing for rounded corners.
7. `ScaledFramebufferCanvas` maps logical pixels and damage into the active
   physical mode.
8. `ActiveDisplayBackend` presents that physical damage through ramfb,
   VirtIO-GPU 2D, or the Pi firmware framebuffer.

All frame-state structures use inline bounded storage and no allocator. The
bootstrap tree currently supports eight solid-color layers. This deliberately
small contract makes clipping, ordering, overflow, and presentation behavior
testable before application surfaces or a heap-backed scene graph exist.

## What is shared and what is a driver

The retained tree, animation math, damage policy, compositor, software
rasterizer, logical viewport, and terminal are platform-independent. A display
driver supplies only a validated mode, memory mapping, coherency rules, and a
damage-present operation.

QEMU ramfb continuously scans the Swift-owned surface. The VirtIO-GPU driver
transfers and flushes damaged backing storage through its control queue. The Pi
driver cleans damaged cache ranges before firmware scanout reads them. Future
native Pi HVS/HDMI modesetting and GPU command submission remain separate
drivers; they must not fork the retained UI model.

## Verified proof

`make animation-smoke` boots one QEMU CPU, captures a low-opacity frame, waits
for the retained indicator to reach its peak, captures a second frame, and
requires every changed pixel to remain inside the layer's 12 x 12 damage bounds.
Host tests separately cover timeline wraparound, frame pacing, mutation order,
damage overflow, clipping, alpha, rounded coverage, and compositor repaint.

The live animation loop currently belongs to the single-CPU EL1 monitor. The Pi
image and multicore QEMU path render the same retained component's initial state,
but they enter the EL0 scheduler instead of running the monitor loop. Physical
Pi output remains unverified.

## Next renderer increments

- Add retained image, glyph-run, border, gradient, shadow, and transform content
  while preserving old/new damage reporting.
- Package a PSF2 asset, then separate font parsing, glyph caching, layout, and
  eventual shaping behind a bounded font-face contract.
- Define kernel-owned surfaces and immutable frame submissions for EL0 clients;
  applications must never map scanout directly.
- Move frame scheduling to a compositor thread driven by a display/vblank event,
  with counter pacing retained as a tested fallback.
- Introduce a backend-neutral render-command stream so software rasterization,
  VirtIO 3D, and a future Pi GPU driver execute the same scene semantics.
- Add input hit testing, focus, window lifetime, and surface synchronization only
  after object handles and checked user-copy exist.

This is the base of a modern UI renderer, not yet a window server: there are no
EL0 surfaces, transforms, textures, paths, font atlas, input routing, or GPU
shaders in the current boot artifact.
