@main
struct EDIDBaseBlockTests {
    static func main() {
        testExactRefreshRate()
        testPhysicalDensityAndScale()
        testPreferredDetailedTiming()
        testInterlacedFrameRate()
        testBoundsHeaderAndChecksumValidation()
        testDetailedTimingValidation()
        print("EDID base-block host tests: 6 groups passed")
    }

    private static func testExactRefreshRate() {
        let reduced = RationalRefreshRate(
            numeratorHertz: 120_000,
            denominator: 2_002
        )
        expect(reduced?.numeratorHertz == 60_000, "refresh numerator reduction")
        expect(reduced?.denominator == 1_001, "refresh denominator reduction")
        expect(
            reduced?.divided(by: 2)?.numeratorHertz == 30_000,
            "exact refresh division numerator"
        )
        expect(
            reduced?.divided(by: 2)?.denominator == 1_001,
            "exact refresh division denominator"
        )
        expect(
            RationalRefreshRate(numeratorHertz: 60, denominator: 0) == nil,
            "zero refresh denominator accepted"
        )
    }

    private static func testPhysicalDensityAndScale() {
        let size = requireSize(width: 509, height: 286)
        let density = DisplayPixelDensity.calculate(
            horizontalPixels: 1_920,
            verticalPixels: 1_080,
            physicalSize: size
        )
        expect(
            density?.pixelsPerInchTimes100 == 9_583,
            "diagonal fixed-point PPI"
        )
        expect(DisplayScalePolicy.balanced.scale(for: density) == .oneX,
               "one-X density policy")

        let highDensity = DisplayPixelDensity.calculate(
            horizontalPixels: 3_840,
            verticalPixels: 2_160,
            physicalSize: size
        )
        expect(DisplayScalePolicy.balanced.scale(for: highDensity) == .twoX,
               "two-X density policy")

        let veryHighDensity = DisplayPixelDensity.calculate(
            horizontalPixels: 7_680,
            verticalPixels: 4_320,
            physicalSize: size
        )
        expect(DisplayScalePolicy.balanced.scale(for: veryHighDensity) == .threeX,
               "three-X density policy")
        expect(DisplayScalePolicy.balanced.scale(for: nil) == .oneX,
               "unknown density fallback")
        expect(
            DisplayScalePolicy(
                twoXMinimumPixelsPerInchTimes100: 20_000,
                threeXMinimumPixelsPerInchTimes100: 20_000
            ) == nil,
            "unordered scale thresholds accepted"
        )
    }

    private static func testPreferredDetailedTiming() {
        let result = parse(validEDID())
        guard case .success(let block) = result,
              let timing = block.preferredDetailedTiming
        else {
            fatalError("valid EDID was rejected")
        }

        expect(block.manufacturerCode == 0x4c2d, "manufacturer code")
        expect(block.productCode == 0x1234, "product code")
        expect(block.serialNumber == 0x1234_5678, "serial number")
        expect(block.manufactureWeek == 22, "manufacture week")
        expect(block.manufactureYear == 2_024, "manufacture year")
        expect(block.version == 1 && block.revision == 4, "EDID version")
        expect(block.physicalSize?.widthMillimeters == 510,
               "base physical width")
        expect(block.physicalSize?.heightMillimeters == 290,
               "base physical height")
        expect(block.declaresPreferredTiming, "preferred timing flag")
        expect(block.extensionBlockCount == 0, "extension count")

        expect(timing.pixelClockHertz == 148_500_000, "pixel clock")
        expect(timing.horizontalActivePixels == 1_920, "horizontal active")
        expect(timing.horizontalBlankingPixels == 280, "horizontal blanking")
        expect(timing.verticalActiveLines == 1_080, "vertical active")
        expect(timing.verticalBlankingLines == 45, "vertical blanking")
        expect(timing.horizontalTotalPixels == 2_200, "horizontal total")
        expect(timing.verticalTotalLines == 1_125, "vertical total")
        expect(timing.physicalSize?.widthMillimeters == 509,
               "timing physical width")
        expect(timing.physicalSize?.heightMillimeters == 286,
               "timing physical height")
        expect(!timing.isInterlaced, "progressive timing marked interlaced")
        expect(timing.refreshRate.numeratorHertz == 60,
               "exact preferred refresh numerator")
        expect(timing.refreshRate.denominator == 1,
               "exact preferred refresh denominator")
        expect(timing.pixelDensity?.pixelsPerInchTimes100 == 9_583,
               "preferred timing density")
    }

    private static func testInterlacedFrameRate() {
        guard let timing = DetailedDisplayTiming(
            pixelClockHertz: 148_350_000,
            horizontalActivePixels: 1_920,
            horizontalBlankingPixels: 280,
            verticalActiveLines: 1_080,
            verticalBlankingLines: 45,
            physicalSize: nil,
            isInterlaced: true
        ),
        let expectedFieldRate = RationalRefreshRate(
            numeratorHertz: 148_350_000,
            denominator: 2_200 * 1_125
        )
        else {
            fatalError("valid interlaced timing fixture rejected")
        }

        expect(timing.refreshRate == expectedFieldRate,
               "exact non-integer field refresh")
        expect(timing.frameRefreshRate == expectedFieldRate.divided(by: 2),
               "interlaced frame refresh")
        expect(timing.pixelDensity == nil, "unknown physical size density")
    }

    private static func testBoundsHeaderAndChecksumValidation() {
        let shortBlock = Array(validEDID().prefix(127))
        expect(
            parse(shortBlock) == .failure(.insufficientBytes),
            "short base block accepted"
        )

        var badHeader = validEDID()
        badHeader[1] = 0x00
        updateChecksum(&badHeader)
        expect(
            parse(badHeader) == .failure(.invalidHeader),
            "bad EDID header accepted"
        )

        var badChecksum = validEDID()
        badChecksum[20] ^= 1
        expect(
            parse(badChecksum) == .failure(.invalidChecksum),
            "bad EDID checksum accepted"
        )
    }

    private static func testDetailedTimingValidation() {
        var invalidTiming = validEDID()
        invalidTiming[56] = 0
        invalidTiming[58] &= 0x0f
        updateChecksum(&invalidTiming)
        expect(
            parse(invalidTiming) == .failure(.invalidPreferredDetailedTiming),
            "invalid preferred DTD accepted"
        )

        var descriptorOnly = validEDID()
        descriptorOnly[54] = 0
        descriptorOnly[55] = 0
        updateChecksum(&descriptorOnly)
        guard case .success(let block) = parse(descriptorOnly) else {
            fatalError("monitor descriptor EDID was rejected")
        }
        expect(block.preferredDetailedTiming == nil,
               "monitor descriptor parsed as a timing")
    }

    private static func validEDID() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: EDIDBaseBlock.byteCount)
        bytes[0] = 0x00
        bytes[1] = 0xff
        bytes[2] = 0xff
        bytes[3] = 0xff
        bytes[4] = 0xff
        bytes[5] = 0xff
        bytes[6] = 0xff
        bytes[7] = 0x00
        bytes[8] = 0x4c
        bytes[9] = 0x2d
        bytes[10] = 0x34
        bytes[11] = 0x12
        bytes[12] = 0x78
        bytes[13] = 0x56
        bytes[14] = 0x34
        bytes[15] = 0x12
        bytes[16] = 22
        bytes[17] = 34
        bytes[18] = 1
        bytes[19] = 4
        bytes[21] = 51
        bytes[22] = 29
        bytes[24] = 0x02

        let timingOffset = 54
        let timing: [UInt8] = [
            0x02, 0x3a,
            0x80, 0x18, 0x71,
            0x38, 0x2d, 0x40,
            0x58, 0x2c, 0x45, 0x00,
            0xfd, 0x1e, 0x11,
            0x00, 0x00, 0x1a,
        ]
        var timingIndex = 0
        while timingIndex < timing.count {
            bytes[timingOffset + timingIndex] = timing[timingIndex]
            timingIndex += 1
        }
        bytes[126] = 0
        updateChecksum(&bytes)
        return bytes
    }

    private static func updateChecksum(_ bytes: inout [UInt8]) {
        bytes[127] = 0
        var checksum: UInt8 = 0
        var index = 0
        while index < 127 {
            checksum &+= bytes[index]
            index += 1
        }
        bytes[127] = UInt8(0) &- checksum
    }

    private static func parse(_ bytes: [UInt8]) -> EDIDBaseBlockParseResult {
        bytes.withUnsafeBytes { rawBytes in
            EDIDBaseBlock.parse(rawBytes)
        }
    }

    private static func requireSize(
        width: UInt32,
        height: UInt32
    ) -> PhysicalDisplaySize {
        guard let size = PhysicalDisplaySize(
            widthMillimeters: width,
            heightMillimeters: height
        ) else {
            fatalError("valid physical-size fixture rejected")
        }
        return size
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("EDID assertion failed: \(message)")
        }
    }
}
