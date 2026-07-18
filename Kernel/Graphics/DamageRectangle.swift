struct DamageRectangle: Equatable {
    let x: UInt32
    let y: UInt32
    let width: UInt32
    let height: UInt32

    private init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    static func clipped(
        x: Int64,
        y: Int64,
        width: Int64,
        height: Int64,
        to mode: DisplayMode
    ) -> DamageRectangle? {
        guard width > 0, height > 0 else {
            return nil
        }

        let horizontalEnd = saturatedPositiveEnd(start: x, length: width)
        let verticalEnd = saturatedPositiveEnd(start: y, length: height)
        let modeWidth = Int64(mode.widthInPixels)
        let modeHeight = Int64(mode.heightInPixels)

        let clippedX = maximum(x, 0)
        let clippedY = maximum(y, 0)
        let clippedEndX = minimum(horizontalEnd, modeWidth)
        let clippedEndY = minimum(verticalEnd, modeHeight)

        guard clippedX < clippedEndX, clippedY < clippedEndY else {
            return nil
        }

        return DamageRectangle(
            x: UInt32(clippedX),
            y: UInt32(clippedY),
            width: UInt32(clippedEndX - clippedX),
            height: UInt32(clippedEndY - clippedY)
        )
    }

    static func fullMode(_ mode: DisplayMode) -> DamageRectangle {
        DamageRectangle(
            x: 0,
            y: 0,
            width: mode.widthInPixels,
            height: mode.heightInPixels
        )
    }

    private static func saturatedPositiveEnd(
        start: Int64,
        length: Int64
    ) -> Int64 {
        let result = start.addingReportingOverflow(length)
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func minimum(_ left: Int64, _ right: Int64) -> Int64 {
        left < right ? left : right
    }

    private static func maximum(_ left: Int64, _ right: Int64) -> Int64 {
        left > right ? left : right
    }
}
