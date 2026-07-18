/// Allocation-free source-over rasterization for the shared linear scanout.
///
/// The compositor uses this path for translucent and rounded visual layers.
/// All arithmetic is integer and deterministic so host tests and bare-metal
/// targets produce identical pixels without a floating-point UI dependency.
extension LinearFramebuffer {
    @discardableResult
    func blend(
        _ rectangle: Rectangle,
        color: PixelColor,
        opacity: UInt8,
        cornerRadius: Int = 0,
        clippedTo clip: Rectangle? = nil
    ) -> Bool {
        guard cornerRadius >= 0,
              width > 0,
              height > 0,
              strideInPixels >= width,
              strideInPixels > 0,
              height <= Int.max / strideInPixels,
              let sourceBounds = RasterBounds(rectangle),
              let framebufferBounds = RasterBounds(
                  x: 0,
                  y: 0,
                  width: width,
                  height: height
              ),
              let pixels = UnsafeMutableRawPointer(bitPattern: baseAddress)?
                .assumingMemoryBound(to: UInt32.self)
        else {
            return false
        }
        if opacity == 0 { return true }

        var drawBounds = sourceBounds.intersection(framebufferBounds)
        if let clip {
            guard let clipBounds = RasterBounds(clip) else { return false }
            drawBounds = drawBounds?.intersection(clipBounds)
        }
        guard let drawBounds else { return true }

        let maximumRadius = minimum(rectangle.width, rectangle.height) / 2
        let radius = minimum(cornerRadius, maximumRadius)
        // Four fixed subpixel samples use coordinates scaled by four. This
        // practical upper bound covers every real display mode while keeping
        // the squared-distance comparison inside UInt64.
        guard radius <= Int(UInt32.max / 4) else { return false }

        var y = drawBounds.minimumY
        while y < drawBounds.maximumY {
            let row = pixels.advanced(by: y * strideInPixels)
            var x = drawBounds.minimumX
            while x < drawBounds.maximumX {
                let coverage = roundedCoverage(
                    x: x,
                    y: y,
                    rectangle: rectangle,
                    radius: radius
                )
                if coverage > 0 {
                    let effectiveAlpha = UInt8(
                        (UInt16(opacity) * UInt16(coverage) + 2) / 4
                    )
                    let destination = row.advanced(by: x)
                    destination.pointee = blendedPixel(
                        source: color.xrgb,
                        destination: destination.pointee,
                        alpha: effectiveAlpha,
                        format: pixelFormat
                    )
                }
                x += 1
            }
            y += 1
        }
        return true
    }

    private func roundedCoverage(
        x: Int,
        y: Int,
        rectangle: Rectangle,
        radius: Int
    ) -> UInt8 {
        guard radius > 0 else { return 4 }
        let localXResult = x.subtractingReportingOverflow(rectangle.x)
        let localYResult = y.subtractingReportingOverflow(rectangle.y)
        guard !localXResult.overflow, !localYResult.overflow else { return 0 }
        let localX = localXResult.partialValue
        let localY = localYResult.partialValue

        let centerX: Int
        if localX < radius {
            centerX = radius
        } else if localX >= rectangle.width - radius {
            centerX = rectangle.width - radius
        } else {
            return 4
        }

        let centerY: Int
        if localY < radius {
            centerY = radius
        } else if localY >= rectangle.height - radius {
            centerY = rectangle.height - radius
        } else {
            return 4
        }

        let scaledRadius = UInt64(radius) * 4
        let radiusSquared = scaledRadius * scaledRadius
        var covered: UInt8 = 0
        if subpixelIsInside(
            localX: localX,
            localY: localY,
            offsetX: 1,
            offsetY: 1,
            centerX: centerX,
            centerY: centerY,
            radiusSquared: radiusSquared
        ) { covered += 1 }
        if subpixelIsInside(
            localX: localX,
            localY: localY,
            offsetX: 3,
            offsetY: 1,
            centerX: centerX,
            centerY: centerY,
            radiusSquared: radiusSquared
        ) { covered += 1 }
        if subpixelIsInside(
            localX: localX,
            localY: localY,
            offsetX: 1,
            offsetY: 3,
            centerX: centerX,
            centerY: centerY,
            radiusSquared: radiusSquared
        ) { covered += 1 }
        if subpixelIsInside(
            localX: localX,
            localY: localY,
            offsetX: 3,
            offsetY: 3,
            centerX: centerX,
            centerY: centerY,
            radiusSquared: radiusSquared
        ) { covered += 1 }
        return covered
    }

    private func subpixelIsInside(
        localX: Int,
        localY: Int,
        offsetX: UInt64,
        offsetY: UInt64,
        centerX: Int,
        centerY: Int,
        radiusSquared: UInt64
    ) -> Bool {
        guard let distanceX = scaledSampleDistance(
                  pixelOrigin: localX,
                  sampleOffset: offsetX,
                  center: centerX
              ),
              let distanceY = scaledSampleDistance(
                  pixelOrigin: localY,
                  sampleOffset: offsetY,
                  center: centerY
              )
        else {
            return false
        }
        let xSquared = distanceX.multipliedReportingOverflow(by: distanceX)
        let ySquared = distanceY.multipliedReportingOverflow(by: distanceY)
        guard !xSquared.overflow,
              !ySquared.overflow,
              xSquared.partialValue <= UInt64.max - ySquared.partialValue
        else {
            return false
        }
        return xSquared.partialValue + ySquared.partialValue <= radiusSquared
    }

    /// Computes distance in quarter-pixel units without scaling an absolute
    /// coordinate. A very large rectangle may intersect a small framebuffer at
    /// its far corner; only the corner-relative distance is bounded by radius.
    private func scaledSampleDistance(
        pixelOrigin: Int,
        sampleOffset: UInt64,
        center: Int
    ) -> UInt64? {
        guard pixelOrigin >= 0,
              center >= 0,
              sampleOffset < 4
        else {
            return nil
        }
        if pixelOrigin >= center {
            let units = UInt64(pixelOrigin - center)
            let scaled = units.multipliedReportingOverflow(by: 4)
            guard !scaled.overflow,
                  scaled.partialValue <= UInt64.max - sampleOffset
            else {
                return nil
            }
            return scaled.partialValue + sampleOffset
        }

        let units = UInt64(center - pixelOrigin)
        let scaled = units.multipliedReportingOverflow(by: 4)
        guard !scaled.overflow,
              scaled.partialValue >= sampleOffset
        else {
            return nil
        }
        return scaled.partialValue - sampleOffset
    }

    private func blendedPixel(
        source: UInt32,
        destination: UInt32,
        alpha: UInt8,
        format: PixelFormat
    ) -> UInt32 {
        let sourceRed = (source >> 16) & 0xff
        let sourceGreen = (source >> 8) & 0xff
        let sourceBlue = source & 0xff
        let destinationRed = (destination >> 16) & 0xff
        let destinationGreen = (destination >> 8) & 0xff
        let destinationBlue = destination & 0xff
        let sourceWeight = UInt32(alpha)
        let destinationWeight = 255 - sourceWeight

        let red = (sourceRed * sourceWeight
            + destinationRed * destinationWeight + 127) / 255
        let green = (sourceGreen * sourceWeight
            + destinationGreen * destinationWeight + 127) / 255
        let blue = (sourceBlue * sourceWeight
            + destinationBlue * destinationWeight + 127) / 255
        let rgb = red << 16 | green << 8 | blue
        switch format {
        case .b8g8r8x8:
            return rgb
        case .b8g8r8a8:
            return 0xff00_0000 | rgb
        }
    }

    private func minimum(_ left: Int, _ right: Int) -> Int {
        left < right ? left : right
    }
}

/// Half-open bounds with saturated positive ends. This is intentionally
/// separate from the public Rectangle value so malformed geometry never
/// reaches pointer arithmetic.
private struct RasterBounds {
    let minimumX: Int
    let minimumY: Int
    let maximumX: Int
    let maximumY: Int

    init?(_ rectangle: Rectangle) {
        self.init(
            x: rectangle.x,
            y: rectangle.y,
            width: rectangle.width,
            height: rectangle.height
        )
    }

    init?(x: Int, y: Int, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let maximumX = x.addingReportingOverflow(width)
        let maximumY = y.addingReportingOverflow(height)
        self.minimumX = x
        self.minimumY = y
        self.maximumX = maximumX.overflow ? Int.max : maximumX.partialValue
        self.maximumY = maximumY.overflow ? Int.max : maximumY.partialValue
    }

    func intersection(_ other: RasterBounds) -> RasterBounds? {
        let minimumX = maximum(self.minimumX, other.minimumX)
        let minimumY = maximum(self.minimumY, other.minimumY)
        let maximumX = minimum(self.maximumX, other.maximumX)
        let maximumY = minimum(self.maximumY, other.maximumY)
        guard minimumX < maximumX, minimumY < maximumY else { return nil }
        return RasterBounds(
            minimumX: minimumX,
            minimumY: minimumY,
            maximumX: maximumX,
            maximumY: maximumY
        )
    }

    private init(
        minimumX: Int,
        minimumY: Int,
        maximumX: Int,
        maximumY: Int
    ) {
        self.minimumX = minimumX
        self.minimumY = minimumY
        self.maximumX = maximumX
        self.maximumY = maximumY
    }

    private func minimum(_ left: Int, _ right: Int) -> Int {
        left < right ? left : right
    }

    private func maximum(_ left: Int, _ right: Int) -> Int {
        left > right ? left : right
    }
}
