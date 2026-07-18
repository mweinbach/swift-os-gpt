/// Maps a logical desktop coordinate space into a physical display mode.
///
/// Scaling is always an integer. The viewport selects the largest scale that
/// fits unless a smaller preferred scale is supplied, then centers the result.
/// Modes smaller than the logical desktop use one-to-one centered cropping so
/// every valid display mode still has a usable viewport.
struct DisplayViewport {
    let logicalWidth: Int
    let logicalHeight: Int
    let physicalWidth: Int
    let physicalHeight: Int
    let scale: Int
    let origin: Point

    init?(
        mode: DisplayMode,
        logicalWidth: Int = 800,
        logicalHeight: Int = 600,
        preferredScale: Int? = nil
    ) {
        guard logicalWidth > 0, logicalHeight > 0 else {
            return nil
        }
        if let preferredScale, preferredScale <= 0 {
            return nil
        }

        let physicalWidth = Int(mode.widthInPixels)
        let physicalHeight = Int(mode.heightInPixels)
        let horizontalFit = physicalWidth / logicalWidth
        let verticalFit = physicalHeight / logicalHeight
        let fittingScale = horizontalFit < verticalFit
            ? horizontalFit
            : verticalFit
        let largestUsableScale = fittingScale > 1 ? fittingScale : 1
        let requestedScale = preferredScale ?? largestUsableScale
        let selectedScale = requestedScale < largestUsableScale
            ? requestedScale
            : largestUsableScale

        let scaledWidth = logicalWidth.multipliedReportingOverflow(
            by: selectedScale
        )
        let scaledHeight = logicalHeight.multipliedReportingOverflow(
            by: selectedScale
        )
        guard !scaledWidth.overflow, !scaledHeight.overflow else {
            return nil
        }

        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.physicalWidth = physicalWidth
        self.physicalHeight = physicalHeight
        scale = selectedScale
        origin = Point(
            x: (physicalWidth - scaledWidth.partialValue) / 2,
            y: (physicalHeight - scaledHeight.partialValue) / 2
        )
    }

    var logicalBounds: Rectangle {
        Rectangle(x: 0, y: 0, width: logicalWidth, height: logicalHeight)
    }

    var physicalBounds: Rectangle {
        Rectangle(x: 0, y: 0, width: physicalWidth, height: physicalHeight)
    }

    /// The complete scaled desktop. It may extend beyond `physicalBounds` on
    /// a display smaller than the logical coordinate space.
    var contentBounds: Rectangle {
        Rectangle(
            x: origin.x,
            y: origin.y,
            width: logicalWidth * scale,
            height: logicalHeight * scale
        )
    }

    /// Maps a logical pixel origin when it is both inside the logical desktop
    /// and visible on the physical display.
    func transformClipped(_ logicalPoint: Point) -> Point? {
        guard logicalPoint.x >= 0,
              logicalPoint.y >= 0,
              logicalPoint.x < logicalWidth,
              logicalPoint.y < logicalHeight
        else {
            return nil
        }

        guard let physicalPoint = transform(logicalPoint) else { return nil }
        guard physicalPoint.x >= 0,
              physicalPoint.y >= 0,
              physicalPoint.x < physicalWidth,
              physicalPoint.y < physicalHeight
        else {
            return nil
        }
        return physicalPoint
    }

    /// Maps a logical origin without visibility clipping. Framebuffer drawing
    /// primitives perform their own clipping, which preserves partially
    /// visible glyphs when a mode is smaller than the logical desktop.
    func transform(_ logicalPoint: Point) -> Point? {
        let scaledX = logicalPoint.x.multipliedReportingOverflow(by: scale)
        let scaledY = logicalPoint.y.multipliedReportingOverflow(by: scale)
        guard !scaledX.overflow, !scaledY.overflow else { return nil }
        let physicalX = origin.x.addingReportingOverflow(scaledX.partialValue)
        let physicalY = origin.y.addingReportingOverflow(scaledY.partialValue)
        guard !physicalX.overflow, !physicalY.overflow else { return nil }
        return Point(x: physicalX.partialValue, y: physicalY.partialValue)
    }

    /// Clips a logical rectangle to the desktop, maps it, then clips the
    /// result to the physical display. Empty and fully hidden rectangles are
    /// represented by `nil`.
    func transformClipped(_ logicalRectangle: Rectangle) -> Rectangle? {
        guard logicalRectangle.width > 0, logicalRectangle.height > 0 else {
            return nil
        }

        let logicalEndX = saturatedPositiveEnd(
            start: logicalRectangle.x,
            length: logicalRectangle.width
        )
        let logicalEndY = saturatedPositiveEnd(
            start: logicalRectangle.y,
            length: logicalRectangle.height
        )
        let clippedLogicalX = maximum(logicalRectangle.x, 0)
        let clippedLogicalY = maximum(logicalRectangle.y, 0)
        let clippedLogicalEndX = minimum(logicalEndX, logicalWidth)
        let clippedLogicalEndY = minimum(logicalEndY, logicalHeight)
        guard clippedLogicalX < clippedLogicalEndX,
              clippedLogicalY < clippedLogicalEndY
        else {
            return nil
        }

        let mappedX = origin.x + clippedLogicalX * scale
        let mappedY = origin.y + clippedLogicalY * scale
        let mappedEndX = origin.x + clippedLogicalEndX * scale
        let mappedEndY = origin.y + clippedLogicalEndY * scale
        let clippedPhysicalX = maximum(mappedX, 0)
        let clippedPhysicalY = maximum(mappedY, 0)
        let clippedPhysicalEndX = minimum(mappedEndX, physicalWidth)
        let clippedPhysicalEndY = minimum(mappedEndY, physicalHeight)
        guard clippedPhysicalX < clippedPhysicalEndX,
              clippedPhysicalY < clippedPhysicalEndY
        else {
            return nil
        }

        return Rectangle(
            x: clippedPhysicalX,
            y: clippedPhysicalY,
            width: clippedPhysicalEndX - clippedPhysicalX,
            height: clippedPhysicalEndY - clippedPhysicalY
        )
    }

    /// Converts a nonnegative logical length for line widths, glyph scales,
    /// and other size-only values.
    func scaledLength(_ logicalLength: Int) -> Int? {
        guard logicalLength >= 0 else {
            return nil
        }
        let result = logicalLength.multipliedReportingOverflow(by: scale)
        return result.overflow ? nil : result.partialValue
    }

    private func saturatedPositiveEnd(start: Int, length: Int) -> Int {
        let result = start.addingReportingOverflow(length)
        return result.overflow ? Int.max : result.partialValue
    }

    private func minimum(_ left: Int, _ right: Int) -> Int {
        left < right ? left : right
    }

    private func maximum(_ left: Int, _ right: Int) -> Int {
        left > right ? left : right
    }
}
