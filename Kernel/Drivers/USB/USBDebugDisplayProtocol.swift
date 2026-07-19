/// Versioned wire protocol for exporting completed display frames over a USB
/// debug transport.
///
/// This is a diagnostic observation path only. It neither owns rendering nor
/// permits a CPU rasterizer to replace the production GPU renderer. The guest
/// codec is allocation-free: callers provide every packet and stream buffer.
enum USBDebugDisplayProtocol {
    static let magic: UInt32 = 0x5044_4453 // "SDDP" on the wire.
    static let versionMajor: UInt8 = 1
    static let versionMinor: UInt8 = 0
    static let headerByteCount = 40
    static let maximumPayloadByteCount = 1_024
    static let maximumPacketByteCount =
        headerByteCount + maximumPayloadByteCount
    static let frameChunkPrefixByteCount = 16
    static let maximumChunkDataByteCount =
        maximumPayloadByteCount - frameChunkPrefixByteCount
    static let maximumDimension: UInt32 = 32_767
}

enum USBDebugDisplayMessageType: UInt8, Equatable {
    case hello = 1
    case capabilities = 2
    case displayMode = 3
    case fullFrameBegin = 4
    case damageFrameBegin = 5
    case frameChunk = 6
    case frameEnd = 7
    case reset = 8
}

enum USBDebugDisplayEndpointRole: UInt8, Equatable {
    case guest = 1
    case host = 2
}

struct USBDebugDisplayCapabilityBits: Equatable {
    static let diagnosticOnly: UInt32 = 1 << 0
    static let fullFrames: UInt32 = 1 << 1
    static let damageRectangles: UInt32 = 1 << 2
    static let chunkChecksums: UInt32 = 1 << 3
    static let displayMetadata: UInt32 = 1 << 4
    static let resetRecovery: UInt32 = 1 << 5
    static let required: UInt32 = diagnosticOnly | fullFrames
        | damageRectangles | chunkChecksums | displayMetadata | resetRecovery

    let rawValue: UInt32

    func contains(_ mask: UInt32) -> Bool {
        rawValue & mask == mask
    }
}

enum USBDebugDisplayPixelFormat: UInt32, Equatable {
    // DRM XR24 and AR24. Pixel bytes are B, G, R, X/A on little-endian hosts.
    case b8g8r8x8 = 0x3432_5258
    case b8g8r8a8 = 0x3432_5241

    var bytesPerPixel: UInt32 { 4 }

    var capabilityMask: UInt32 {
        switch self {
        case .b8g8r8x8: return 1 << 0
        case .b8g8r8a8: return 1 << 1
        }
    }
}

struct USBDebugDisplayHello: Equatable {
    let sessionID: UInt64
    let minimumVersionMajor: UInt8
    let minimumVersionMinor: UInt8
    let maximumVersionMajor: UInt8
    let maximumVersionMinor: UInt8
    let role: USBDebugDisplayEndpointRole

    init?(
        sessionID: UInt64,
        minimumVersionMajor: UInt8 = USBDebugDisplayProtocol.versionMajor,
        minimumVersionMinor: UInt8 = USBDebugDisplayProtocol.versionMinor,
        maximumVersionMajor: UInt8 = USBDebugDisplayProtocol.versionMajor,
        maximumVersionMinor: UInt8 = USBDebugDisplayProtocol.versionMinor,
        role: USBDebugDisplayEndpointRole
    ) {
        guard sessionID != 0,
              minimumVersionMajor < maximumVersionMajor
                || minimumVersionMajor == maximumVersionMajor
                    && minimumVersionMinor <= maximumVersionMinor
        else {
            return nil
        }
        self.sessionID = sessionID
        self.minimumVersionMajor = minimumVersionMajor
        self.minimumVersionMinor = minimumVersionMinor
        self.maximumVersionMajor = maximumVersionMajor
        self.maximumVersionMinor = maximumVersionMinor
        self.role = role
    }

    var supportsCurrentVersion: Bool {
        let currentMajor = USBDebugDisplayProtocol.versionMajor
        let currentMinor = USBDebugDisplayProtocol.versionMinor
        let notBeforeMinimum = currentMajor > minimumVersionMajor
            || currentMajor == minimumVersionMajor
                && currentMinor >= minimumVersionMinor
        let notAfterMaximum = currentMajor < maximumVersionMajor
            || currentMajor == maximumVersionMajor
                && currentMinor <= maximumVersionMinor
        return notBeforeMinimum && notAfterMaximum
    }
}

struct USBDebugDisplayCapabilities: Equatable {
    let sessionID: UInt64
    let features: USBDebugDisplayCapabilityBits
    let maximumPayloadByteCount: UInt32
    let maximumChunkDataByteCount: UInt32
    let maximumWidth: UInt32
    let maximumHeight: UInt32
    let pixelFormatMask: UInt32

    init?(
        sessionID: UInt64,
        features: USBDebugDisplayCapabilityBits,
        maximumPayloadByteCount: UInt32,
        maximumChunkDataByteCount: UInt32,
        maximumWidth: UInt32,
        maximumHeight: UInt32,
        pixelFormatMask: UInt32
    ) {
        guard sessionID != 0,
              maximumPayloadByteCount
                <= UInt32(USBDebugDisplayProtocol.maximumPayloadByteCount),
              maximumPayloadByteCount
                > UInt32(USBDebugDisplayProtocol.frameChunkPrefixByteCount),
              maximumChunkDataByteCount != 0,
              maximumChunkDataByteCount
                <= maximumPayloadByteCount
                    - UInt32(
                        USBDebugDisplayProtocol.frameChunkPrefixByteCount
                    ),
              maximumWidth != 0,
              maximumHeight != 0,
              maximumWidth <= USBDebugDisplayProtocol.maximumDimension,
              maximumHeight <= USBDebugDisplayProtocol.maximumDimension,
              pixelFormatMask != 0
        else {
            return nil
        }
        self.sessionID = sessionID
        self.features = features
        self.maximumPayloadByteCount = maximumPayloadByteCount
        self.maximumChunkDataByteCount = maximumChunkDataByteCount
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.pixelFormatMask = pixelFormatMask
    }

    func supports(_ format: USBDebugDisplayPixelFormat) -> Bool {
        pixelFormatMask & format.capabilityMask != 0
    }
}

struct USBDebugDisplayMode: Equatable {
    let width: UInt32
    let height: UInt32
    let bytesPerRow: UInt32
    let pixelFormat: USBDebugDisplayPixelFormat
    let scaleNumerator: UInt16
    let scaleDenominator: UInt16
    /// Zero means the display did not publish physical density.
    let horizontalPixelsPerInchMilli: UInt32
    /// Zero means the display did not publish physical density.
    let verticalPixelsPerInchMilli: UInt32
    /// Zero means the transport does not know the active refresh rate.
    let refreshRateMilliHertz: UInt32

    init?(
        width: UInt32,
        height: UInt32,
        bytesPerRow: UInt32,
        pixelFormat: USBDebugDisplayPixelFormat,
        scaleNumerator: UInt16,
        scaleDenominator: UInt16,
        horizontalPixelsPerInchMilli: UInt32,
        verticalPixelsPerInchMilli: UInt32,
        refreshRateMilliHertz: UInt32
    ) {
        guard width != 0, height != 0,
              width <= USBDebugDisplayProtocol.maximumDimension,
              height <= USBDebugDisplayProtocol.maximumDimension,
              scaleNumerator != 0, scaleDenominator != 0
        else {
            return nil
        }
        let minimumRow = width.multipliedReportingOverflow(
            by: pixelFormat.bytesPerPixel
        )
        guard !minimumRow.overflow, bytesPerRow >= minimumRow.partialValue else {
            return nil
        }
        let byteCount = UInt64(bytesPerRow).multipliedReportingOverflow(
            by: UInt64(height)
        )
        guard !byteCount.overflow, byteCount.partialValue != 0 else {
            return nil
        }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.scaleNumerator = scaleNumerator
        self.scaleDenominator = scaleDenominator
        self.horizontalPixelsPerInchMilli = horizontalPixelsPerInchMilli
        self.verticalPixelsPerInchMilli = verticalPixelsPerInchMilli
        self.refreshRateMilliHertz = refreshRateMilliHertz
    }

    var fullFrameByteCount: UInt64 {
        UInt64(bytesPerRow) * UInt64(height)
    }
}

struct USBDebugDisplayDamageRectangle: Equatable {
    let x: UInt32
    let y: UInt32
    let width: UInt32
    let height: UInt32

    init?(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        guard width != 0, height != 0 else { return nil }
        let endX = x.addingReportingOverflow(width)
        let endY = y.addingReportingOverflow(height)
        guard !endX.overflow, !endY.overflow else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func fits(_ mode: USBDebugDisplayMode) -> Bool {
        x + width <= mode.width && y + height <= mode.height
    }

    func packedByteCount(
        format: USBDebugDisplayPixelFormat
    ) -> UInt64? {
        // Damage payloads are tightly packed; unlike a full frame they do not
        // carry the scanout's bytes-per-row padding between rectangle rows.
        let row = UInt64(width).multipliedReportingOverflow(
            by: UInt64(format.bytesPerPixel)
        )
        guard !row.overflow else { return nil }
        let total = row.partialValue.multipliedReportingOverflow(
            by: UInt64(height)
        )
        return total.overflow ? nil : total.partialValue
    }
}

struct USBDebugDisplayFullFrameBegin: Equatable {
    let totalDataByteCount: UInt64
    let chunkCount: UInt32
}

struct USBDebugDisplayDamageFrameBegin: Equatable {
    let rectangle: USBDebugDisplayDamageRectangle
    let totalDataByteCount: UInt64
    let chunkCount: UInt32
}

struct USBDebugDisplayFrameChunk {
    let chunkSequence: UInt32
    let offset: UInt64
    let data: UnsafeRawBufferPointer
}

struct USBDebugDisplayFrameEnd: Equatable {
    let chunkCount: UInt32
    let frameCRC32: UInt32
    let totalDataByteCount: UInt64
}

enum USBDebugDisplayResetReason: UInt16, Equatable {
    case requested = 1
    case framingError = 2
    case sequenceError = 3
    case boundsError = 4
    case checksumError = 5
    case unsupportedMode = 6
}

struct USBDebugDisplayReset: Equatable {
    let generation: UInt32
    let reason: USBDebugDisplayResetReason
    let previousSessionID: UInt64
}

enum USBDebugDisplayMessage {
    case hello(USBDebugDisplayHello)
    case capabilities(USBDebugDisplayCapabilities)
    case displayMode(USBDebugDisplayMode)
    case fullFrameBegin(USBDebugDisplayFullFrameBegin)
    case damageFrameBegin(USBDebugDisplayDamageFrameBegin)
    case frameChunk(USBDebugDisplayFrameChunk)
    case frameEnd(USBDebugDisplayFrameEnd)
    case reset(USBDebugDisplayReset)

    var type: USBDebugDisplayMessageType {
        switch self {
        case .hello: return .hello
        case .capabilities: return .capabilities
        case .displayMode: return .displayMode
        case .fullFrameBegin: return .fullFrameBegin
        case .damageFrameBegin: return .damageFrameBegin
        case .frameChunk: return .frameChunk
        case .frameEnd: return .frameEnd
        case .reset: return .reset
        }
    }

    var requiresFrameID: Bool {
        switch self {
        case .fullFrameBegin, .damageFrameBegin, .frameChunk, .frameEnd:
            return true
        case .hello, .capabilities, .displayMode, .reset:
            return false
        }
    }
}

struct USBDebugDisplayDecodedPacket {
    let sequence: UInt32
    let frameID: UInt64
    let message: USBDebugDisplayMessage
    let encodedByteCount: Int
}

enum USBDebugDisplayEncodeRejection: Equatable {
    case zeroSequence
    case invalidFrameID
    case invalidMessage
    case payloadTooLarge(requested: Int, maximum: Int)
    case outputBufferTooSmall(required: Int, available: Int)
}

enum USBDebugDisplayEncodeResult: Equatable {
    case encoded(byteCount: Int)
    case rejected(USBDebugDisplayEncodeRejection)
}

enum USBDebugDisplayPacketEncoder {
    static func encode(
        _ message: USBDebugDisplayMessage,
        sequence: UInt32,
        frameID: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> USBDebugDisplayEncodeResult {
        guard sequence != 0 else { return .rejected(.zeroSequence) }
        guard message.requiresFrameID ? frameID != 0 : frameID == 0 else {
            return .rejected(.invalidFrameID)
        }
        guard let payloadByteCount = payloadByteCount(for: message) else {
            return .rejected(.invalidMessage)
        }
        guard payloadByteCount <= USBDebugDisplayProtocol.maximumPayloadByteCount
        else {
            return .rejected(
                .payloadTooLarge(
                    requested: payloadByteCount,
                    maximum: USBDebugDisplayProtocol.maximumPayloadByteCount
                )
            )
        }
        let packetByteCount = USBDebugDisplayProtocol.headerByteCount
            + payloadByteCount
        guard output.count >= packetByteCount else {
            return .rejected(
                .outputBufferTooSmall(
                    required: packetByteCount,
                    available: output.count
                )
            )
        }

        guard encodePayload(
                  message,
                  into: output,
                  payloadOffset: USBDebugDisplayProtocol.headerByteCount
              )
        else {
            return .rejected(.invalidMessage)
        }
        let payloadCRC = USBDebugDisplayCRC32.checksum(
            output,
            offset: USBDebugDisplayProtocol.headerByteCount,
            count: payloadByteCount
        )
        USBDebugDisplayWire.writeUInt32(
            USBDebugDisplayProtocol.magic,
            to: output,
            at: 0
        )
        output[4] = USBDebugDisplayProtocol.versionMajor
        output[5] = USBDebugDisplayProtocol.versionMinor
        output[6] = message.type.rawValue
        output[7] = 0
        USBDebugDisplayWire.writeUInt16(
            UInt16(USBDebugDisplayProtocol.headerByteCount),
            to: output,
            at: 8
        )
        USBDebugDisplayWire.writeUInt16(0, to: output, at: 10)
        USBDebugDisplayWire.writeUInt32(
            UInt32(payloadByteCount),
            to: output,
            at: 12
        )
        USBDebugDisplayWire.writeUInt32(sequence, to: output, at: 16)
        USBDebugDisplayWire.writeUInt64(frameID, to: output, at: 20)
        USBDebugDisplayWire.writeUInt32(payloadCRC, to: output, at: 28)
        USBDebugDisplayWire.writeUInt32(
            UInt32(packetByteCount),
            to: output,
            at: 32
        )
        let headerCRC = USBDebugDisplayCRC32.checksum(
            output,
            offset: 0,
            count: 36
        )
        USBDebugDisplayWire.writeUInt32(headerCRC, to: output, at: 36)
        return .encoded(byteCount: packetByteCount)
    }

    private static func payloadByteCount(
        for message: USBDebugDisplayMessage
    ) -> Int? {
        switch message {
        case .hello: return 16
        case .capabilities: return 32
        case .displayMode: return 36
        case .fullFrameBegin: return 16
        case .damageFrameBegin: return 32
        case .frameChunk(let chunk):
            guard chunk.chunkSequence != 0,
                  chunk.data.count > 0,
                  chunk.data.count
                    <= USBDebugDisplayProtocol.maximumChunkDataByteCount
            else {
                return nil
            }
            return USBDebugDisplayProtocol.frameChunkPrefixByteCount
                + chunk.data.count
        case .frameEnd: return 24
        case .reset: return 16
        }
    }

    private static func encodePayload(
        _ message: USBDebugDisplayMessage,
        into output: UnsafeMutableRawBufferPointer,
        payloadOffset: Int
    ) -> Bool {
        switch message {
        case .hello(let hello):
            guard hello.sessionID != 0 else { return false }
            USBDebugDisplayWire.writeUInt64(
                hello.sessionID,
                to: output,
                at: payloadOffset
            )
            output[payloadOffset + 8] = hello.minimumVersionMajor
            output[payloadOffset + 9] = hello.minimumVersionMinor
            output[payloadOffset + 10] = hello.maximumVersionMajor
            output[payloadOffset + 11] = hello.maximumVersionMinor
            output[payloadOffset + 12] = hello.role.rawValue
            output[payloadOffset + 13] = 0
            USBDebugDisplayWire.writeUInt16(0, to: output, at: payloadOffset + 14)

        case .capabilities(let capabilities):
            USBDebugDisplayWire.writeUInt64(
                capabilities.sessionID,
                to: output,
                at: payloadOffset
            )
            USBDebugDisplayWire.writeUInt32(
                capabilities.features.rawValue,
                to: output,
                at: payloadOffset + 8
            )
            USBDebugDisplayWire.writeUInt32(
                capabilities.maximumPayloadByteCount,
                to: output,
                at: payloadOffset + 12
            )
            USBDebugDisplayWire.writeUInt32(
                capabilities.maximumChunkDataByteCount,
                to: output,
                at: payloadOffset + 16
            )
            USBDebugDisplayWire.writeUInt32(
                capabilities.maximumWidth,
                to: output,
                at: payloadOffset + 20
            )
            USBDebugDisplayWire.writeUInt32(
                capabilities.maximumHeight,
                to: output,
                at: payloadOffset + 24
            )
            USBDebugDisplayWire.writeUInt32(
                capabilities.pixelFormatMask,
                to: output,
                at: payloadOffset + 28
            )

        case .displayMode(let mode):
            USBDebugDisplayWire.writeUInt32(mode.width, to: output, at: payloadOffset)
            USBDebugDisplayWire.writeUInt32(mode.height, to: output, at: payloadOffset + 4)
            USBDebugDisplayWire.writeUInt32(mode.bytesPerRow, to: output, at: payloadOffset + 8)
            USBDebugDisplayWire.writeUInt32(mode.pixelFormat.rawValue, to: output, at: payloadOffset + 12)
            USBDebugDisplayWire.writeUInt16(mode.scaleNumerator, to: output, at: payloadOffset + 16)
            USBDebugDisplayWire.writeUInt16(mode.scaleDenominator, to: output, at: payloadOffset + 18)
            USBDebugDisplayWire.writeUInt32(mode.horizontalPixelsPerInchMilli, to: output, at: payloadOffset + 20)
            USBDebugDisplayWire.writeUInt32(mode.verticalPixelsPerInchMilli, to: output, at: payloadOffset + 24)
            USBDebugDisplayWire.writeUInt32(mode.refreshRateMilliHertz, to: output, at: payloadOffset + 28)
            USBDebugDisplayWire.writeUInt32(0, to: output, at: payloadOffset + 32)

        case .fullFrameBegin(let begin):
            guard begin.totalDataByteCount != 0, begin.chunkCount != 0 else {
                return false
            }
            USBDebugDisplayWire.writeUInt64(begin.totalDataByteCount, to: output, at: payloadOffset)
            USBDebugDisplayWire.writeUInt32(begin.chunkCount, to: output, at: payloadOffset + 8)
            USBDebugDisplayWire.writeUInt32(0, to: output, at: payloadOffset + 12)

        case .damageFrameBegin(let begin):
            guard begin.totalDataByteCount != 0, begin.chunkCount != 0 else {
                return false
            }
            USBDebugDisplayWire.writeUInt32(begin.rectangle.x, to: output, at: payloadOffset)
            USBDebugDisplayWire.writeUInt32(begin.rectangle.y, to: output, at: payloadOffset + 4)
            USBDebugDisplayWire.writeUInt32(begin.rectangle.width, to: output, at: payloadOffset + 8)
            USBDebugDisplayWire.writeUInt32(begin.rectangle.height, to: output, at: payloadOffset + 12)
            USBDebugDisplayWire.writeUInt64(begin.totalDataByteCount, to: output, at: payloadOffset + 16)
            USBDebugDisplayWire.writeUInt32(begin.chunkCount, to: output, at: payloadOffset + 24)
            USBDebugDisplayWire.writeUInt32(0, to: output, at: payloadOffset + 28)

        case .frameChunk(let chunk):
            USBDebugDisplayWire.writeUInt32(chunk.chunkSequence, to: output, at: payloadOffset)
            USBDebugDisplayWire.writeUInt32(UInt32(chunk.data.count), to: output, at: payloadOffset + 4)
            USBDebugDisplayWire.writeUInt64(chunk.offset, to: output, at: payloadOffset + 8)
            var index = 0
            while index < chunk.data.count {
                output[payloadOffset + 16 + index] = chunk.data[index]
                index += 1
            }

        case .frameEnd(let end):
            guard end.chunkCount != 0, end.totalDataByteCount != 0 else {
                return false
            }
            USBDebugDisplayWire.writeUInt32(end.chunkCount, to: output, at: payloadOffset)
            USBDebugDisplayWire.writeUInt32(end.frameCRC32, to: output, at: payloadOffset + 4)
            USBDebugDisplayWire.writeUInt64(end.totalDataByteCount, to: output, at: payloadOffset + 8)
            USBDebugDisplayWire.writeUInt64(0, to: output, at: payloadOffset + 16)

        case .reset(let reset):
            USBDebugDisplayWire.writeUInt32(reset.generation, to: output, at: payloadOffset)
            USBDebugDisplayWire.writeUInt16(reset.reason.rawValue, to: output, at: payloadOffset + 4)
            USBDebugDisplayWire.writeUInt16(0, to: output, at: payloadOffset + 6)
            USBDebugDisplayWire.writeUInt64(reset.previousSessionID, to: output, at: payloadOffset + 8)
        }
        return true
    }
}

enum USBDebugDisplayDecodeRejection: Equatable {
    case invalidMagic
    case unsupportedVersion(major: UInt8, minor: UInt8)
    case invalidHeaderLength
    case nonzeroReservedField
    case unknownMessageType(UInt8)
    case payloadTooLarge(requested: UInt32, maximum: Int)
    case inconsistentPacketLength
    case headerChecksumMismatch
    case payloadChecksumMismatch
    case zeroSequence
    case invalidFrameID
    case malformedPayload(USBDebugDisplayMessageType)
}

enum USBDebugDisplayDecodeResult {
    case decoded(USBDebugDisplayDecodedPacket)
    case needMoreBytes(requiredTotalByteCount: Int)
    /// Discard this many bytes from a caller-owned stream buffer, then retry.
    case rejected(
        USBDebugDisplayDecodeRejection,
        recoveryDiscardByteCount: Int
    )
}

enum USBDebugDisplayPacketDecoder {
    static func decodePrefix(
        _ input: UnsafeRawBufferPointer
    ) -> USBDebugDisplayDecodeResult {
        guard input.count >= 4 else {
            return .needMoreBytes(requiredTotalByteCount: 4)
        }
        guard USBDebugDisplayWire.readUInt32(input, at: 0)
                == USBDebugDisplayProtocol.magic
        else {
            return rejected(.invalidMagic, in: input)
        }
        guard input.count >= USBDebugDisplayProtocol.headerByteCount else {
            return .needMoreBytes(
                requiredTotalByteCount: USBDebugDisplayProtocol.headerByteCount
            )
        }
        let major = input[4]
        let minor = input[5]
        guard major == USBDebugDisplayProtocol.versionMajor,
              minor == USBDebugDisplayProtocol.versionMinor
        else {
            return rejected(
                .unsupportedVersion(major: major, minor: minor),
                in: input
            )
        }
        guard USBDebugDisplayWire.readUInt16(input, at: 8)
                == UInt16(USBDebugDisplayProtocol.headerByteCount)
        else {
            return rejected(.invalidHeaderLength, in: input)
        }
        guard input[7] == 0,
              USBDebugDisplayWire.readUInt16(input, at: 10) == 0
        else {
            return rejected(.nonzeroReservedField, in: input)
        }
        guard let type = USBDebugDisplayMessageType(rawValue: input[6]) else {
            return rejected(.unknownMessageType(input[6]), in: input)
        }
        let payloadByteCount = USBDebugDisplayWire.readUInt32(input, at: 12)
        guard payloadByteCount
                <= UInt32(USBDebugDisplayProtocol.maximumPayloadByteCount)
        else {
            return rejected(
                .payloadTooLarge(
                    requested: payloadByteCount,
                    maximum: USBDebugDisplayProtocol.maximumPayloadByteCount
                ),
                in: input
            )
        }
        let total = UInt64(USBDebugDisplayProtocol.headerByteCount)
            + UInt64(payloadByteCount)
        guard total <= UInt64(Int.max),
              USBDebugDisplayWire.readUInt32(input, at: 32) == UInt32(total)
        else {
            return rejected(.inconsistentPacketLength, in: input)
        }
        let packetByteCount = Int(total)
        guard input.count >= packetByteCount else {
            return .needMoreBytes(requiredTotalByteCount: packetByteCount)
        }
        let headerCRC = USBDebugDisplayCRC32.checksum(input, offset: 0, count: 36)
        guard headerCRC == USBDebugDisplayWire.readUInt32(input, at: 36) else {
            return rejected(.headerChecksumMismatch, in: input)
        }
        let payloadCRC = USBDebugDisplayCRC32.checksum(
            input,
            offset: USBDebugDisplayProtocol.headerByteCount,
            count: Int(payloadByteCount)
        )
        guard payloadCRC == USBDebugDisplayWire.readUInt32(input, at: 28) else {
            return rejected(.payloadChecksumMismatch, in: input)
        }
        let sequence = USBDebugDisplayWire.readUInt32(input, at: 16)
        let frameID = USBDebugDisplayWire.readUInt64(input, at: 20)
        guard sequence != 0 else {
            return rejected(.zeroSequence, in: input)
        }
        let requiresFrameID = type == .fullFrameBegin
            || type == .damageFrameBegin || type == .frameChunk
            || type == .frameEnd
        guard requiresFrameID ? frameID != 0 : frameID == 0 else {
            return rejected(.invalidFrameID, in: input)
        }
        guard let message = decodePayload(
                  type: type,
                  input: input,
                  payloadByteCount: Int(payloadByteCount)
              )
        else {
            return rejected(.malformedPayload(type), in: input)
        }
        return .decoded(
            USBDebugDisplayDecodedPacket(
                sequence: sequence,
                frameID: frameID,
                message: message,
                encodedByteCount: packetByteCount
            )
        )
    }

    private static func decodePayload(
        type: USBDebugDisplayMessageType,
        input: UnsafeRawBufferPointer,
        payloadByteCount: Int
    ) -> USBDebugDisplayMessage? {
        let offset = USBDebugDisplayProtocol.headerByteCount
        switch type {
        case .hello:
            guard payloadByteCount == 16,
                  input[offset + 13] == 0,
                  USBDebugDisplayWire.readUInt16(input, at: offset + 14) == 0,
                  let role = USBDebugDisplayEndpointRole(
                      rawValue: input[offset + 12]
                  )
            else { return nil }
            guard let hello = USBDebugDisplayHello(
                      sessionID: USBDebugDisplayWire.readUInt64(input, at: offset),
                      minimumVersionMajor: input[offset + 8],
                      minimumVersionMinor: input[offset + 9],
                      maximumVersionMajor: input[offset + 10],
                      maximumVersionMinor: input[offset + 11],
                      role: role
                  )
            else { return nil }
            return .hello(hello)

        case .capabilities:
            guard payloadByteCount == 32,
                  let capabilities = USBDebugDisplayCapabilities(
                      sessionID: USBDebugDisplayWire.readUInt64(input, at: offset),
                      features: USBDebugDisplayCapabilityBits(
                          rawValue: USBDebugDisplayWire.readUInt32(
                              input,
                              at: offset + 8
                          )
                      ),
                      maximumPayloadByteCount: USBDebugDisplayWire.readUInt32(input, at: offset + 12),
                      maximumChunkDataByteCount: USBDebugDisplayWire.readUInt32(input, at: offset + 16),
                      maximumWidth: USBDebugDisplayWire.readUInt32(input, at: offset + 20),
                      maximumHeight: USBDebugDisplayWire.readUInt32(input, at: offset + 24),
                      pixelFormatMask: USBDebugDisplayWire.readUInt32(input, at: offset + 28)
                  )
            else { return nil }
            return .capabilities(capabilities)

        case .displayMode:
            guard payloadByteCount == 36,
                  USBDebugDisplayWire.readUInt32(input, at: offset + 32) == 0,
                  let format = USBDebugDisplayPixelFormat(
                      rawValue: USBDebugDisplayWire.readUInt32(
                          input,
                          at: offset + 12
                      )
                  ),
                  let mode = USBDebugDisplayMode(
                      width: USBDebugDisplayWire.readUInt32(input, at: offset),
                      height: USBDebugDisplayWire.readUInt32(input, at: offset + 4),
                      bytesPerRow: USBDebugDisplayWire.readUInt32(input, at: offset + 8),
                      pixelFormat: format,
                      scaleNumerator: USBDebugDisplayWire.readUInt16(input, at: offset + 16),
                      scaleDenominator: USBDebugDisplayWire.readUInt16(input, at: offset + 18),
                      horizontalPixelsPerInchMilli: USBDebugDisplayWire.readUInt32(input, at: offset + 20),
                      verticalPixelsPerInchMilli: USBDebugDisplayWire.readUInt32(input, at: offset + 24),
                      refreshRateMilliHertz: USBDebugDisplayWire.readUInt32(input, at: offset + 28)
                  )
            else { return nil }
            return .displayMode(mode)

        case .fullFrameBegin:
            guard payloadByteCount == 16,
                  USBDebugDisplayWire.readUInt32(input, at: offset + 12) == 0
            else { return nil }
            let begin = USBDebugDisplayFullFrameBegin(
                totalDataByteCount: USBDebugDisplayWire.readUInt64(input, at: offset),
                chunkCount: USBDebugDisplayWire.readUInt32(input, at: offset + 8)
            )
            guard begin.totalDataByteCount != 0, begin.chunkCount != 0 else {
                return nil
            }
            return .fullFrameBegin(begin)

        case .damageFrameBegin:
            guard payloadByteCount == 32,
                  USBDebugDisplayWire.readUInt32(input, at: offset + 28) == 0,
                  let rectangle = USBDebugDisplayDamageRectangle(
                      x: USBDebugDisplayWire.readUInt32(input, at: offset),
                      y: USBDebugDisplayWire.readUInt32(input, at: offset + 4),
                      width: USBDebugDisplayWire.readUInt32(input, at: offset + 8),
                      height: USBDebugDisplayWire.readUInt32(input, at: offset + 12)
                  )
            else { return nil }
            let begin = USBDebugDisplayDamageFrameBegin(
                rectangle: rectangle,
                totalDataByteCount: USBDebugDisplayWire.readUInt64(input, at: offset + 16),
                chunkCount: USBDebugDisplayWire.readUInt32(input, at: offset + 24)
            )
            guard begin.totalDataByteCount != 0, begin.chunkCount != 0 else {
                return nil
            }
            return .damageFrameBegin(begin)

        case .frameChunk:
            guard payloadByteCount
                    > USBDebugDisplayProtocol.frameChunkPrefixByteCount
            else { return nil }
            let chunkDataByteCount = USBDebugDisplayWire.readUInt32(
                input,
                at: offset + 4
            )
            guard chunkDataByteCount != 0,
                  chunkDataByteCount
                    <= UInt32(
                        USBDebugDisplayProtocol.maximumChunkDataByteCount
                    ),
                  UInt64(chunkDataByteCount)
                    + UInt64(USBDebugDisplayProtocol.frameChunkPrefixByteCount)
                    == UInt64(payloadByteCount),
                  let base = input.baseAddress
            else { return nil }
            let chunk = USBDebugDisplayFrameChunk(
                chunkSequence: USBDebugDisplayWire.readUInt32(input, at: offset),
                offset: USBDebugDisplayWire.readUInt64(input, at: offset + 8),
                data: UnsafeRawBufferPointer(
                    start: base.advanced(by: offset + 16),
                    count: Int(chunkDataByteCount)
                )
            )
            guard chunk.chunkSequence != 0 else { return nil }
            return .frameChunk(chunk)

        case .frameEnd:
            guard payloadByteCount == 24,
                  USBDebugDisplayWire.readUInt64(input, at: offset + 16) == 0
            else { return nil }
            let end = USBDebugDisplayFrameEnd(
                chunkCount: USBDebugDisplayWire.readUInt32(input, at: offset),
                frameCRC32: USBDebugDisplayWire.readUInt32(input, at: offset + 4),
                totalDataByteCount: USBDebugDisplayWire.readUInt64(input, at: offset + 8)
            )
            guard end.chunkCount != 0, end.totalDataByteCount != 0 else {
                return nil
            }
            return .frameEnd(end)

        case .reset:
            guard payloadByteCount == 16,
                  USBDebugDisplayWire.readUInt16(input, at: offset + 6) == 0,
                  let reason = USBDebugDisplayResetReason(
                      rawValue: USBDebugDisplayWire.readUInt16(
                          input,
                          at: offset + 4
                      )
                  )
            else { return nil }
            return .reset(
                USBDebugDisplayReset(
                    generation: USBDebugDisplayWire.readUInt32(input, at: offset),
                    reason: reason,
                    previousSessionID: USBDebugDisplayWire.readUInt64(input, at: offset + 8)
                )
            )
        }
    }

    private static func rejected(
        _ rejection: USBDebugDisplayDecodeRejection,
        in input: UnsafeRawBufferPointer
    ) -> USBDebugDisplayDecodeResult {
        .rejected(
            rejection,
            recoveryDiscardByteCount: recoveryDiscardByteCount(in: input)
        )
    }

    /// Keeps at most the final three bytes, which may be a split magic prefix.
    private static func recoveryDiscardByteCount(
        in input: UnsafeRawBufferPointer
    ) -> Int {
        guard input.count > 1 else { return 1 }
        var offset = 1
        while offset + 4 <= input.count {
            if USBDebugDisplayWire.readUInt32(input, at: offset)
                == USBDebugDisplayProtocol.magic {
                return offset
            }
            offset += 1
        }
        return input.count > 3 ? input.count - 3 : 1
    }
}

struct USBDebugDisplayCRC32 {
    private var accumulator: UInt32 = .max

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var index = 0
        while index < bytes.count {
            var value = accumulator ^ UInt32(bytes[index])
            var bit = 0
            while bit < 8 {
                let mask = UInt32(0) &- (value & 1)
                value = value >> 1 ^ (0xedb8_8320 & mask)
                bit += 1
            }
            accumulator = value
            index += 1
        }
    }

    var value: UInt32 { accumulator ^ .max }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc = USBDebugDisplayCRC32()
        crc.update(bytes)
        return crc.value
    }

    static func checksum(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> UInt32 {
        guard count > 0, let base = bytes.baseAddress else {
            return checksum(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return checksum(
            UnsafeRawBufferPointer(
                start: base.advanced(by: offset),
                count: count
            )
        )
    }

    static func checksum(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int,
        count: Int
    ) -> UInt32 {
        guard count > 0, let base = bytes.baseAddress else {
            return checksum(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return checksum(
            UnsafeRawBufferPointer(
                start: base.advanced(by: offset),
                count: count
            )
        )
    }
}

enum USBDebugDisplayReceiverPhase: UInt8, Equatable {
    case awaitingHello
    case awaitingCapabilities
    case awaitingDisplayMode
    case ready
    case receivingFrame
    case awaitingReset
}

enum USBDebugDisplayUpdateKind: UInt8, Equatable {
    case fullFrame
    case damageRectangle
}

enum USBDebugDisplayReceiverEvent: Equatable {
    case helloAccepted
    case capabilitiesAccepted
    case displayModeAccepted
    case frameBegan(kind: USBDebugDisplayUpdateKind, frameID: UInt64)
    case chunkAccepted(frameID: UInt64, chunkSequence: UInt32)
    case frameCompleted(frameID: UInt64)
    case resetAccepted(generation: UInt32)
}

enum USBDebugDisplayReceiverRejection: Equatable {
    case resetRequired
    case unexpectedMessage(
        phase: USBDebugDisplayReceiverPhase,
        type: USBDebugDisplayMessageType
    )
    case sequenceMismatch(expected: UInt32, actual: UInt32)
    case sequenceExhausted
    case unsupportedVersion
    case wrongEndpointRole
    case sessionMismatch
    case requiredCapabilitiesMissing
    case unsupportedDisplayMode
    case frameIDNotIncreasing
    case invalidFrameByteCount(expected: UInt64, actual: UInt64)
    case invalidChunkCount
    case frameIDMismatch(expected: UInt64, actual: UInt64)
    case chunkSequenceMismatch(expected: UInt32, actual: UInt32)
    case chunkOffsetMismatch(expected: UInt64, actual: UInt64)
    case chunkTooLarge(maximum: UInt32, actual: Int)
    case chunkExceedsFrame
    case frameChecksumMismatch(expected: UInt32, actual: UInt32)
}

enum USBDebugDisplayReceiverResult: Equatable {
    case accepted(USBDebugDisplayReceiverEvent)
    case rejected(USBDebugDisplayReceiverRejection)
}

/// Strict semantic receiver for one diagnostic-display session. Any semantic
/// violation enters `awaitingReset`; only a valid reset can recover it.
struct USBDebugDisplayReceiver {
    private(set) var phase: USBDebugDisplayReceiverPhase = .awaitingHello
    private(set) var mode: USBDebugDisplayMode?

    private var sessionID: UInt64 = 0
    private var capabilities: USBDebugDisplayCapabilities?
    private var nextSequence: UInt32 = 1
    private var lastCompletedFrameID: UInt64 = 0
    private var activeFrameID: UInt64 = 0
    private var activeFrameByteCount: UInt64 = 0
    private var activeChunkCount: UInt32 = 0
    private var nextChunkSequence: UInt32 = 1
    private var nextChunkOffset: UInt64 = 0
    private var frameCRC = USBDebugDisplayCRC32()

    mutating func accept(
        _ packet: USBDebugDisplayDecodedPacket
    ) -> USBDebugDisplayReceiverResult {
        if case .reset(let reset) = packet.message {
            clearSession()
            return .accepted(.resetAccepted(generation: reset.generation))
        }
        guard phase != .awaitingReset else {
            return .rejected(.resetRequired)
        }
        guard packet.sequence == nextSequence else {
            return fail(
                .sequenceMismatch(
                    expected: nextSequence,
                    actual: packet.sequence
                )
            )
        }
        guard nextSequence != UInt32.max else {
            return fail(.sequenceExhausted)
        }

        let result: USBDebugDisplayReceiverResult
        switch packet.message {
        case .hello(let hello):
            guard phase == .awaitingHello else {
                return fail(unexpected(packet.message))
            }
            guard hello.supportsCurrentVersion else {
                return fail(.unsupportedVersion)
            }
            guard hello.role == .guest else { return fail(.wrongEndpointRole) }
            sessionID = hello.sessionID
            phase = .awaitingCapabilities
            result = .accepted(.helloAccepted)

        case .capabilities(let advertised):
            guard phase == .awaitingCapabilities else {
                return fail(unexpected(packet.message))
            }
            guard advertised.sessionID == sessionID else {
                return fail(.sessionMismatch)
            }
            guard advertised.features.contains(
                      USBDebugDisplayCapabilityBits.required
                  )
            else {
                return fail(.requiredCapabilitiesMissing)
            }
            capabilities = advertised
            phase = .awaitingDisplayMode
            result = .accepted(.capabilitiesAccepted)

        case .displayMode(let displayMode):
            guard phase == .awaitingDisplayMode,
                  let advertised = capabilities
            else {
                return fail(unexpected(packet.message))
            }
            guard displayMode.width <= advertised.maximumWidth,
                  displayMode.height <= advertised.maximumHeight,
                  advertised.supports(displayMode.pixelFormat)
            else {
                return fail(.unsupportedDisplayMode)
            }
            mode = displayMode
            phase = .ready
            result = .accepted(.displayModeAccepted)

        case .fullFrameBegin(let begin):
            guard phase == .ready, let displayMode = mode,
                  let advertised = capabilities
            else {
                return fail(unexpected(packet.message))
            }
            guard packet.frameID > lastCompletedFrameID else {
                return fail(.frameIDNotIncreasing)
            }
            guard begin.totalDataByteCount == displayMode.fullFrameByteCount else {
                return fail(
                    .invalidFrameByteCount(
                        expected: displayMode.fullFrameByteCount,
                        actual: begin.totalDataByteCount
                    )
                )
            }
            guard validChunkCount(
                      begin.chunkCount,
                      totalByteCount: begin.totalDataByteCount,
                      maximumChunkDataByteCount:
                        advertised.maximumChunkDataByteCount
                  )
            else { return fail(.invalidChunkCount) }
            beginFrame(
                id: packet.frameID,
                byteCount: begin.totalDataByteCount,
                chunkCount: begin.chunkCount
            )
            result = .accepted(
                .frameBegan(kind: .fullFrame, frameID: packet.frameID)
            )

        case .damageFrameBegin(let begin):
            guard phase == .ready, let displayMode = mode,
                  let advertised = capabilities
            else {
                return fail(unexpected(packet.message))
            }
            guard packet.frameID > lastCompletedFrameID else {
                return fail(.frameIDNotIncreasing)
            }
            guard begin.rectangle.fits(displayMode),
                  let expected = begin.rectangle.packedByteCount(
                      format: displayMode.pixelFormat
                  )
            else {
                return fail(.unsupportedDisplayMode)
            }
            guard begin.totalDataByteCount == expected else {
                return fail(
                    .invalidFrameByteCount(
                        expected: expected,
                        actual: begin.totalDataByteCount
                    )
                )
            }
            guard validChunkCount(
                      begin.chunkCount,
                      totalByteCount: begin.totalDataByteCount,
                      maximumChunkDataByteCount:
                        advertised.maximumChunkDataByteCount
                  )
            else { return fail(.invalidChunkCount) }
            beginFrame(
                id: packet.frameID,
                byteCount: begin.totalDataByteCount,
                chunkCount: begin.chunkCount
            )
            result = .accepted(
                .frameBegan(
                    kind: .damageRectangle,
                    frameID: packet.frameID
                )
            )

        case .frameChunk(let chunk):
            guard phase == .receivingFrame,
                  let advertised = capabilities
            else {
                return fail(unexpected(packet.message))
            }
            guard packet.frameID == activeFrameID else {
                return fail(
                    .frameIDMismatch(
                        expected: activeFrameID,
                        actual: packet.frameID
                    )
                )
            }
            guard chunk.chunkSequence == nextChunkSequence else {
                return fail(
                    .chunkSequenceMismatch(
                        expected: nextChunkSequence,
                        actual: chunk.chunkSequence
                    )
                )
            }
            guard chunk.offset == nextChunkOffset else {
                return fail(
                    .chunkOffsetMismatch(
                        expected: nextChunkOffset,
                        actual: chunk.offset
                    )
                )
            }
            guard chunk.data.count
                    <= Int(advertised.maximumChunkDataByteCount)
            else {
                return fail(
                    .chunkTooLarge(
                        maximum: advertised.maximumChunkDataByteCount,
                        actual: chunk.data.count
                    )
                )
            }
            let nextOffset = nextChunkOffset.addingReportingOverflow(
                UInt64(chunk.data.count)
            )
            guard !nextOffset.overflow,
                  nextOffset.partialValue <= activeFrameByteCount,
                  nextChunkSequence <= activeChunkCount
            else {
                return fail(.chunkExceedsFrame)
            }
            frameCRC.update(chunk.data)
            nextChunkOffset = nextOffset.partialValue
            nextChunkSequence &+= 1
            result = .accepted(
                .chunkAccepted(
                    frameID: packet.frameID,
                    chunkSequence: chunk.chunkSequence
                )
            )

        case .frameEnd(let end):
            guard phase == .receivingFrame else {
                return fail(unexpected(packet.message))
            }
            guard packet.frameID == activeFrameID else {
                return fail(
                    .frameIDMismatch(
                        expected: activeFrameID,
                        actual: packet.frameID
                    )
                )
            }
            guard end.chunkCount == activeChunkCount,
                  nextChunkSequence == activeChunkCount + 1
            else { return fail(.invalidChunkCount) }
            guard end.totalDataByteCount == activeFrameByteCount,
                  nextChunkOffset == activeFrameByteCount
            else {
                return fail(
                    .invalidFrameByteCount(
                        expected: activeFrameByteCount,
                        actual: end.totalDataByteCount
                    )
                )
            }
            guard end.frameCRC32 == frameCRC.value else {
                return fail(
                    .frameChecksumMismatch(
                        expected: frameCRC.value,
                        actual: end.frameCRC32
                    )
                )
            }
            let completedID = activeFrameID
            lastCompletedFrameID = completedID
            clearActiveFrame()
            phase = .ready
            result = .accepted(.frameCompleted(frameID: completedID))

        case .reset:
            return .rejected(.resetRequired)
        }

        nextSequence &+= 1
        return result
    }

    private mutating func beginFrame(
        id: UInt64,
        byteCount: UInt64,
        chunkCount: UInt32
    ) {
        activeFrameID = id
        activeFrameByteCount = byteCount
        activeChunkCount = chunkCount
        nextChunkSequence = 1
        nextChunkOffset = 0
        frameCRC = USBDebugDisplayCRC32()
        phase = .receivingFrame
    }

    private func validChunkCount(
        _ chunkCount: UInt32,
        totalByteCount: UInt64,
        maximumChunkDataByteCount: UInt32
    ) -> Bool {
        // UInt32.max cannot name a transfer because the receiver must express
        // the one-past-last sequence without wrapping it back to zero.
        guard chunkCount != 0, chunkCount != UInt32.max,
              maximumChunkDataByteCount != 0,
              UInt64(chunkCount) <= totalByteCount
        else { return false }
        let maximum = UInt64(maximumChunkDataByteCount)
        let minimumChunks = totalByteCount / maximum
            + (totalByteCount % maximum == 0 ? 0 : 1)
        return UInt64(chunkCount) >= minimumChunks
    }

    private func unexpected(
        _ message: USBDebugDisplayMessage
    ) -> USBDebugDisplayReceiverRejection {
        .unexpectedMessage(phase: phase, type: message.type)
    }

    private mutating func fail(
        _ rejection: USBDebugDisplayReceiverRejection
    ) -> USBDebugDisplayReceiverResult {
        clearActiveFrame()
        phase = .awaitingReset
        return .rejected(rejection)
    }

    private mutating func clearActiveFrame() {
        activeFrameID = 0
        activeFrameByteCount = 0
        activeChunkCount = 0
        nextChunkSequence = 1
        nextChunkOffset = 0
        frameCRC = USBDebugDisplayCRC32()
    }

    private mutating func clearSession() {
        phase = .awaitingHello
        mode = nil
        sessionID = 0
        capabilities = nil
        nextSequence = 1
        lastCompletedFrameID = 0
        clearActiveFrame()
    }
}

private enum USBDebugDisplayWire {
    static func writeUInt16(
        _ value: UInt16,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    static func writeUInt32(
        _ value: UInt32,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    static func writeUInt64(
        _ value: UInt64,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeUInt32(UInt32(truncatingIfNeeded: value), to: bytes, at: offset)
        writeUInt32(
            UInt32(truncatingIfNeeded: value >> 32),
            to: bytes,
            at: offset + 4
        )
    }

    static func readUInt16(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func readUInt32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    static func readUInt64(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        UInt64(readUInt32(bytes, at: offset))
            | UInt64(readUInt32(bytes, at: offset + 4)) << 32
    }

    static func readUInt32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        onlyIfAvailable: Bool
    ) -> UInt32? {
        guard onlyIfAvailable, offset >= 0, offset + 4 <= bytes.count else {
            return nil
        }
        return readUInt32(bytes, at: offset)
    }
}
