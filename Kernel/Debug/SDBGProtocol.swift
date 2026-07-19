/// Transport-neutral, allocation-free SwiftOS debug protocol (SDBG) v1.
///
/// All integers are little-endian. The CRC covers bytes 0..<36 followed by
/// the payload; the CRC field itself is not included. The envelope deliberately
/// contains no USB, UART, or network concepts so a transport only has to carry
/// an ordered byte stream.
enum SDBGProtocol {
    static let magic: UInt32 = 0x4742_4453 // "SDBG" in wire byte order.
    static let versionMajor: UInt8 = 1
    static let versionMinor: UInt8 = 0
    static let headerByteCount = 40
    static let crcCoveredHeaderByteCount = 36
    static let maximumPayloadByteCount = 64 * 1_024
    static let maximumFrameByteCount = headerByteCount
        + maximumPayloadByteCount
}

enum SDBGMessageKind: UInt8, Equatable {
    case hello = 1
    case capabilities = 2
    case request = 3
    case response = 4
    case event = 5
    case logChunk = 6
}

struct SDBGMessageFlags: RawRepresentable, Equatable {
    let rawValue: UInt8

    static let none = Self(rawValue: 0)
    static let moreFragments = Self(rawValue: 1 << 0)
    static let error = Self(rawValue: 1 << 1)
    static let supportedMask: UInt8 = moreFragments.rawValue | error.rawValue

    func contains(_ flag: Self) -> Bool {
        rawValue & flag.rawValue == flag.rawValue
    }
}

/// Full 128-bit identity of one booted debug session.
struct SDBGBootSessionID: Equatable {
    let high: UInt64
    let low: UInt64

    var isZero: Bool { high == 0 && low == 0 }
}

struct SDBGEnvelope: Equatable {
    let kind: SDBGMessageKind
    let flags: SDBGMessageFlags
    /// Changes on every boot and identifies the live kernel debug session.
    let bootSessionID: SDBGBootSessionID
    /// Nonzero only for request/response messages.
    let requestID: UInt64
}

struct SDBGDecodedFrame {
    let envelope: SDBGEnvelope
    let payload: UnsafeRawBufferPointer
    let encodedByteCount: Int
}

enum SDBGSemanticRejection: Equatable {
    case zeroBootSessionID
    case missingRequestID
    case unexpectedRequestID
    case unsupportedFlags(rawValue: UInt8)
    case flagsNotAllowed(kind: SDBGMessageKind, rawValue: UInt8)
}

enum SDBGEnvelopeValidator {
    static func validate(
        kind: SDBGMessageKind,
        flags: SDBGMessageFlags,
        bootSessionID: SDBGBootSessionID,
        requestID: UInt64
    ) -> SDBGSemanticRejection? {
        guard !bootSessionID.isZero else { return .zeroBootSessionID }
        guard flags.rawValue & ~SDBGMessageFlags.supportedMask == 0 else {
            return .unsupportedFlags(rawValue: flags.rawValue)
        }

        switch kind {
        case .request, .response:
            guard requestID != 0 else { return .missingRequestID }
        case .hello, .capabilities, .event, .logChunk:
            guard requestID == 0 else { return .unexpectedRequestID }
        }

        switch kind {
        case .hello, .capabilities, .request:
            guard flags == .none else {
                return .flagsNotAllowed(kind: kind, rawValue: flags.rawValue)
            }
        case .response:
            break
        case .event, .logChunk:
            guard !flags.contains(.error) else {
                return .flagsNotAllowed(kind: kind, rawValue: flags.rawValue)
            }
        }
        return nil
    }
}

enum SDBGEncodeRejection: Equatable {
    case invalidPayload
    case payloadTooLarge(requested: Int, maximum: Int)
    case invalidEnvelope(SDBGSemanticRejection)
    case outputBufferTooSmall(required: Int, available: Int)
}

enum SDBGEncodeResult: Equatable {
    case encoded(byteCount: Int)
    case rejected(SDBGEncodeRejection)
}

enum SDBGFrameEncoder {
    static func encode(
        envelope: SDBGEnvelope,
        payload: UnsafeRawBufferPointer,
        into output: UnsafeMutableRawBufferPointer
    ) -> SDBGEncodeResult {
        guard payload.count == 0 || payload.baseAddress != nil else {
            return .rejected(.invalidPayload)
        }
        guard payload.count <= SDBGProtocol.maximumPayloadByteCount else {
            return .rejected(
                .payloadTooLarge(
                    requested: payload.count,
                    maximum: SDBGProtocol.maximumPayloadByteCount
                )
            )
        }
        if let rejection = SDBGEnvelopeValidator.validate(
            kind: envelope.kind,
            flags: envelope.flags,
            bootSessionID: envelope.bootSessionID,
            requestID: envelope.requestID
        ) {
            return .rejected(.invalidEnvelope(rejection))
        }

        let frameByteCount = SDBGProtocol.headerByteCount + payload.count
        guard output.count >= frameByteCount else {
            return .rejected(
                .outputBufferTooSmall(
                    required: frameByteCount,
                    available: output.count
                )
            )
        }

        SDBGWire.writeUInt32(SDBGProtocol.magic, to: output, at: 0)
        output[4] = SDBGProtocol.versionMajor
        output[5] = SDBGProtocol.versionMinor
        output[6] = envelope.kind.rawValue
        output[7] = envelope.flags.rawValue
        SDBGWire.writeUInt64(envelope.bootSessionID.high, to: output, at: 8)
        SDBGWire.writeUInt64(envelope.bootSessionID.low, to: output, at: 16)
        SDBGWire.writeUInt64(envelope.requestID, to: output, at: 24)
        SDBGWire.writeUInt32(UInt32(payload.count), to: output, at: 32)
        SDBGWire.writeUInt32(0, to: output, at: 36)

        var index = 0
        while index < payload.count {
            output[SDBGProtocol.headerByteCount + index] = payload[index]
            index += 1
        }

        let encodedBytes = UnsafeRawBufferPointer(
            start: output.baseAddress,
            count: frameByteCount
        )
        var crc = SDBGCRC32()
        crc.update(
            encodedBytes,
            offset: 0,
            count: SDBGProtocol.crcCoveredHeaderByteCount
        )
        crc.update(
            encodedBytes,
            offset: SDBGProtocol.headerByteCount,
            count: payload.count
        )
        SDBGWire.writeUInt32(crc.value, to: output, at: 36)
        return .encoded(byteCount: frameByteCount)
    }
}

enum SDBGWire {
    static func readUInt32(
        _ input: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(input[offset])
            | (UInt32(input[offset + 1]) << 8)
            | (UInt32(input[offset + 2]) << 16)
            | (UInt32(input[offset + 3]) << 24)
    }

    static func readUInt64(
        _ input: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        UInt64(readUInt32(input, at: offset))
            | (UInt64(readUInt32(input, at: offset + 4)) << 32)
    }

    static func writeUInt32(
        _ value: UInt32,
        to output: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        output[offset] = UInt8(truncatingIfNeeded: value)
        output[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        output[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        output[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    static func writeUInt64(
        _ value: UInt64,
        to output: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeUInt32(UInt32(truncatingIfNeeded: value), to: output, at: offset)
        writeUInt32(
            UInt32(truncatingIfNeeded: value >> 32),
            to: output,
            at: offset + 4
        )
    }
}

/// Table-free IEEE CRC-32, suitable for the freestanding kernel.
struct SDBGCRC32 {
    private var state: UInt32 = 0xffff_ffff

    var value: UInt32 { state ^ 0xffff_ffff }

    mutating func update(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int = 0,
        count: Int
    ) {
        guard offset >= 0,
              count >= 0,
              offset <= bytes.count,
              count <= bytes.count - offset
        else { return }

        var index = 0
        while index < count {
            state ^= UInt32(bytes[offset + index])
            var bit = 0
            while bit < 8 {
                let mask = UInt32(bitPattern: -Int32(state & 1))
                state = (state >> 1) ^ (0xedb8_8320 & mask)
                bit += 1
            }
            index += 1
        }
    }
}
