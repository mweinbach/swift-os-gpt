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
