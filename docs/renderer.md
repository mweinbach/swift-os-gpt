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

1. reads the active display mode and validates the renderer capset, including
   format-100 render-target/scanout support and format-64 `R8_UNORM` sampler
   support;
2. creates a host-private format-100 `B8G8R8A8_SRGB` target with render-target
   and scanout bindings, preserving alpha and applying the sRGB transfer on the
   GPU;
3. creates and attaches a GPU vertex buffer, then uploads six unit-quad
   `R32G32_FLOAT` vertices without creating any pixel backing store;
4. creates and attaches an immutable 112 x 54 `R8_UNORM` glyph-mask atlas and
   uploads its coverage in two bounded 112 x 27 strips;
5. creates the color surface and framebuffer; solid, analytic-rounded, and
   mask-glyph shader pairs; a sampler view and nearest/linear sampler states;
   vertex elements; rasterizer; depth/stencil/alpha state; and copy/source-over
   blend state;
6. builds the first desktop as five retained logical layers, then uses
   `GPURetainedSceneCompiler` to lower full logical damage into one attachment
   clear, one solid top bar, and four source-over analytic rounded quads; loads
   that attachment in a second pass and draws the seven glyphs in `SWIFTOS` by
   sampling, tinting, and blending the mask atlas on the GPU; and
7. sets scanout and flushes the compiler-provided presentation damage only
   after all dependent queue work completes.

`DisplayViewport` centers and integer-scales the 800 x 600 logical scene. The
full-damage clear includes letterboxes, so the first presentation damage is the
complete scanout.

The validated lifecycle uses 18 fenced control-queue transactions: display
query; two capset metadata queries; selected-capset payload; context creation;
create/attach for the color target, unit quad, and glyph atlas; quad upload; two
atlas-strip uploads; pipeline initialization; desktop-and-text render
submission; scanout selection; and flush. The context, targets, immutable
geometry and coverage assets, and initialized IR compiler remain owned by
`VirtIOGPU3DSession`. Its reusable `render` entry point lowers another immutable
command buffer, submits it to the same GPU target, and issues a fenced flush for
the caller's checked damage rectangle. Neither bootstrap nor reusable
submission maps or uploads CPU-made color or scanout pixels; the R8 bytes are
immutable glyph coverage that the GPU turns into visible text.

If no accelerated device is available, boot emits
`SWIFTOS:GRAPHICS_DIAGNOSTIC` before entering the software route. Once an
accelerated device starts a session, any failure is fatal and cannot fall back
to CPU rendering; a source gate rejects CPU framebuffer dependencies in that
crossing. The installed local QEMU build does not provide a GL-backed VirGL
device, so this accelerated pixel path is source-, protocol-, and host-tested
but has not produced locally hardware-exercised pixels or a captured
accelerated frame.

## Accelerated file-manager runtime

The reusable GPU session now has a bounded file-manager consumer rather than
only static boot-scene builders. `AcceleratedFileManagerInteractionState` is
backend-neutral and owns caller-supplied storage for directory entries and
names, window records, type-ahead text, cursor/focus/capture state, and
deterministic animation. It loads a mounted `VFSNodeProvider`, copies borrowed
names immediately, restarts once after a stale directory cookie, and reports a
bounded truncated page instead of reading past capacity.

Canonical pointer and keyboard events enter through a synchronous dispatcher.
The state converts physical relative motion into logical coordinates while
retaining subpixel remainders, performs shared-layout hit testing, scrolls and
selects visible rows, composes a bounded US-keyboard type-ahead prefix, and
marks frames dirty only while input or a transition changes visible state. The
single-owner contract requires input polling and rendering to occur serially;
SMP input remains inactive until an IRQ/service-thread design supplies that
ownership.

`GPUFileManagerSceneCompiler` emits one chrome pass and one text pass for the
window, rows, hover/selection state, and cursor. The QEMU wrapper keeps the UI
state in stable allocator-backed pages and calls `VirtIOGPU3DSession.renderBatch`
so both passes become one ordered GPU submission followed by one damage flush.
The GPU-only source audit rejects software-framebuffer and CPU-rasterizer
dependencies across the full runtime. Focused host tests cover input routing,
pointer scaling, keyboard navigation/type-ahead, animation retirement,
provider-cookie restart, copied names, and capacity truncation.

`KernelMain` now owns the complete accelerated bootstrap loop: it loads the
mounted provider, transfers the retained GPU session to one mutable owner,
presents the first file-manager frame, completes the opening transition, and in
single-CPU mode drains input before servicing input-driven redraws. This path is
compiled, host-tested, and source-audited, but it remains a visual-verification
boundary: the installed QEMU cannot expose a GL-backed VirGL device, so no local
accelerated file-manager pixels or interaction capture exist. The runtime is
kernel bootstrap infrastructure, not an EL0 window server.

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
configuration, enumerates and validates bounded VirGL capability sets including
R8 sampling, encodes context/resource/transfer/submit control messages, and
emits VirGL surface, framebuffer, clear, fixed-state, shader, sampler-view,
sampler-state, texture, draw, and GPU-to-GPU copy commands. The boot path now
creates that context and submits a GPU-rasterized retained desktop compiled
through `GPUDesktopScene` and `GPURetainedSceneCompiler`, followed by the
GPU-sampled `SWIFTOS` label from `GPUBootTextScene`. A reusable session API
accepts later GPU-only IR frames with bounded damage.

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
packet order, fence progression, color and R8 sampler capability rejection,
unit-quad upload, exact atlas bytes and two-strip upload packets, glyph shader
and sampler state, retained boot-scene and text-scene construction, 1080p and 4K
integer viewport scaling, full-clear presentation damage, per-corner analytic
coverage, transformed padded bounds, shader switching, five initial quad draws,
seven glyph draws, reusable submission, and damage flush. The GPU-only source
audit separately requires the retained scene, rounded-shader, mask-atlas, and
GPU-text crossings and prevents software rasterizer, software text, or
framebuffer types from entering accelerated activation and execution.

The live animation loop currently belongs to the single-CPU EL1 diagnostic
monitor. The Pi image and diagnostic multicore QEMU path rasterize the same
retained component's initial state through software before entering the EL0
scheduler. The installed QEMU cannot run the VirGL GL route, and the Pi image
has not run on physical hardware, so neither accelerated QEMU pixels nor
physical Pi output are hardware-verified.

`make virtio-gpu-3d-acceptance` is the strict opt-in live gate. It starts a
GL-backed `virtio-gpu-gl-device` with SwiftFS, keyboard, and relative-pointer
devices; requires accelerator, mounted-provider, ready, first-frame, and
steady-frame markers; validates a nonuniform 800 x 600 GPU screendump; injects
exact `+37/-19` pointer motion; requires the guest input and interaction-frame
markers; and accepts only a second screendump with at least 16 changed pixels.
QEMU capability absence makes the underlying probe exit 77, which `make`
reports as a failed target. This gate is intentionally outside `make test`, and
the installed macOS QEMU currently takes the unavailable path.

## Next renderer increments

- Exercise the fully wired provider-backed file-manager boot and interaction
  loop on a GL-backed VirGL QEMU configuration, retaining serial, fence, and
  captured-pixel evidence.
- Move ongoing retained-scene updates from the single-owner bootstrap loop into
  the frame scheduler and graphics mailbox as a dedicated service.
- Add retained image, glyph-run, border, gradient, shadow, and transform content
  while preserving old/new damage reporting and GPU-only pixel production.
- Grow the fixed boot mask into bounded font loading, layout and shaping,
  dynamic atlas allocation/update/eviction, and batched glyph runs behind a
  font-face contract.
- Define kernel-owned surfaces and immutable frame submissions for EL0 clients;
  applications must never map scanout directly.
- Move frame scheduling to a compositor thread driven by a display/vblank event,
  with counter pacing retained as a tested fallback.
- Implement native Pi V3D VII command submission, graphics address translation,
  HVS display lists, vblank, HDMI hotplug/DDC/EDID, clocking, and PHY control
  behind the same contracts.
- Move the existing bounded input hit testing/focus model behind an EL0 window
  and surface service only after object handles and checked user-copy exist.

This is the base of a modern UI renderer, not yet a window server. The QEMU
accelerated branch has both the static retained bootstrap scene and a bounded
provider-backed file-manager compiler/runtime with kernel-side input routing.
It still has one immutable R8 boot atlas, no EL0 surfaces, general image
textures, dynamic font loading or shaping, mutable atlas lifecycle, paths, or
vblank-driven compositor service. Neither the checked-in GPU bootstrap frame
nor the file-manager frame has been exercised by the installed local QEMU.
