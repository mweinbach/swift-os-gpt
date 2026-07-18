struct DetailedDisplayTiming: Equatable {
    let pixelClockHertz: UInt64
    let horizontalActivePixels: UInt32
    let horizontalBlankingPixels: UInt32
    let verticalActiveLines: UInt32
    let verticalBlankingLines: UInt32
    let physicalSize: PhysicalDisplaySize?
    let isInterlaced: Bool
    let refreshRate: RationalRefreshRate
    let frameRefreshRate: RationalRefreshRate

    init?(
        pixelClockHertz: UInt64,
        horizontalActivePixels: UInt32,
        horizontalBlankingPixels: UInt32,
        verticalActiveLines: UInt32,
        verticalBlankingLines: UInt32,
        physicalSize: PhysicalDisplaySize?,
        isInterlaced: Bool
    ) {
        guard pixelClockHertz > 0,
              horizontalActivePixels > 0,
              horizontalBlankingPixels > 0,
              verticalActiveLines > 0,
              verticalBlankingLines > 0
        else {
            return nil
        }

        let horizontalTotal = horizontalActivePixels.addingReportingOverflow(
            horizontalBlankingPixels
        )
        let verticalTotal = verticalActiveLines.addingReportingOverflow(
            verticalBlankingLines
        )
        guard !horizontalTotal.overflow, !verticalTotal.overflow,
              let refreshRate = RationalRefreshRate(
                numeratorHertz: pixelClockHertz,
                denominator: UInt64(horizontalTotal.partialValue)
                    * UInt64(verticalTotal.partialValue)
              ),
              let frameRefreshRate = isInterlaced
                ? refreshRate.divided(by: 2)
                : refreshRate
        else {
            return nil
        }

        self.pixelClockHertz = pixelClockHertz
        self.horizontalActivePixels = horizontalActivePixels
        self.horizontalBlankingPixels = horizontalBlankingPixels
        self.verticalActiveLines = verticalActiveLines
        self.verticalBlankingLines = verticalBlankingLines
        self.physicalSize = physicalSize
        self.isInterlaced = isInterlaced
        self.refreshRate = refreshRate
        self.frameRefreshRate = frameRefreshRate
    }

    var horizontalTotalPixels: UInt32 {
        horizontalActivePixels + horizontalBlankingPixels
    }

    var verticalTotalLines: UInt32 {
        verticalActiveLines + verticalBlankingLines
    }

    var pixelDensity: DisplayPixelDensity? {
        guard let physicalSize else {
            return nil
        }
        return DisplayPixelDensity.calculate(
            horizontalPixels: horizontalActivePixels,
            verticalPixels: verticalActiveLines,
            physicalSize: physicalSize
        )
    }
}
