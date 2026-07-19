enum SDBGStreamAppendResult: Equatable {
    case appended
    case invalidInput
    case capacityExceeded
}

enum SDBGDecodeRejection: Equatable {
    case invalidMagic
    case unsupportedVersion(major: UInt8, minor: UInt8)
    case unknownMessageKind(rawValue: UInt8)
    case payloadTooLarge(requested: UInt32, maximum: Int)
    case invalidEnvelope(SDBGSemanticRejection)
    case checksumMismatch(expected: UInt32, actual: UInt32)
}

enum SDBGStreamPumpResult {
    case needsMoreBytes(requiredTotalByteCount: Int)
    case frame(SDBGDecodedFrame)
    case discarded(rejection: SDBGDecodeRejection, byteCount: Int)
}

/// Resynchronizing, allocation-free framing for an ordered byte transport.
///
/// The caller owns `storage` and must keep it alive for the decoder's lifetime.
/// A returned payload aliases that storage and remains valid only until the
/// next call to `append`, `pump`, or `reset`.
struct SDBGStreamDecoder {
    private let storageBaseAddress: UInt
    private let storageByteCount: Int
    let maximumPayloadByteCount: Int
    private(set) var bufferedByteCount = 0
    private var pendingFrameByteCount = 0

    init?(
        storageBaseAddress: UInt,
        storageByteCount: Int,
        maximumPayloadByteCount: Int = SDBGProtocol.maximumPayloadByteCount
    ) {
        guard storageBaseAddress != 0,
              maximumPayloadByteCount >= 0,
              maximumPayloadByteCount <= SDBGProtocol.maximumPayloadByteCount,
              storageByteCount >= SDBGProtocol.headerByteCount,
              maximumPayloadByteCount
                <= storageByteCount - SDBGProtocol.headerByteCount,
              UInt(storageByteCount) <= UInt.max - storageBaseAddress
        else { return nil }
        self.storageBaseAddress = storageBaseAddress
        self.storageByteCount = storageByteCount
        self.maximumPayloadByteCount = maximumPayloadByteCount
    }

    mutating func append(
        _ bytes: UnsafeRawBufferPointer
    ) -> SDBGStreamAppendResult {
        prepareForMutation()
        guard bytes.count == 0 || bytes.baseAddress != nil else {
            return .invalidInput
        }
        guard bytes.count <= storageByteCount - bufferedByteCount,
              let destination = UnsafeMutableRawPointer(
                  bitPattern: storageBaseAddress
              )
        else { return .capacityExceeded }

        var index = 0
        while index < bytes.count {
            destination.storeBytes(
                of: bytes[index],
                toByteOffset: bufferedByteCount + index,
                as: UInt8.self
            )
            index += 1
        }
        bufferedByteCount += bytes.count
        return .appended
    }

    mutating func pump() -> SDBGStreamPumpResult {
        prepareForMutation()
        let input = storageBuffer
        guard bufferedByteCount >= 4 else {
            let discardCount = bytesBeforeNextMagic(in: input)
            if discardCount > 0 {
                discardPrefix(discardCount)
                return .discarded(
                    rejection: .invalidMagic,
                    byteCount: discardCount
                )
            }
            return .needsMoreBytes(requiredTotalByteCount: 4)
        }

        guard SDBGWire.readUInt32(input, at: 0) == SDBGProtocol.magic else {
            let discardCount = bytesBeforeNextMagic(in: input)
            discardPrefix(discardCount)
            return .discarded(
                rejection: .invalidMagic,
                byteCount: discardCount
            )
        }

        guard bufferedByteCount >= SDBGProtocol.headerByteCount else {
            return .needsMoreBytes(
                requiredTotalByteCount: SDBGProtocol.headerByteCount
            )
        }

        let major = input[4]
        let minor = input[5]
        guard major == SDBGProtocol.versionMajor,
              minor == SDBGProtocol.versionMinor
        else {
            discardPrefix(1)
            return .discarded(
                rejection: .unsupportedVersion(major: major, minor: minor),
                byteCount: 1
            )
        }

        guard let kind = SDBGMessageKind(rawValue: input[6]) else {
            let rawKind = input[6]
            discardPrefix(1)
            return .discarded(
                rejection: .unknownMessageKind(rawValue: rawKind),
                byteCount: 1
            )
        }

        let payloadLength = SDBGWire.readUInt32(input, at: 32)
        guard payloadLength <= UInt32(maximumPayloadByteCount) else {
            discardPrefix(1)
            return .discarded(
                rejection: .payloadTooLarge(
                    requested: payloadLength,
                    maximum: maximumPayloadByteCount
                ),
                byteCount: 1
            )
        }

        let flags = SDBGMessageFlags(rawValue: input[7])
        let bootSessionID = SDBGBootSessionID(
            high: SDBGWire.readUInt64(input, at: 8),
            low: SDBGWire.readUInt64(input, at: 16)
        )
        let requestID = SDBGWire.readUInt64(input, at: 24)
        if let rejection = SDBGEnvelopeValidator.validate(
            kind: kind,
            flags: flags,
            bootSessionID: bootSessionID,
            requestID: requestID
        ) {
            discardPrefix(1)
            return .discarded(
                rejection: .invalidEnvelope(rejection),
                byteCount: 1
            )
        }

        let frameByteCount = SDBGProtocol.headerByteCount + Int(payloadLength)
        guard bufferedByteCount >= frameByteCount else {
            return .needsMoreBytes(requiredTotalByteCount: frameByteCount)
        }

        let expectedCRC = SDBGWire.readUInt32(input, at: 36)
        var crc = SDBGCRC32()
        crc.update(
            input,
            offset: 0,
            count: SDBGProtocol.crcCoveredHeaderByteCount
        )
        crc.update(
            input,
            offset: SDBGProtocol.headerByteCount,
            count: Int(payloadLength)
        )
        guard expectedCRC == crc.value else {
            let actualCRC = crc.value
            discardPrefix(1)
            return .discarded(
                rejection: .checksumMismatch(
                    expected: expectedCRC,
                    actual: actualCRC
                ),
                byteCount: 1
            )
        }

        guard let base = input.baseAddress else {
            return .needsMoreBytes(requiredTotalByteCount: frameByteCount)
        }
        let payload = UnsafeRawBufferPointer(
            start: base.advanced(by: SDBGProtocol.headerByteCount),
            count: Int(payloadLength)
        )
        pendingFrameByteCount = frameByteCount
        return .frame(
            SDBGDecodedFrame(
                envelope: SDBGEnvelope(
                    kind: kind,
                    flags: flags,
                    bootSessionID: bootSessionID,
                    requestID: requestID
                ),
                payload: payload,
                encodedByteCount: frameByteCount
            )
        )
    }

    mutating func reset() {
        bufferedByteCount = 0
        pendingFrameByteCount = 0
    }

    private var storageBuffer: UnsafeRawBufferPointer {
        guard let base = UnsafeRawPointer(bitPattern: storageBaseAddress) else {
            return UnsafeRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeRawBufferPointer(start: base, count: bufferedByteCount)
    }

    private mutating func prepareForMutation() {
        guard pendingFrameByteCount > 0 else { return }
        let consumed = pendingFrameByteCount
        pendingFrameByteCount = 0
        discardPrefix(consumed)
    }

    private func bytesBeforeNextMagic(
        in input: UnsafeRawBufferPointer
    ) -> Int {
        var candidate = 1
        while candidate + 4 <= input.count {
            if SDBGWire.readUInt32(input, at: candidate)
                == SDBGProtocol.magic {
                return candidate
            }
            candidate += 1
        }

        var retained = 3
        if retained > input.count { retained = input.count }
        while retained > 0 {
            var matches = true
            var index = 0
            while index < retained {
                let magicByte = UInt8(
                    truncatingIfNeeded: SDBGProtocol.magic >> (index * 8)
                )
                if input[input.count - retained + index] != magicByte {
                    matches = false
                    break
                }
                index += 1
            }
            if matches { return input.count - retained }
            retained -= 1
        }
        return input.count
    }

    private mutating func discardPrefix(_ requestedByteCount: Int) {
        let discardCount = requestedByteCount < bufferedByteCount
            ? requestedByteCount
            : bufferedByteCount
        let remaining = bufferedByteCount - discardCount
        guard remaining > 0,
              let storage = UnsafeMutableRawPointer(
                  bitPattern: storageBaseAddress
              )
        else {
            bufferedByteCount = 0
            return
        }

        var index = 0
        while index < remaining {
            let byte = storage.load(
                fromByteOffset: discardCount + index,
                as: UInt8.self
            )
            storage.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
            index += 1
        }
        bufferedByteCount = remaining
    }
}
