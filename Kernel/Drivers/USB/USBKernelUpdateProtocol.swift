/// Board-neutral, allocation-free wire contract for staged software updates.
///
/// SUPD is intentionally distinct from the SDDP display stream. A USB gadget
/// may route it over a dedicated bulk endpoint or multiplex it on any reliable
/// byte transport without coupling this codec to DWC2, a board, or storage.
enum USBKernelUpdateProtocol {
    static let magic: UInt32 = 0x4450_5553 // "SUPD" in wire byte order.
    static let version: UInt8 = 1
    static let headerByteCount = 24
    static let dataPrefixByteCount = 16
    static let beginPayloadByteCount = 56
    static let commitPayloadByteCount = 40
    static let abortPayloadByteCount = 4
    static let statusPayloadByteCount = 20

    static let minimumChunkByteCount: UInt32 = 64
    static let maximumWireChunkByteCount: UInt32 = 4_096
    /// Leaves a complete DATA frame at 496 bytes, below one 512-byte HS packet.
    static let maximumAcceptedChunkByteCount: UInt32 = 456
    static let maximumPayloadByteCount = dataPrefixByteCount
        + Int(maximumWireChunkByteCount)
    static let maximumPacketByteCount = headerByteCount
        + maximumPayloadByteCount
    static let maximumArtifactByteCount: UInt64 = 512 * 1_024 * 1_024
}

enum USBKernelUpdateMessageKind: UInt8, Equatable {
    case begin = 1
    case data = 2
    case commit = 3
    case abort = 4
    case status = 5
}

enum USBKernelUpdateArtifactKind: UInt16, Equatable {
    case kernelBootImage = 1
}

enum USBKernelUpdateTargetMachine: UInt16, Equatable {
    case raspberryPi5 = 1
    case qemuVirtAArch64 = 2
}

enum USBKernelUpdateStatusPhase: UInt8, Equatable {
    case idle = 0
    case receiving = 1
    case verifying = 2
    case committed = 3
    case rejected = 4
}

struct USBKernelUpdateStatusCode: RawRepresentable, Equatable {
    let rawValue: UInt16

    static let ready = Self(rawValue: 0)
    static let accepted = Self(rawValue: 1)
    static let progress = Self(rawValue: 2)
    static let verified = Self(rawValue: 3)
    static let committed = Self(rawValue: 4)

    static let malformedFrame = Self(rawValue: 0x0100)
    static let unsupportedVersion = Self(rawValue: 0x0101)
    static let unsupportedTarget = Self(rawValue: 0x0102)
    static let invalidOffset = Self(rawValue: 0x0103)
    static let checksumMismatch = Self(rawValue: 0x0104)
    static let storageFailure = Self(rawValue: 0x0105)
    static let busy = Self(rawValue: 0x0106)
    static let aborted = Self(rawValue: 0x0107)

    var isFailure: Bool { rawValue >= 0x0100 }
}

struct USBKernelUpdateBegin: Equatable {
    let artifactKind: USBKernelUpdateArtifactKind
    let targetMachine: USBKernelUpdateTargetMachine
    let totalLength: UInt64
    let chunkByteCount: UInt32
    let totalChunkCount: UInt32
    let sha256: USBKernelUpdateSHA256Digest
    let imageCRC32: UInt32
}

struct USBKernelUpdateData {
    let offset: UInt64
    let bytes: UnsafeRawBufferPointer
}

struct USBKernelUpdateCommit: Equatable {
    let totalLength: UInt64
    let sha256: USBKernelUpdateSHA256Digest
}

struct USBKernelUpdateAbort: Equatable {
    let reason: UInt32
}

struct USBKernelUpdateStatus: Equatable {
    let code: USBKernelUpdateStatusCode
    let phase: USBKernelUpdateStatusPhase
    let flags: UInt8
    let nextOffset: UInt64
    let acceptedChunkByteCount: UInt32
    let detail: UInt32

    init(
        code: USBKernelUpdateStatusCode,
        phase: USBKernelUpdateStatusPhase,
        flags: UInt8 = 0,
        nextOffset: UInt64,
        acceptedChunkByteCount: UInt32,
        detail: UInt32
    ) {
        self.code = code
        self.phase = phase
        self.flags = flags
        self.nextOffset = nextOffset
        self.acceptedChunkByteCount = acceptedChunkByteCount
        self.detail = detail
    }
}

enum USBKernelUpdateMessage {
    case begin(USBKernelUpdateBegin)
    case data(USBKernelUpdateData)
    case commit(USBKernelUpdateCommit)
    case abort(USBKernelUpdateAbort)
    case status(USBKernelUpdateStatus)

    var kind: USBKernelUpdateMessageKind {
        switch self {
        case .begin: return .begin
        case .data: return .data
        case .commit: return .commit
        case .abort: return .abort
        case .status: return .status
        }
    }
}

struct USBKernelUpdateDecodedPacket {
    let transferID: UInt32
    let sequence: UInt32
    let message: USBKernelUpdateMessage
    let encodedByteCount: Int
}

enum USBKernelUpdateEncodeRejection: Equatable {
    case zeroTransferID
    case nonzeroFlags
    case malformedMessage
    case payloadTooLarge(requested: Int, maximum: Int)
    case outputBufferTooSmall(required: Int, available: Int)
}

enum USBKernelUpdateEncodeResult: Equatable {
    case encoded(byteCount: Int)
    case rejected(USBKernelUpdateEncodeRejection)
}

enum USBKernelUpdatePacketEncoder {
    static func encode(
        _ message: USBKernelUpdateMessage,
        transferID: UInt32,
        sequence: UInt32,
        flags: UInt16 = 0,
        into output: UnsafeMutableRawBufferPointer
    ) -> USBKernelUpdateEncodeResult {
        guard transferID != 0 else { return .rejected(.zeroTransferID) }
        guard flags == 0 else { return .rejected(.nonzeroFlags) }
        guard let payloadByteCount = payloadByteCount(for: message) else {
            return .rejected(.malformedMessage)
        }
        guard payloadByteCount <= USBKernelUpdateProtocol.maximumPayloadByteCount
        else {
            return .rejected(
                .payloadTooLarge(
                    requested: payloadByteCount,
                    maximum: USBKernelUpdateProtocol.maximumPayloadByteCount
                )
            )
        }
        let packetByteCount = USBKernelUpdateProtocol.headerByteCount
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
                  at: USBKernelUpdateProtocol.headerByteCount
              )
        else { return .rejected(.malformedMessage) }

        USBKernelUpdateWire.writeUInt32(
            USBKernelUpdateProtocol.magic,
            to: output,
            at: 0
        )
        output[4] = USBKernelUpdateProtocol.version
        output[5] = message.kind.rawValue
        USBKernelUpdateWire.writeUInt16(flags, to: output, at: 6)
        USBKernelUpdateWire.writeUInt32(transferID, to: output, at: 8)
        USBKernelUpdateWire.writeUInt32(sequence, to: output, at: 12)
        USBKernelUpdateWire.writeUInt32(
            UInt32(payloadByteCount),
            to: output,
            at: 16
        )
        USBKernelUpdateWire.writeUInt32(0, to: output, at: 20)

        var crc = USBKernelUpdateCRC32()
        crc.update(output, offset: 0, count: 20)
        crc.update(
            output,
            offset: USBKernelUpdateProtocol.headerByteCount,
            count: payloadByteCount
        )
        USBKernelUpdateWire.writeUInt32(crc.value, to: output, at: 20)
        return .encoded(byteCount: packetByteCount)
    }

    private static func payloadByteCount(
        for message: USBKernelUpdateMessage
    ) -> Int? {
        switch message {
        case .begin:
            return USBKernelUpdateProtocol.beginPayloadByteCount
        case .data(let data):
            guard data.bytes.count > 0,
                  data.bytes.count
                    <= Int(USBKernelUpdateProtocol.maximumWireChunkByteCount)
            else { return nil }
            return USBKernelUpdateProtocol.dataPrefixByteCount
                + data.bytes.count
        case .commit:
            return USBKernelUpdateProtocol.commitPayloadByteCount
        case .abort:
            return USBKernelUpdateProtocol.abortPayloadByteCount
        case .status:
            return USBKernelUpdateProtocol.statusPayloadByteCount
        }
    }

    private static func encodePayload(
        _ message: USBKernelUpdateMessage,
        into output: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> Bool {
        switch message {
        case .begin(let begin):
            guard valid(begin: begin) else { return false }
            USBKernelUpdateWire.writeUInt16(
                begin.artifactKind.rawValue,
                to: output,
                at: offset
            )
            USBKernelUpdateWire.writeUInt16(
                begin.targetMachine.rawValue,
                to: output,
                at: offset + 2
            )
            USBKernelUpdateWire.writeUInt64(
                begin.totalLength,
                to: output,
                at: offset + 4
            )
            USBKernelUpdateWire.writeUInt32(
                begin.chunkByteCount,
                to: output,
                at: offset + 12
            )
            USBKernelUpdateWire.writeUInt32(
                begin.totalChunkCount,
                to: output,
                at: offset + 16
            )
            guard begin.sha256.write(to: output, at: offset + 20) else {
                return false
            }
            USBKernelUpdateWire.writeUInt32(
                begin.imageCRC32,
                to: output,
                at: offset + 52
            )

        case .data(let data):
            USBKernelUpdateWire.writeUInt64(data.offset, to: output, at: offset)
            USBKernelUpdateWire.writeUInt32(
                UInt32(data.bytes.count),
                to: output,
                at: offset + 8
            )
            USBKernelUpdateWire.writeUInt32(0, to: output, at: offset + 12)
            guard copy(
                      data.bytes,
                      into: output,
                      at: offset + USBKernelUpdateProtocol.dataPrefixByteCount
                  )
            else { return false }

        case .commit(let commit):
            guard commit.totalLength != 0 else { return false }
            USBKernelUpdateWire.writeUInt64(
                commit.totalLength,
                to: output,
                at: offset
            )
            guard commit.sha256.write(to: output, at: offset + 8) else {
                return false
            }

        case .abort(let abort):
            USBKernelUpdateWire.writeUInt32(abort.reason, to: output, at: offset)

        case .status(let status):
            guard status.flags == 0 else { return false }
            USBKernelUpdateWire.writeUInt16(
                status.code.rawValue,
                to: output,
                at: offset
            )
            output[offset + 2] = status.phase.rawValue
            output[offset + 3] = status.flags
            USBKernelUpdateWire.writeUInt64(
                status.nextOffset,
                to: output,
                at: offset + 4
            )
            USBKernelUpdateWire.writeUInt32(
                status.acceptedChunkByteCount,
                to: output,
                at: offset + 12
            )
            USBKernelUpdateWire.writeUInt32(
                status.detail,
                to: output,
                at: offset + 16
            )
        }
        return true
    }

    private static func valid(begin: USBKernelUpdateBegin) -> Bool {
        guard begin.totalLength != 0,
              begin.totalLength
                <= USBKernelUpdateProtocol.maximumArtifactByteCount,
              begin.chunkByteCount
                >= USBKernelUpdateProtocol.minimumChunkByteCount,
              begin.chunkByteCount
                <= USBKernelUpdateProtocol.maximumWireChunkByteCount
        else { return false }
        return begin.totalChunkCount == chunkCount(
            totalLength: begin.totalLength,
            chunkByteCount: begin.chunkByteCount
        )
    }

    private static func chunkCount(
        totalLength: UInt64,
        chunkByteCount: UInt32
    ) -> UInt32? {
        let chunk = UInt64(chunkByteCount)
        let count = totalLength / chunk
            + (totalLength % chunk == 0 ? 0 : 1)
        return count > 0 && count <= UInt64(UInt32.max)
            ? UInt32(count) : nil
    }

    private static func copy(
        _ source: UnsafeRawBufferPointer,
        into output: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> Bool {
        guard offset >= 0, offset <= output.count,
              source.count <= output.count - offset
        else { return false }
        var index = 0
        while index < source.count {
            output[offset + index] = source[index]
            index += 1
        }
        return true
    }
}

enum USBKernelUpdateDecodeRejection: Equatable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownMessageKind(UInt8)
    case nonzeroFlags(UInt16)
    case zeroTransferID
    case payloadTooLarge(requested: UInt32, maximum: Int)
    case packetChecksumMismatch(expected: UInt32, actual: UInt32)
    case malformedPayload(USBKernelUpdateMessageKind)
}

enum USBKernelUpdateDecodeResult {
    case decoded(USBKernelUpdateDecodedPacket)
    case needMoreBytes(requiredTotalByteCount: Int)
    case rejected(
        USBKernelUpdateDecodeRejection,
        recoveryDiscardByteCount: Int
    )
}

enum USBKernelUpdatePacketDecoder {
    static func decodePrefix(
        _ input: UnsafeRawBufferPointer
    ) -> USBKernelUpdateDecodeResult {
        guard input.count >= 4 else {
            return .needMoreBytes(requiredTotalByteCount: 4)
        }
        guard USBKernelUpdateWire.readUInt32(input, at: 0)
                == USBKernelUpdateProtocol.magic
        else { return rejected(.invalidMagic, in: input) }
        guard input.count >= USBKernelUpdateProtocol.headerByteCount else {
            return .needMoreBytes(
                requiredTotalByteCount: USBKernelUpdateProtocol.headerByteCount
            )
        }
        guard input[4] == USBKernelUpdateProtocol.version else {
            return rejected(.unsupportedVersion(input[4]), in: input)
        }
        guard let kind = USBKernelUpdateMessageKind(rawValue: input[5]) else {
            return rejected(.unknownMessageKind(input[5]), in: input)
        }
        let flags = USBKernelUpdateWire.readUInt16(input, at: 6)
        guard flags == 0 else {
            return rejected(.nonzeroFlags(flags), in: input)
        }
        let transferID = USBKernelUpdateWire.readUInt32(input, at: 8)
        guard transferID != 0 else {
            return rejected(.zeroTransferID, in: input)
        }
        let payloadByteCount = USBKernelUpdateWire.readUInt32(input, at: 16)
        guard payloadByteCount
                <= UInt32(USBKernelUpdateProtocol.maximumPayloadByteCount)
        else {
            return rejected(
                .payloadTooLarge(
                    requested: payloadByteCount,
                    maximum: USBKernelUpdateProtocol.maximumPayloadByteCount
                ),
                in: input
            )
        }
        let packetByteCount = USBKernelUpdateProtocol.headerByteCount
            + Int(payloadByteCount)
        guard input.count >= packetByteCount else {
            return .needMoreBytes(requiredTotalByteCount: packetByteCount)
        }

        var crc = USBKernelUpdateCRC32()
        crc.update(input, offset: 0, count: 20)
        crc.update(
            input,
            offset: USBKernelUpdateProtocol.headerByteCount,
            count: Int(payloadByteCount)
        )
        let expectedCRC = USBKernelUpdateWire.readUInt32(input, at: 20)
        guard crc.value == expectedCRC else {
            return rejected(
                .packetChecksumMismatch(
                    expected: expectedCRC,
                    actual: crc.value
                ),
                in: input
            )
        }
        guard let message = decodePayload(
                  kind: kind,
                  input: input,
                  payloadByteCount: Int(payloadByteCount)
              )
        else { return rejected(.malformedPayload(kind), in: input) }
        return .decoded(
            USBKernelUpdateDecodedPacket(
                transferID: transferID,
                sequence: USBKernelUpdateWire.readUInt32(input, at: 12),
                message: message,
                encodedByteCount: packetByteCount
            )
        )
    }

    private static func decodePayload(
        kind: USBKernelUpdateMessageKind,
        input: UnsafeRawBufferPointer,
        payloadByteCount: Int
    ) -> USBKernelUpdateMessage? {
        let offset = USBKernelUpdateProtocol.headerByteCount
        switch kind {
        case .begin:
            guard payloadByteCount
                    == USBKernelUpdateProtocol.beginPayloadByteCount,
                  let artifact = USBKernelUpdateArtifactKind(
                      rawValue: USBKernelUpdateWire.readUInt16(input, at: offset)
                  ),
                  let target = USBKernelUpdateTargetMachine(
                      rawValue: USBKernelUpdateWire.readUInt16(
                          input,
                          at: offset + 2
                      )
                  ),
                  let digest = digest(input, at: offset + 20)
            else { return nil }
            let begin = USBKernelUpdateBegin(
                artifactKind: artifact,
                targetMachine: target,
                totalLength: USBKernelUpdateWire.readUInt64(
                    input,
                    at: offset + 4
                ),
                chunkByteCount: USBKernelUpdateWire.readUInt32(
                    input,
                    at: offset + 12
                ),
                totalChunkCount: USBKernelUpdateWire.readUInt32(
                    input,
                    at: offset + 16
                ),
                sha256: digest,
                imageCRC32: USBKernelUpdateWire.readUInt32(
                    input,
                    at: offset + 52
                )
            )
            guard USBKernelUpdatePacketEncoder.validForDecoding(begin) else {
                return nil
            }
            return .begin(begin)

        case .data:
            guard payloadByteCount > USBKernelUpdateProtocol.dataPrefixByteCount,
                  USBKernelUpdateWire.readUInt32(input, at: offset + 12) == 0
            else { return nil }
            let byteCount = USBKernelUpdateWire.readUInt32(input, at: offset + 8)
            guard byteCount != 0,
                  byteCount
                    <= USBKernelUpdateProtocol.maximumWireChunkByteCount,
                  Int(byteCount) + USBKernelUpdateProtocol.dataPrefixByteCount
                    == payloadByteCount,
                  let base = input.baseAddress
            else { return nil }
            return .data(
                USBKernelUpdateData(
                    offset: USBKernelUpdateWire.readUInt64(input, at: offset),
                    bytes: UnsafeRawBufferPointer(
                        start: base.advanced(
                            by: offset
                                + USBKernelUpdateProtocol.dataPrefixByteCount
                        ),
                        count: Int(byteCount)
                    )
                )
            )

        case .commit:
            guard payloadByteCount
                    == USBKernelUpdateProtocol.commitPayloadByteCount,
                  let digest = digest(input, at: offset + 8)
            else { return nil }
            let commit = USBKernelUpdateCommit(
                totalLength: USBKernelUpdateWire.readUInt64(input, at: offset),
                sha256: digest
            )
            guard commit.totalLength != 0 else { return nil }
            return .commit(commit)

        case .abort:
            guard payloadByteCount
                    == USBKernelUpdateProtocol.abortPayloadByteCount
            else { return nil }
            return .abort(
                USBKernelUpdateAbort(
                    reason: USBKernelUpdateWire.readUInt32(input, at: offset)
                )
            )

        case .status:
            guard payloadByteCount
                    == USBKernelUpdateProtocol.statusPayloadByteCount,
                  let phase = USBKernelUpdateStatusPhase(
                      rawValue: input[offset + 2]
                  ),
                  input[offset + 3] == 0
            else { return nil }
            return .status(
                USBKernelUpdateStatus(
                    code: USBKernelUpdateStatusCode(
                        rawValue: USBKernelUpdateWire.readUInt16(
                            input,
                            at: offset
                        )
                    ),
                    phase: phase,
                    nextOffset: USBKernelUpdateWire.readUInt64(
                        input,
                        at: offset + 4
                    ),
                    acceptedChunkByteCount: USBKernelUpdateWire.readUInt32(
                        input,
                        at: offset + 12
                    ),
                    detail: USBKernelUpdateWire.readUInt32(
                        input,
                        at: offset + 16
                    )
                )
            )
        }
    }

    private static func digest(
        _ input: UnsafeRawBufferPointer,
        at offset: Int
    ) -> USBKernelUpdateSHA256Digest? {
        guard let base = input.baseAddress else { return nil }
        return USBKernelUpdateSHA256Digest(
            bytes: UnsafeRawBufferPointer(
                start: base.advanced(by: offset),
                count: 32
            )
        )
    }

    private static func rejected(
        _ rejection: USBKernelUpdateDecodeRejection,
        in input: UnsafeRawBufferPointer
    ) -> USBKernelUpdateDecodeResult {
        .rejected(
            rejection,
            recoveryDiscardByteCount: recoveryDiscardByteCount(in: input)
        )
    }

    /// Retains at most a split three-byte SUPD prefix for stream recovery.
    private static func recoveryDiscardByteCount(
        in input: UnsafeRawBufferPointer
    ) -> Int {
        guard input.count > 1 else { return 1 }
        var offset = 1
        while offset + 4 <= input.count {
            if USBKernelUpdateWire.readUInt32(input, at: offset)
                == USBKernelUpdateProtocol.magic {
                return offset
            }
            offset += 1
        }
        return input.count > 3 ? input.count - 3 : 1
    }
}

// The decoder shares the encoder's metadata validation without making the
// implementation detail public to the rest of the kernel.
private extension USBKernelUpdatePacketEncoder {
    static func validForDecoding(_ begin: USBKernelUpdateBegin) -> Bool {
        guard begin.totalLength != 0,
              begin.totalLength
                <= USBKernelUpdateProtocol.maximumArtifactByteCount,
              begin.chunkByteCount
                >= USBKernelUpdateProtocol.minimumChunkByteCount,
              begin.chunkByteCount
                <= USBKernelUpdateProtocol.maximumWireChunkByteCount
        else { return false }
        let chunk = UInt64(begin.chunkByteCount)
        let count = begin.totalLength / chunk
            + (begin.totalLength % chunk == 0 ? 0 : 1)
        return count > 0 && count <= UInt64(UInt32.max)
            && begin.totalChunkCount == UInt32(count)
    }
}

struct USBKernelUpdateCRC32 {
    private var accumulator: UInt32 = .max

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var index = 0
        while index < bytes.count {
            update(byte: bytes[index])
            index += 1
        }
    }

    mutating func update(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int,
        count: Int
    ) {
        guard count > 0, let base = bytes.baseAddress else { return }
        update(
            UnsafeRawBufferPointer(
                start: base.advanced(by: offset),
                count: count
            )
        )
    }

    mutating func update(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) {
        guard count > 0, let base = bytes.baseAddress else { return }
        update(
            UnsafeRawBufferPointer(
                start: base.advanced(by: offset),
                count: count
            )
        )
    }

    var value: UInt32 { accumulator ^ .max }

    private mutating func update(byte: UInt8) {
        var value = accumulator ^ UInt32(byte)
        var bit = 0
        while bit < 8 {
            let mask = UInt32(0) &- (value & 1)
            value = value >> 1 ^ (0xedb8_8320 & mask)
            bit += 1
        }
        accumulator = value
    }
}

private enum USBKernelUpdateWire {
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
}
