/// Allocation-free logical drawing surface over a physical linear scanout.
/// Board drivers provide the scanout; shared UI code draws in one stable
/// coordinate space and this canvas owns integer scaling and letterboxing.
struct ScaledFramebufferCanvas {
    let framebuffer: LinearFramebuffer
    let viewport: DisplayViewport

    init?(framebuffer: LinearFramebuffer, viewport: DisplayViewport) {
        guard framebuffer.width == viewport.physicalWidth,
              framebuffer.height == viewport.physicalHeight,
              framebuffer.strideInPixels >= framebuffer.width
        else {
            return nil
        }
        self.framebuffer = framebuffer
        self.viewport = viewport
    }

    func clear(_ color: PixelColor) {
        framebuffer.fill(color)
    }

    func fill(_ rectangle: Rectangle, color: PixelColor) {
        guard let physical = viewport.transformClipped(rectangle) else {
            return
        }
        framebuffer.fill(physical, color: color)
    }

    func stroke(
        _ rectangle: Rectangle,
        color: PixelColor,
        thickness: Int = 1
    ) {
        guard let physical = viewport.transformClipped(rectangle),
              let physicalThickness = viewport.scaledLength(thickness),
              physicalThickness > 0
        else {
            return
        }
        framebuffer.stroke(
            physical,
            color: color,
            thickness: physicalThickness
        )
    }

    /// Source-over composition in logical coordinates. The uncut physical
    /// frame is retained for correct rounded-corner geometry, while the
    /// logical desktop and optional layer clip constrain actual writes.
    @discardableResult
    func blend(
        _ rectangle: Rectangle,
        color: PixelColor,
        opacity: UInt8,
        cornerRadius: Int = 0,
        clippedTo logicalClip: Rectangle? = nil
    ) -> Bool {
        guard rectangle.width > 0,
              rectangle.height > 0,
              cornerRadius >= 0,
              let physicalOrigin = viewport.transform(
                  Point(x: rectangle.x, y: rectangle.y)
              ),
              let physicalWidth = viewport.scaledLength(rectangle.width),
              let physicalHeight = viewport.scaledLength(rectangle.height),
              let physicalRadius = viewport.scaledLength(cornerRadius)
        else {
            return false
        }
        let effectiveLogicalClip = logicalClip ?? viewport.logicalBounds
        guard let physicalClip = viewport.transformClipped(
                  effectiveLogicalClip
              )
        else {
            return true
        }
        return framebuffer.blend(
            Rectangle(
                x: physicalOrigin.x,
                y: physicalOrigin.y,
                width: physicalWidth,
                height: physicalHeight
            ),
            color: color,
            opacity: opacity,
            cornerRadius: physicalRadius,
            clippedTo: physicalClip
        )
    }

    /// Converts logical compositor damage to the physical scanout contract.
    /// Returning nil means the logical damage is entirely offscreen.
    func damageRectangle(
        for logicalRectangle: Rectangle,
        mode: DisplayMode
    ) -> DamageRectangle? {
        guard Int(mode.widthInPixels) == viewport.physicalWidth,
              Int(mode.heightInPixels) == viewport.physicalHeight,
              let physical = viewport.transformClipped(logicalRectangle)
        else {
            return nil
        }
        return DamageRectangle.clipped(
            x: Int64(physical.x),
            y: Int64(physical.y),
            width: Int64(physical.width),
            height: Int64(physical.height),
            to: mode
        )
    }

    func drawText(
        _ text: StaticString,
        at origin: Point,
        color: PixelColor,
        scale logicalScale: Int = 1
    ) {
        guard logicalScale > 0,
              let physicalOrigin = viewport.transform(origin)
        else {
            return
        }
        let scale = logicalScale.multipliedReportingOverflow(
            by: viewport.scale
        )
        guard !scale.overflow else { return }
        framebuffer.drawText(
            text,
            at: physicalOrigin,
            color: color,
            scale: scale.partialValue
        )
    }

    func drawCharacter(
        _ character: UInt8,
        at origin: Point,
        color: PixelColor,
        scale logicalScale: Int = 1
    ) {
        guard logicalScale > 0,
              let physicalOrigin = viewport.transform(origin)
        else {
            return
        }
        let scale = logicalScale.multipliedReportingOverflow(
            by: viewport.scale
        )
        guard !scale.overflow else { return }
        framebuffer.drawCharacter(
            character,
            at: physicalOrigin,
            color: color,
            scale: scale.partialValue
        )
    }
}
