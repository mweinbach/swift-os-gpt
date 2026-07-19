# Renderer foundation

SwiftOS rendering is guest-owned Swift code. It does not call SwiftUI, Metal,
CoreGraphics, a host window server, or a Linux graphics stack. The production
QEMU driver lowers the shared retained scene and backend-neutral GPU command
contract to VirGL. A future native Raspberry Pi driver must lower that same
contract to V3D/HVS without changing UI policy.

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

## Production QEMU GPU path

The QEMU boot artifact attempts a production VirtIO/VirGL session before any
diagnostic framebuffer setup. On a compatible VirGL2 device, the guest:

1. reads the active display mode and validates the renderer capset;
2. creates a host-private format-100 `B8G8R8A8_SRGB` target with render-target
   and scanout bindings, preserving alpha and applying the sRGB transfer on the
   GPU;
3. creates and attaches a GPU vertex buffer, then uploads six unit-quad
   `R32G32_FLOAT` vertices without creating any pixel backing store;
4. creates the color surface, framebuffer, shaders, vertex elements,
   rasterizer, depth/stencil/alpha state, and copy/source-over blend state;
5. builds the first desktop as five retained logical layers, then uses
   `GPURetainedSceneCompiler` to lower full logical damage into one attachment
   clear and five source-over solid quads; and
6. sets scanout and flushes the compiler-provided presentation damage only
   after all dependent queue work completes.

`DisplayViewport` centers and integer-scales the 800 x 600 logical scene. The
full-damage clear includes letterboxes, so the first presentation damage is the
complete scanout.

The validated lifecycle uses 13 fenced control-queue transactions: display
query; two capset metadata queries; selected-capset payload; context creation;
create/attach for both the color target and unit quad; quad upload; render
submission; scanout selection; and flush. The context, target, geometry, and
initialized IR compiler remain owned by `VirtIOGPU3DSession`. Its reusable
`render` entry point lowers another immutable command buffer, submits it to the
same GPU target, and issues a fenced flush for the caller's checked damage
rectangle. Neither bootstrap nor reusable submission maps or uploads CPU-made
pixels.

If no accelerated device is available, boot emits
`SWIFTOS:GRAPHICS_DIAGNOSTIC` before entering the software route. Once an
accelerated device starts a session, any failure is fatal and cannot fall back
to CPU rendering; a source gate rejects CPU framebuffer dependencies in that
crossing. The installed local QEMU build does not provide a GL-backed VirGL
device, so this accelerated pixel path is source-, protocol-, and host-tested
but has not produced locally hardware-exercised pixels or a captured
accelerated frame.

## Explicit diagnostic frame path

QEMU ramfb, QEMU VirtIO-GPU 2D, and the statically inspected Pi simplefb path
select the CPU renderer only as diagnostics:

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
behavior testable alongside the production GPU executor.

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

The QEMU backend negotiates optional VirtIO 3D features, reads stable device
configuration, enumerates and validates bounded VirGL capability sets, encodes
context/resource/transfer/submit control messages, and emits VirGL surface,
framebuffer, clear, fixed-state, shader, draw, and GPU-to-GPU copy commands. The
boot path now creates that context and submits a GPU-rasterized retained desktop
compiled through `GPUDesktopScene` and `GPURetainedSceneCompiler`, while a
reusable session API accepts later GPU-only IR frames with bounded damage.

The planned Pi backend will use the same generic commands and scheduling
contracts. Device tree discovery identifies the enabled V3D VII hub/core/SMS
regions, HVS scanout registers, and the requirement for graphics address
translation; boot-resource planning maps those MMIO regions as Device memory.
Discovery and mapping do not constitute V3D command submission or HDMI output.

The production frame path will keep three offscreen GPU render targets and a
separate persistent scanout image. After a frame fence completes, the GPU copies
only the damaged region into scanout before presentation. This avoids reusing a
render target while the display engine may still read the visible front image.
QEMU and Pi will implement that model with different queue and display drivers,
not different UI semantics.

## Verified proof and validation boundary

`make animation-smoke` boots one QEMU CPU, captures a low-opacity diagnostic
frame, waits for the retained indicator to reach its peak, captures a second
frame, and requires every changed pixel to remain inside the layer's 12 x 12
damage bounds. Host tests separately cover timeline wraparound, frame pacing,
mutation order, damage overflow, clipping, alpha, rounded coverage, and
compositor repaint.

The accelerated session and IR lowering have deterministic host tests for exact
packet order, fence progression, format/capability rejection, unit-quad upload,
pipeline state, retained boot-scene construction, 1080p and 4K integer viewport
scaling, full-clear presentation damage, initial quad draws, reusable
submission, and damage flush. The GPU-only source audit separately requires the
retained scene crossing and prevents software rasterizer or framebuffer types
from entering accelerated activation and execution.

The live animation loop currently belongs to the single-CPU EL1 diagnostic
monitor. The Pi image and diagnostic multicore QEMU path rasterize the same
retained component's initial state through software before entering the EL0
scheduler. The installed QEMU cannot run the VirGL GL route, and the Pi image
has not run on physical hardware, so neither accelerated QEMU pixels nor
physical Pi output are hardware-verified.

## Next renderer increments

- Exercise the checked-in session on a GL-backed VirGL QEMU configuration and
  retain accelerated serial, fence, and captured-frame evidence.
- Route ongoing retained-scene updates through the reusable GPU submission API,
  then execute the frame scheduler and graphics mailbox in the live boot path.
- Lower rounded-corner and glyph-atlas commands to VirGL; solid quads, affine
  transforms, clear/load/store, clipping, and copy/source-over blending already
  have bounded lowering.
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

This is the base of a modern UI renderer, not yet a window server. The QEMU
accelerated branch currently produces a static retained-scene bootstrap frame
(one attachment clear plus five quads);
there are no EL0 surfaces, textures, paths, rounded GPU coverage, live font
atlas, input routing, or sustained compositor loop yet, and the checked-in GPU
frame has not been exercised by the installed local QEMU.
