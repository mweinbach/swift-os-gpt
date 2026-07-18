enum EDIDBaseBlockParseError: UInt8, Equatable {
    case insufficientBytes
    case invalidHeader
    case invalidChecksum
    case invalidPreferredDetailedTiming
}

enum EDIDBaseBlockParseResult: Equatable {
    case success(EDIDBaseBlock)
    case failure(EDIDBaseBlockParseError)
}

struct EDIDBaseBlock: Equatable {
    static let byteCount = 128

    let manufacturerCode: UInt16
    let productCode: UInt16
    let serialNumber: UInt32
    let manufactureWeek: UInt8
    let manufactureYear: UInt16
    let version: UInt8
    let revision: UInt8
    let physicalSize: PhysicalDisplaySize?
    let declaresPreferredTiming: Bool
    let preferredDetailedTiming: DetailedDisplayTiming?
    let extensionBlockCount: UInt8

    static func parse(_ bytes: UnsafeRawBufferPointer) -> EDIDBaseBlockParseResult {
        guard bytes.count >= byteCount else {
            return .failure(.insufficientBytes)
        }
        guard hasValidHeader(bytes) else {
            return .failure(.invalidHeader)
        }
        guard hasValidChecksum(bytes) else {
            return .failure(.invalidChecksum)
        }

        let preferredTiming: DetailedDisplayTiming?
        switch parseDetailedTiming(bytes, at: 54) {
        case .none:
            preferredTiming = nil
        case .timing(let timing):
            preferredTiming = timing
        case .invalid:
            return .failure(.invalidPreferredDetailedTiming)
        }

        let widthMillimeters = UInt32(bytes[21]) * 10
        let heightMillimeters = UInt32(bytes[22]) * 10
        let physicalSize = PhysicalDisplaySize(
            widthMillimeters: widthMillimeters,
            heightMillimeters: heightMillimeters
        )

        return .success(
            EDIDBaseBlock(
                manufacturerCode: readBigEndianUInt16(bytes, at: 8),
                productCode: readLittleEndianUInt16(bytes, at: 10),
                serialNumber: readLittleEndianUInt32(bytes, at: 12),
                manufactureWeek: bytes[16],
                manufactureYear: UInt16(bytes[17]) + 1_990,
                version: bytes[18],
                revision: bytes[19],
                physicalSize: physicalSize,
                declaresPreferredTiming: bytes[24] & 0x02 != 0,
                preferredDetailedTiming: preferredTiming,
                extensionBlockCount: bytes[126]
            )
        )
    }

    private enum DetailedTimingResult {
        case none
        case timing(DetailedDisplayTiming)
        case invalid
    }

    private static func parseDetailedTiming(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> DetailedTimingResult {
        guard offset >= 0, offset <= bytes.count - 18 else {
            return .invalid
        }

        let pixelClockUnits = readLittleEndianUInt16(bytes, at: offset)
        guard pixelClockUnits != 0 else {
            return .none
        }

        let horizontalActive = UInt32(bytes[offset + 2])
            | UInt32(bytes[offset + 4] & 0xf0) << 4
        let horizontalBlanking = UInt32(bytes[offset + 3])
            | UInt32(bytes[offset + 4] & 0x0f) << 8
        let verticalActive = UInt32(bytes[offset + 5])
            | UInt32(bytes[offset + 7] & 0xf0) << 4
        let verticalBlanking = UInt32(bytes[offset + 6])
            | UInt32(bytes[offset + 7] & 0x0f) << 8
        let widthMillimeters = UInt32(bytes[offset + 12])
            | UInt32(bytes[offset + 14] & 0xf0) << 4
        let heightMillimeters = UInt32(bytes[offset + 13])
            | UInt32(bytes[offset + 14] & 0x0f) << 8
        let physicalSize = PhysicalDisplaySize(
            widthMillimeters: widthMillimeters,
            heightMillimeters: heightMillimeters
        )

        guard let timing = DetailedDisplayTiming(
            pixelClockHertz: UInt64(pixelClockUnits) * 10_000,
            horizontalActivePixels: horizontalActive,
            horizontalBlankingPixels: horizontalBlanking,
            verticalActiveLines: verticalActive,
            verticalBlankingLines: verticalBlanking,
            physicalSize: physicalSize,
            isInterlaced: bytes[offset + 17] & 0x80 != 0
        ) else {
            return .invalid
        }
        return .timing(timing)
    }

    private static func hasValidHeader(_ bytes: UnsafeRawBufferPointer) -> Bool {
        bytes[0] == 0x00
            && bytes[1] == 0xff
            && bytes[2] == 0xff
            && bytes[3] == 0xff
            && bytes[4] == 0xff
            && bytes[5] == 0xff
            && bytes[6] == 0xff
            && bytes[7] == 0x00
    }

    private static func hasValidChecksum(
        _ bytes: UnsafeRawBufferPointer
    ) -> Bool {
        var checksum: UInt8 = 0
        var index = 0
        while index < byteCount {
            checksum &+= bytes[index]
            index += 1
        }
        return checksum == 0
    }

    private static func readLittleEndianUInt16(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readBigEndianUInt16(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readLittleEndianUInt32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
