struct LinearFramebuffer {
    let baseAddress: UInt
    let width: Int
    let height: Int
    let strideInPixels: Int

    func fill(_ color: PixelColor) {
        fill(
            Rectangle(x: 0, y: 0, width: width, height: height),
            color: color
        )
    }

    func fill(_ rectangle: Rectangle, color: PixelColor) {
        var startX = rectangle.x
        var startY = rectangle.y
        var endX = rectangle.x + rectangle.width
        var endY = rectangle.y + rectangle.height

        if startX < 0 { startX = 0 }
        if startY < 0 { startY = 0 }
        if endX > width { endX = width }
        if endY > height { endY = height }
        guard startX < endX,
              startY < endY,
              let pixels = UnsafeMutableRawPointer(bitPattern: baseAddress)?
                .assumingMemoryBound(to: UInt32.self)
        else {
            return
        }

        var y = startY
        while y < endY {
            var x = startX
            let row = pixels.advanced(by: y * strideInPixels)
            while x < endX {
                row.advanced(by: x).pointee = color.xrgb
                x += 1
            }
            y += 1
        }
    }

    func stroke(_ rectangle: Rectangle, color: PixelColor, thickness: Int = 1) {
        guard thickness > 0 else { return }
        fill(
            Rectangle(x: rectangle.x, y: rectangle.y, width: rectangle.width, height: thickness),
            color: color
        )
        fill(
            Rectangle(
                x: rectangle.x,
                y: rectangle.y + rectangle.height - thickness,
                width: rectangle.width,
                height: thickness
            ),
            color: color
        )
        fill(
            Rectangle(x: rectangle.x, y: rectangle.y, width: thickness, height: rectangle.height),
            color: color
        )
        fill(
            Rectangle(
                x: rectangle.x + rectangle.width - thickness,
                y: rectangle.y,
                width: thickness,
                height: rectangle.height
            ),
            color: color
        )
    }

    func drawText(
        _ text: StaticString,
        at origin: Point,
        color: PixelColor,
        scale: Int = 1
    ) {
        guard scale > 0 else { return }
        text.withUTF8Buffer { bytes in
            var x = origin.x
            var y = origin.y
            for byte in bytes {
                if byte == 10 {
                    x = origin.x
                    y += 9 * scale
                } else {
                    drawCharacter(byte, at: Point(x: x, y: y), color: color, scale: scale)
                    x += 6 * scale
                }
            }
        }
    }

    func drawCharacter(
        _ character: UInt8,
        at origin: Point,
        color: PixelColor,
        scale: Int
    ) {
        let glyph = BitmapFont.glyph(for: character)
        var row = 0
        while row < 7 {
            let bits = UInt8(truncatingIfNeeded: glyph >> UInt64(row * 5))
            var column = 0
            while column < 5 {
                if bits & (1 << UInt8(4 - column)) != 0 {
                    fill(
                        Rectangle(
                            x: origin.x + column * scale,
                            y: origin.y + row * scale,
                            width: scale,
                            height: scale
                        ),
                        color: color
                    )
                }
                column += 1
            }
            row += 1
        }
    }
}
