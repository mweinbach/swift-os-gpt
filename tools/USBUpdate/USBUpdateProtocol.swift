// SwiftOS USB update host protocol. This file intentionally depends only on
// the Swift standard library so its framing and validation can be tested
// without opening a device or loading a macOS framework.

enum USBUpdateLimits {
    static let headerByteCount = 24
    // The first activation contract stages a raw Raspberry Pi Image in a
    // dedicated 16 MiB RAM region. Keep host validation at that same boundary
    // so an image cannot pass locally and then fail only after transmission.
    static let maximumArtifactByteCount = 16 * 1_024 * 1_024
    static let maximumRuntimeImageByteCount = 32 * 1_024 * 1_024
    static let minimumChunkByteCount = 64
    static let maximumChunkByteCount = 4_096
    // 24-byte SUPD header + 16-byte DATA prefix + 456 bytes = 496 bytes,
    // fitting inside one 512-byte high-speed USB bulk packet.
    static let defaultChunkByteCount = 456
    static let dataPrefixByteCount = 16
    static let maximumPayloadByteCount = dataPrefixByteCount
        + maximumChunkByteCount
    static let maximumBufferedByteCount = 64 * 1_024
}

enum USBUpdateMessageKind: UInt8, Equatable {
    case begin = 1
    case data = 2
    case commit = 3
    case abort = 4
    case status = 5
}

enum USBUpdateArtifactKind: UInt16, Equatable {
    case kernelBootImage = 1
}

enum USBUpdateTargetMachine: UInt16, Equatable {
    case raspberryPi5 = 1
}

enum USBUpdateStatusPhase: UInt8, Equatable {
    case idle = 0
    case receiving = 1
    case verifying = 2
    case committed = 3
    case rejected = 4
}

struct USBUpdateStatusCode: RawRepresentable, Equatable {
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

struct USBUpdateFrame: Equatable {
    static let magic: [UInt8] = [0x53, 0x55, 0x50, 0x44] // "SUPD"
    static let version: UInt8 = 1

    let kind: USBUpdateMessageKind
    let flags: UInt16
    let transferID: UInt32
    let sequence: UInt32
    let payload: [UInt8]

    init(
        kind: USBUpdateMessageKind,
        flags: UInt16 = 0,
        transferID: UInt32,
        sequence: UInt32,
        payload: [UInt8]
    ) {
        self.kind = kind
        self.flags = flags
        self.transferID = transferID
        self.sequence = sequence
        self.payload = payload
    }

    func encoded() -> [UInt8] {
        var bytes = Self.magic
        bytes.append(Self.version)
        bytes.append(kind.rawValue)
        bytes.appendLittleEndian(flags)
        bytes.appendLittleEndian(transferID)
        bytes.appendLittleEndian(sequence)
        bytes.appendLittleEndian(UInt32(payload.count))
        let checksum = USBUpdateCRC32.checksum(parts: [bytes, payload])
        bytes.appendLittleEndian(checksum)
        bytes += payload
        return bytes
    }
}

enum USBUpdateFrameRejection: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    case nonzeroFlags(UInt16)
    case payloadTooLarge(UInt32)
    case checksumMismatch(expected: UInt32, actual: UInt32)

    var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "unsupported protocol version \(version)"
        case .unknownKind(let raw):
            return "unknown message kind \(raw)"
        case .nonzeroFlags(let flags):
            return "unsupported frame flags 0x\(String(flags, radix: 16))"
        case .payloadTooLarge(let count):
            return "payload length \(count) exceeds the protocol bound"
        case .checksumMismatch(let expected, let actual):
            return "frame CRC32 mismatch (wire \(hex(expected)), computed \(hex(actual)))"
        }
    }
}

enum USBUpdateStreamStep: Equatable {
    case needMoreBytes
    case frame(USBUpdateFrame)
    case rejected(USBUpdateFrameRejection)
}

/// Bounded resynchronizing decoder. It can share a CDC receive stream with the
/// diagnostic display protocol: bytes before the next SUPD magic are discarded
/// without allowing the buffer to grow beyond a fixed limit.
final class USBUpdateStreamDecoder {
    private var storage: [UInt8] = []

    var bufferedByteCount: Int { storage.count }

    func reset() {
        storage.removeAll(keepingCapacity: true)
    }

    func append(_ bytes: [UInt8]) {
        if bytes.count >= USBUpdateLimits.maximumBufferedByteCount {
            storage = Array(
                bytes.suffix(USBUpdateLimits.maximumBufferedByteCount)
            )
        } else {
            let overflow = storage.count + bytes.count
                - USBUpdateLimits.maximumBufferedByteCount
            if overflow > 0 {
                storage.removeFirst(overflow)
            }
            storage += bytes
        }
    }

    func next() -> USBUpdateStreamStep {
        guard alignToMagic() else { return .needMoreBytes }
        guard storage.count >= USBUpdateLimits.headerByteCount else {
            return .needMoreBytes
        }

        let version = storage[4]
        guard version == USBUpdateFrame.version else {
            storage.removeFirst()
            return .rejected(.unsupportedVersion(version))
        }
        guard let kind = USBUpdateMessageKind(rawValue: storage[5]) else {
            let raw = storage[5]
            storage.removeFirst()
            return .rejected(.unknownKind(raw))
        }
        let flags = storage.readUInt16LittleEndian(at: 6)
        guard flags == 0 else {
            storage.removeFirst()
            return .rejected(.nonzeroFlags(flags))
        }
        let payloadLength = storage.readUInt32LittleEndian(at: 16)
        guard payloadLength <= UInt32(USBUpdateLimits.maximumPayloadByteCount)
        else {
            storage.removeFirst()
            return .rejected(.payloadTooLarge(payloadLength))
        }
        let totalLength = USBUpdateLimits.headerByteCount + Int(payloadLength)
        guard storage.count >= totalLength else { return .needMoreBytes }

        let expectedCRC = storage.readUInt32LittleEndian(at: 20)
        let headerPrefix = Array(storage[0..<20])
        let payload = Array(
            storage[USBUpdateLimits.headerByteCount..<totalLength]
        )
        let actualCRC = USBUpdateCRC32.checksum(
            parts: [headerPrefix, payload]
        )
        guard expectedCRC == actualCRC else {
            storage.removeFirst()
            return .rejected(
                .checksumMismatch(expected: expectedCRC, actual: actualCRC)
            )
        }

        let frame = USBUpdateFrame(
            kind: kind,
            flags: flags,
            transferID: storage.readUInt32LittleEndian(at: 8),
            sequence: storage.readUInt32LittleEndian(at: 12),
            payload: payload
        )
        storage.removeFirst(totalLength)
        return .frame(frame)
    }

    private func alignToMagic() -> Bool {
        guard storage.count >= USBUpdateFrame.magic.count else {
            return false
        }
        if storage.starts(with: USBUpdateFrame.magic) { return true }

        var found: Int?
        if storage.count >= USBUpdateFrame.magic.count {
            for index in 1...(storage.count - USBUpdateFrame.magic.count) {
                if storage[index] == USBUpdateFrame.magic[0]
                    && storage[index + 1] == USBUpdateFrame.magic[1]
                    && storage[index + 2] == USBUpdateFrame.magic[2]
                    && storage[index + 3] == USBUpdateFrame.magic[3]
                {
                    found = index
                    break
                }
            }
        }
        if let found {
            storage.removeFirst(found)
            return true
        }

        var preserved = 0
        let maximumPrefix = min(
            USBUpdateFrame.magic.count - 1,
            storage.count
        )
        if maximumPrefix > 0 {
            for length in stride(from: maximumPrefix, through: 1, by: -1) {
                if Array(storage.suffix(length))
                    == Array(USBUpdateFrame.magic.prefix(length))
                {
                    preserved = length
                    break
                }
            }
        }
        if preserved == 0 {
            storage.removeAll(keepingCapacity: true)
        } else {
            storage = Array(storage.suffix(preserved))
        }
        return false
    }
}

struct USBUpdateBegin: Equatable {
    static let payloadByteCount = 56

    let artifactKind: USBUpdateArtifactKind
    let targetMachine: USBUpdateTargetMachine
    let totalLength: UInt64
    let chunkByteCount: UInt32
    let totalChunkCount: UInt32
    let sha256: [UInt8]
    let imageCRC32: UInt32

    func payload() -> [UInt8] {
        precondition(sha256.count == 32)
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(artifactKind.rawValue)
        bytes.appendLittleEndian(targetMachine.rawValue)
        bytes.appendLittleEndian(totalLength)
        bytes.appendLittleEndian(chunkByteCount)
        bytes.appendLittleEndian(totalChunkCount)
        bytes += sha256
        bytes.appendLittleEndian(imageCRC32)
        return bytes
    }
}

struct USBUpdateData: Equatable {
    let offset: UInt64
    let bytes: [UInt8]

    func payload() -> [UInt8] {
        precondition(bytes.count <= USBUpdateLimits.maximumChunkByteCount)
        var payload: [UInt8] = []
        payload.appendLittleEndian(offset)
        payload.appendLittleEndian(UInt32(bytes.count))
        payload.appendLittleEndian(UInt32(0))
        payload += bytes
        return payload
    }
}

struct USBUpdateCommit: Equatable {
    static let payloadByteCount = 40

    let totalLength: UInt64
    let sha256: [UInt8]

    func payload() -> [UInt8] {
        precondition(sha256.count == 32)
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(totalLength)
        bytes += sha256
        return bytes
    }
}

struct USBUpdateStatus: Equatable {
    static let payloadByteCount = 20

    let code: USBUpdateStatusCode
    let phase: USBUpdateStatusPhase
    let flags: UInt8
    let nextOffset: UInt64
    let acceptedChunkByteCount: UInt32
    let detail: UInt32

    init(
        code: USBUpdateStatusCode,
        phase: USBUpdateStatusPhase,
        flags: UInt8,
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

    init?(payload: [UInt8]) {
        guard payload.count == Self.payloadByteCount,
              let phase = USBUpdateStatusPhase(rawValue: payload[2])
        else { return nil }
        code = USBUpdateStatusCode(
            rawValue: payload.readUInt16LittleEndian(at: 0)
        )
        self.phase = phase
        flags = payload[3]
        nextOffset = payload.readUInt64LittleEndian(at: 4)
        acceptedChunkByteCount = payload.readUInt32LittleEndian(at: 12)
        detail = payload.readUInt32LittleEndian(at: 16)
    }

    func payload() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(code.rawValue)
        bytes.append(phase.rawValue)
        bytes.append(flags)
        bytes.appendLittleEndian(nextOffset)
        bytes.appendLittleEndian(acceptedChunkByteCount)
        bytes.appendLittleEndian(detail)
        return bytes
    }
}

enum USBUpdateArtifactValidationError: Error, Equatable,
    CustomStringConvertible
{
    case empty
    case tooLarge(Int)
    case headerTooShort(Int)
    case missingARM64ImageMagic
    case invalidEntryInstruction(UInt32)
    case invalidEntryOffset(Int64)
    case wrongTextOffset(UInt64)
    case declaredImageTooSmall(UInt64)
    case declaredImageTooLarge(UInt64)
    case unalignedDeclaredImageSize(UInt64)
    case unsupportedImageFlags(UInt64)
    case nonzeroReservedField(offset: Int, value: UInt64)
    case invalidChunkByteCount(Int)

    var description: String {
        switch self {
        case .empty:
            return "image is empty"
        case .tooLarge(let count):
            return "image is \(count) bytes; maximum is \(USBUpdateLimits.maximumArtifactByteCount)"
        case .headerTooShort(let count):
            return "image is \(count) bytes; the AArch64 Image header needs 64"
        case .missingARM64ImageMagic:
            return "image does not contain ARM64 Image magic at byte 56"
        case .invalidEntryInstruction(let instruction):
            return "image entry instruction \(hex(UInt64(instruction))) is not an AArch64 branch"
        case .invalidEntryOffset(let offset):
            return "image entry branch offset \(offset) is outside the raw image"
        case .wrongTextOffset(let offset):
            return "image text offset is \(hex(offset)); expected 0x80000"
        case .declaredImageTooSmall(let size):
            return "declared memory image size \(size) is smaller than the file"
        case .declaredImageTooLarge(let size):
            return "declared memory image size \(size) exceeds \(USBUpdateLimits.maximumRuntimeImageByteCount)"
        case .unalignedDeclaredImageSize(let size):
            return "declared memory image size \(size) is not 4 KiB aligned"
        case .unsupportedImageFlags(let flags):
            return "image flags \(hex(flags)) do not select little-endian 4 KiB pages"
        case .nonzeroReservedField(let offset, let value):
            return "reserved Image header field at byte \(offset) is \(hex(value))"
        case .invalidChunkByteCount(let count):
            return "chunk size \(count) is outside \(USBUpdateLimits.minimumChunkByteCount)...\(USBUpdateLimits.maximumChunkByteCount)"
        }
    }
}

struct USBUpdateArtifact: Equatable {
    let bytes: [UInt8]
    let chunkByteCount: Int
    let sha256: [UInt8]
    let imageCRC32: UInt32

    init(
        validatingRaspberryPi5Image bytes: [UInt8],
        chunkByteCount: Int = USBUpdateLimits.defaultChunkByteCount
    ) throws {
        guard !bytes.isEmpty else {
            throw USBUpdateArtifactValidationError.empty
        }
        guard bytes.count <= USBUpdateLimits.maximumArtifactByteCount else {
            throw USBUpdateArtifactValidationError.tooLarge(bytes.count)
        }
        guard bytes.count >= 64 else {
            throw USBUpdateArtifactValidationError.headerTooShort(bytes.count)
        }
        guard Array(bytes[56..<60]) == [0x41, 0x52, 0x4d, 0x64] else {
            throw USBUpdateArtifactValidationError.missingARM64ImageMagic
        }
        let instruction = bytes.readUInt32LittleEndian(at: 0)
        guard instruction & 0xfc00_0000 == 0x1400_0000 else {
            throw USBUpdateArtifactValidationError.invalidEntryInstruction(
                instruction
            )
        }
        let rawImmediate = Int64(instruction & 0x03ff_ffff)
        let signedImmediate = rawImmediate & (1 << 25) == 0
            ? rawImmediate : rawImmediate - (1 << 26)
        let entryOffset = signedImmediate * 4
        guard entryOffset >= 64,
              UInt64(entryOffset) < UInt64(bytes.count)
        else {
            throw USBUpdateArtifactValidationError.invalidEntryOffset(
                entryOffset
            )
        }
        let textOffset = bytes.readUInt64LittleEndian(at: 8)
        guard textOffset == 0x80000 else {
            throw USBUpdateArtifactValidationError.wrongTextOffset(textOffset)
        }
        let declaredSize = bytes.readUInt64LittleEndian(at: 16)
        guard declaredSize >= UInt64(bytes.count) else {
            throw USBUpdateArtifactValidationError.declaredImageTooSmall(
                declaredSize
            )
        }
        guard declaredSize <= UInt64(
                  USBUpdateLimits.maximumRuntimeImageByteCount
              )
        else {
            throw USBUpdateArtifactValidationError.declaredImageTooLarge(
                declaredSize
            )
        }
        guard declaredSize & 0xfff == 0 else {
            throw USBUpdateArtifactValidationError
                .unalignedDeclaredImageSize(declaredSize)
        }
        let flags = bytes.readUInt64LittleEndian(at: 24)
        guard flags == 0x02 else {
            throw USBUpdateArtifactValidationError.unsupportedImageFlags(flags)
        }
        for offset in stride(from: 32, through: 48, by: 8) {
            let reserved = bytes.readUInt64LittleEndian(at: offset)
            guard reserved == 0 else {
                throw USBUpdateArtifactValidationError.nonzeroReservedField(
                    offset: offset,
                    value: reserved
                )
            }
        }
        guard chunkByteCount >= USBUpdateLimits.minimumChunkByteCount,
              chunkByteCount <= USBUpdateLimits.maximumChunkByteCount
        else {
            throw USBUpdateArtifactValidationError.invalidChunkByteCount(
                chunkByteCount
            )
        }
        self.bytes = bytes
        self.chunkByteCount = chunkByteCount
        sha256 = USBUpdateSHA256.hash(bytes)
        imageCRC32 = USBUpdateCRC32.checksum(bytes)
    }

    var totalChunkCount: UInt32 {
        totalChunkCount(for: chunkByteCount)
    }

    func totalChunkCount(for transferChunkByteCount: Int) -> UInt32 {
        UInt32(
            (bytes.count + transferChunkByteCount - 1)
                / transferChunkByteCount
        )
    }

    /// Stable across host restarts so a reconnect can resume a staged image.
    var transferID: UInt32 {
        let derived = sha256.readUInt32LittleEndian(at: 0)
            ^ UInt32(truncatingIfNeeded: bytes.count)
        // Zero is reserved by the guest decoder as "no active transfer."
        return derived == 0 ? 1 : derived
    }

    func beginFrame() -> USBUpdateFrame {
        let begin = USBUpdateBegin(
            artifactKind: .kernelBootImage,
            targetMachine: .raspberryPi5,
            totalLength: UInt64(bytes.count),
            chunkByteCount: UInt32(chunkByteCount),
            totalChunkCount: totalChunkCount,
            sha256: sha256,
            imageCRC32: imageCRC32
        )
        return USBUpdateFrame(
            kind: .begin,
            transferID: transferID,
            sequence: 0,
            payload: begin.payload()
        )
    }

    func dataFrame(
        at offset: UInt64,
        chunkByteCount transferChunkByteCount: Int? = nil
    ) -> USBUpdateFrame? {
        let effectiveChunkByteCount = transferChunkByteCount ?? chunkByteCount
        guard offset < UInt64(bytes.count),
              effectiveChunkByteCount >= USBUpdateLimits.minimumChunkByteCount,
              effectiveChunkByteCount <= USBUpdateLimits.maximumChunkByteCount,
              offset % UInt64(effectiveChunkByteCount) == 0
        else { return nil }
        let lower = Int(offset)
        let upper = min(lower + effectiveChunkByteCount, bytes.count)
        let data = USBUpdateData(
            offset: offset,
            bytes: Array(bytes[lower..<upper])
        )
        let sequence = UInt32(offset / UInt64(effectiveChunkByteCount)) &+ 1
        return USBUpdateFrame(
            kind: .data,
            transferID: transferID,
            sequence: sequence,
            payload: data.payload()
        )
    }

    func commitFrame(chunkByteCount transferChunkByteCount: Int? = nil)
        -> USBUpdateFrame
    {
        let effectiveChunkByteCount = transferChunkByteCount ?? chunkByteCount
        let commit = USBUpdateCommit(
            totalLength: UInt64(bytes.count),
            sha256: sha256
        )
        return USBUpdateFrame(
            kind: .commit,
            transferID: transferID,
            sequence: totalChunkCount(for: effectiveChunkByteCount) &+ 1,
            payload: commit.payload()
        )
    }
}

enum USBUpdateStatusValidationError: Error, Equatable,
    CustomStringConvertible
{
    case notStatus
    case wrongTransferID(UInt32)
    case wrongSequence(UInt32)
    case malformedPayload
    case remoteFailure(code: UInt16, detail: UInt32)
    case impossibleOffset(UInt64)
    case unsupportedChunkByteCount(UInt32)
    case unexpectedCode(UInt16)

    var description: String {
        switch self {
        case .notStatus:
            return "response is not a status frame"
        case .wrongTransferID(let identifier):
            return "status belongs to transfer \(hex(identifier))"
        case .wrongSequence(let sequence):
            return "status echoes sequence \(sequence)"
        case .malformedPayload:
            return "status payload is malformed"
        case .remoteFailure(let code, let detail):
            return "device rejected update with code \(hex(code)), detail \(hex(detail))"
        case .impossibleOffset(let offset):
            return "device returned impossible resume offset \(offset)"
        case .unsupportedChunkByteCount(let count):
            return "device accepted unsupported chunk size \(count)"
        case .unexpectedCode(let code):
            return "device returned unexpected status code \(hex(code))"
        }
    }
}

extension USBUpdateArtifact {
    func validateStatus(
        _ frame: USBUpdateFrame,
        expectedNextOffset: UInt64? = nil,
        effectiveChunkByteCount: Int? = nil,
        commit: Bool = false
    ) throws -> USBUpdateStatus {
        guard frame.kind == .status else {
            throw USBUpdateStatusValidationError.notStatus
        }
        guard frame.transferID == transferID else {
            throw USBUpdateStatusValidationError.wrongTransferID(
                frame.transferID
            )
        }
        guard frame.sequence == 0 else {
            throw USBUpdateStatusValidationError.wrongSequence(frame.sequence)
        }
        guard let status = USBUpdateStatus(payload: frame.payload) else {
            throw USBUpdateStatusValidationError.malformedPayload
        }
        if status.code.isFailure || status.phase == .rejected {
            throw USBUpdateStatusValidationError.remoteFailure(
                code: status.code.rawValue,
                detail: status.detail
            )
        }
        let statusChunkByteCount = Int(status.acceptedChunkByteCount)
        let alignment: Int
        if let effectiveChunkByteCount {
            guard status.acceptedChunkByteCount == 0
                    || statusChunkByteCount == effectiveChunkByteCount
            else {
                throw USBUpdateStatusValidationError
                    .unsupportedChunkByteCount(status.acceptedChunkByteCount)
            }
            alignment = effectiveChunkByteCount
        } else if status.acceptedChunkByteCount == 0 {
            alignment = chunkByteCount
        } else {
            guard statusChunkByteCount >= USBUpdateLimits.minimumChunkByteCount,
                  statusChunkByteCount <= chunkByteCount
            else {
                throw USBUpdateStatusValidationError
                    .unsupportedChunkByteCount(status.acceptedChunkByteCount)
            }
            alignment = statusChunkByteCount
        }
        guard status.nextOffset <= UInt64(bytes.count),
              status.nextOffset == UInt64(bytes.count)
                || status.nextOffset % UInt64(alignment) == 0
        else {
            throw USBUpdateStatusValidationError.impossibleOffset(
                status.nextOffset
            )
        }
        if let expectedNextOffset,
           status.nextOffset != expectedNextOffset
        {
            throw USBUpdateStatusValidationError.impossibleOffset(
                status.nextOffset
            )
        }
        if commit {
            guard status.code == .committed, status.phase == .committed else {
                throw USBUpdateStatusValidationError.unexpectedCode(
                    status.code.rawValue
                )
            }
        } else {
            if status.code == .committed, status.phase == .committed,
               status.nextOffset == UInt64(bytes.count)
            {
                return status
            }
            let acceptedCodes: [USBUpdateStatusCode] = [
                .ready, .accepted, .progress, .verified,
            ]
            guard acceptedCodes.contains(status.code) else {
                throw USBUpdateStatusValidationError.unexpectedCode(
                    status.code.rawValue
                )
            }
        }
        return status
    }
}

enum USBUpdateCRC32 {
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        checksum(parts: [bytes])
    }

    static func checksum(parts: [[UInt8]]) -> UInt32 {
        var crc = UInt32.max
        for bytes in parts {
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    let mask = UInt32(bitPattern: -Int32(crc & 1))
                    crc = (crc >> 1) ^ (0xedb88320 & mask)
                }
            }
        }
        return ~crc
    }
}

/// Small dependency-free SHA-256 used to validate the complete update before
/// commit. It follows FIPS 180-4 and is deliberately usable by host tests.
enum USBUpdateSHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(input.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var words = [UInt32](repeating: 0, count: 64)
        for blockOffset in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let offset = blockOffset + index * 4
                words[index] = UInt32(message[offset]) << 24
                    | UInt32(message[offset + 1]) << 16
                    | UInt32(message[offset + 2]) << 8
                    | UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let first = rotateRight(words[index - 15], by: 7)
                    ^ rotateRight(words[index - 15], by: 18)
                    ^ (words[index - 15] >> 3)
                let second = rotateRight(words[index - 2], by: 17)
                    ^ rotateRight(words[index - 2], by: 19)
                    ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ first
                    &+ words[index - 7] &+ second
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]
            for index in 0..<64 {
                let sigma1 = rotateRight(e, by: 6)
                    ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ (~e & g)
                let temporary1 = h &+ sigma1 &+ choose
                    &+ constants[index] &+ words[index]
                let sigma0 = rotateRight(a, by: 2)
                    ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = sigma0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }

        var digest: [UInt8] = []
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32)
        -> UInt32
    {
        (value >> amount) | (value << (32 - amount))
    }
}

private extension Array where Element == UInt8 {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        appendLittleEndian(UInt32(truncatingIfNeeded: value))
        appendLittleEndian(UInt32(truncatingIfNeeded: value >> 32))
    }

    func readUInt16LittleEndian(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func readUInt32LittleEndian(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func readUInt64LittleEndian(at offset: Int) -> UInt64 {
        UInt64(readUInt32LittleEndian(at: offset))
            | UInt64(readUInt32LittleEndian(at: offset + 4)) << 32
    }
}

private func hex<T: FixedWidthInteger>(_ value: T) -> String {
    "0x" + String(value, radix: 16)
}
