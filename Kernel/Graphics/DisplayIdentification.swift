struct RationalRefreshRate: Equatable {
    let numeratorHertz: UInt64
    let denominator: UInt64

    init?(numeratorHertz: UInt64, denominator: UInt64) {
        guard numeratorHertz > 0, denominator > 0 else {
            return nil
        }

        let divisor = Self.greatestCommonDivisor(
            numeratorHertz,
            denominator
        )
        self.numeratorHertz = numeratorHertz / divisor
        self.denominator = denominator / divisor
    }

    func divided(by divisor: UInt64) -> RationalRefreshRate? {
        guard divisor > 0 else {
            return nil
        }

        let commonDivisor = Self.greatestCommonDivisor(
            numeratorHertz,
            divisor
        )
        let reducedNumerator = numeratorHertz / commonDivisor
        let reducedDivisor = divisor / commonDivisor
        let scaledDenominator = denominator.multipliedReportingOverflow(
            by: reducedDivisor
        )
        guard !scaledDenominator.overflow else {
            return nil
        }

        return RationalRefreshRate(
            numeratorHertz: reducedNumerator,
            denominator: scaledDenominator.partialValue
        )
    }

    private static func greatestCommonDivisor(
        _ first: UInt64,
        _ second: UInt64
    ) -> UInt64 {
        var left = first
        var right = second
        while right != 0 {
            let remainder = left % right
            left = right
            right = remainder
        }
        return left
    }
}

struct PhysicalDisplaySize: Equatable {
    let widthMillimeters: UInt32
    let heightMillimeters: UInt32

    init?(widthMillimeters: UInt32, heightMillimeters: UInt32) {
        guard widthMillimeters > 0, heightMillimeters > 0 else {
            return nil
        }
        self.widthMillimeters = widthMillimeters
        self.heightMillimeters = heightMillimeters
    }
}

struct DisplayPixelDensity: Equatable {
    // Fixed-point diagonal PPI, rounded down to one hundredth of a PPI.
    let pixelsPerInchTimes100: UInt32

    static func calculate(
        horizontalPixels: UInt32,
        verticalPixels: UInt32,
        physicalSize: PhysicalDisplaySize
    ) -> DisplayPixelDensity? {
        guard horizontalPixels > 0, verticalPixels > 0 else {
            return nil
        }

        guard let pixelDiagonalSquared = sumOfSquares(
                UInt64(horizontalPixels),
                UInt64(verticalPixels)
              ),
              let physicalDiagonalSquared = sumOfSquares(
                UInt64(physicalSize.widthMillimeters),
                UInt64(physicalSize.heightMillimeters)
              )
        else {
            return nil
        }

        // 25.4 millimeters per inch, scaled by 100 for fixed-point PPI.
        let millimetersPerInchTimes100: UInt64 = 2_540
        let scaleSquared = millimetersPerInchTimes100
            * millimetersPerInchTimes100
        let scaledPixels = pixelDiagonalSquared.multipliedReportingOverflow(
            by: scaleSquared
        )
        guard !scaledPixels.overflow else {
            return nil
        }

        let densitySquared = scaledPixels.partialValue
            / physicalDiagonalSquared
        let density = integerSquareRoot(densitySquared)
        guard density > 0, density <= UInt64(UInt32.max) else {
            return nil
        }
        return DisplayPixelDensity(
            pixelsPerInchTimes100: UInt32(density)
        )
    }

    private static func sumOfSquares(
        _ first: UInt64,
        _ second: UInt64
    ) -> UInt64? {
        let firstSquared = first.multipliedReportingOverflow(by: first)
        let secondSquared = second.multipliedReportingOverflow(by: second)
        guard !firstSquared.overflow, !secondSquared.overflow else {
            return nil
        }
        let sum = firstSquared.partialValue.addingReportingOverflow(
            secondSquared.partialValue
        )
        return sum.overflow ? nil : sum.partialValue
    }

    private static func integerSquareRoot(_ value: UInt64) -> UInt64 {
        var lower: UInt64 = 0
        var upper: UInt64 = UInt64(UInt32.max)
        while lower < upper {
            let midpoint = lower + (upper - lower + 1) / 2
            if midpoint <= value / midpoint {
                lower = midpoint
            } else {
                upper = midpoint - 1
            }
        }
        return lower
    }
}

enum DisplayScaleFactor: UInt8, Equatable {
    case oneX = 1
    case twoX = 2
    case threeX = 3
}

struct DisplayScalePolicy: Equatable {
    let twoXMinimumPixelsPerInchTimes100: UInt32
    let threeXMinimumPixelsPerInchTimes100: UInt32

    init?(
        twoXMinimumPixelsPerInchTimes100: UInt32,
        threeXMinimumPixelsPerInchTimes100: UInt32
    ) {
        guard twoXMinimumPixelsPerInchTimes100 > 0,
              threeXMinimumPixelsPerInchTimes100
                > twoXMinimumPixelsPerInchTimes100
        else {
            return nil
        }
        self.twoXMinimumPixelsPerInchTimes100 =
            twoXMinimumPixelsPerInchTimes100
        self.threeXMinimumPixelsPerInchTimes100 =
            threeXMinimumPixelsPerInchTimes100
    }

    static var balanced: DisplayScalePolicy {
        DisplayScalePolicy(
            uncheckedTwoXMinimum: 16_000,
            uncheckedThreeXMinimum: 24_000
        )
    }

    func scale(for density: DisplayPixelDensity?) -> DisplayScaleFactor {
        guard let density else {
            return .oneX
        }
        if density.pixelsPerInchTimes100
            >= threeXMinimumPixelsPerInchTimes100
        {
            return .threeX
        }
        if density.pixelsPerInchTimes100
            >= twoXMinimumPixelsPerInchTimes100
        {
            return .twoX
        }
        return .oneX
    }

    private init(
        uncheckedTwoXMinimum: UInt32,
        uncheckedThreeXMinimum: UInt32
    ) {
        twoXMinimumPixelsPerInchTimes100 = uncheckedTwoXMinimum
        threeXMinimumPixelsPerInchTimes100 = uncheckedThreeXMinimum
    }
}
