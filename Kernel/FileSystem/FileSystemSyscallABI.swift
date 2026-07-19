/// Stable, pointer-free wire contract for EL0 filesystem calls.
///
/// User software passes `x0 = requestAddress`, `x1 = 64`, and
/// `x2 = resultAddress` to SVC number 32. Both records are explicitly
/// little-endian; their ABI does not depend on Swift enum or struct layout.
///
/// Request bytes:
/// - 0: magic u32, 4: version u16, 6: size u16
/// - 8: operation u16, 10: flags u16, 12: requested rights u16
/// - 14: reserved u16, 16...63: six u64 arguments
///
/// Operation arguments:
/// - open: path address, path byte count; requested rights is nonzero
/// - read/write: handle, offset, buffer address, buffer byte count
/// - stat/close: handle
/// - readDirectory: handle, cookie, name address, name capacity
///
/// Result bytes:
/// - 0: magic u32, 4: version u16, 6: size u16
/// - 8: operation u16, 10: payload kind u16, 12: status i32
/// - 16: detail u32, 20: reserved u32, 24...127: thirteen u64 values
///
/// Payload values:
/// - handle: token, granted rights, node kind
/// - transfer: transferred byte count
/// - metadata: volume, node, kind, size, links, generation, creation seconds,
///   creation nanoseconds, modification seconds, modification nanoseconds,
///   provider rights, handle rights, mount identifier
/// - directoryEntry: next cookie, name length, volume, node, kind
enum FileSystemSyscallABI {
    static let systemCallNumber: UInt64 = 32
    static let version: UInt16 = 1
    static let requestByteCount = 64
    static let resultByteCount = 128

    // Bytes spell `SFSQ` and `SFSR` in memory on AArch64.
    static let requestMagic: UInt32 = 0x5153_4653
    static let resultMagic: UInt32 = 0x5253_4653

    static let requestArgumentCount = 6
    static let resultValueCount = 13
}

enum FileSystemOperation: UInt16, Equatable {
    case open = 1
    case read = 2
    case write = 3
    case stat = 4
    case readDirectory = 5
    case close = 6
}

enum FileSystemResultPayload: UInt16, Equatable {
    case none = 0
    case handle = 1
    case transfer = 2
    case metadata = 3
    case directoryEntry = 4
    case directoryEnd = 5
}

/// Stable status values. Negative values are returned in `x0` (sign-extended)
/// and repeated in the fixed result record when its user range is writable.
enum FileSystemStatus: Int32, Equatable {
    case success = 0
    case invalidRequest = -1
    case unsupportedVersion = -2
    case unsupportedOperation = -3
    case invalidUserMemory = -4
    case invalidPath = -5
    case notMounted = -6
    case notFound = -7
    case notDirectory = -8
    case isDirectory = -9
    case alreadyExists = -10
    case noSpace = -11
    case readOnly = -12
    case invalidOffset = -13
    case corrupt = -14
    case unavailable = -15
    case ioFailure = -16
    case accessDenied = -17
    case invalidHandle = -18
    case staleHandle = -19
    case closedHandle = -20
    case handleTableFull = -21
    case bufferTooSmall = -22
    case overflow = -23
    case wrongNodeKind = -24
    case wrongProcess = -25
    case malformedBackendResult = -26

    var registerValue: UInt64 {
        UInt64(bitPattern: Int64(rawValue))
    }
}

/// Stable detail namespace. The status remains sufficient for control flow;
/// detail distinguishes policy and validation causes without exporting kernel
/// enum representations.
enum FileSystemStatusDetail: UInt32, Equatable {
    case none = 0

    case pathEmpty = 1
    case pathNotAbsolute = 2
    case pathInputTooLong = 3
    case pathOutputTooSmall = 4
    case pathTooManyComponents = 5
    case pathComponentTooLong = 6
    case pathTraversal = 7
    case pathSeparatorInName = 8
    case pathNUL = 9
    case pathControlByte = 10
    case pathInvalidUTF8 = 11

    case invalidPrincipal = 32
    case kernelOnlyVolume = 33
    case volumeMismatch = 34
    case nodeRoleMismatch = 35
    case deniedByRole = 36
    case deniedByMount = 37
    case deniedByNode = 38
    case missingDeviceCapability = 39
    case emptyRights = 40

    case handleInvalidSlot = 64
    case handleStaleGeneration = 65
    case handleClosed = 66
    case handleCorrupt = 67

    case providerNotFound = 96
    case providerNotDirectory = 97
    case providerIsDirectory = 98
    case providerAlreadyExists = 99
    case providerNoSpace = 100
    case providerReadOnly = 101
    case providerInvalidOffset = 102
    case providerCorrupt = 103
    case providerUnavailable = 104
    case providerIOFailure = 105
}

struct FileSystemRequest: Equatable {
    let operationRaw: UInt16
    let flags: UInt16
    let requestedAccessRaw: UInt16
    let reserved: UInt16
    let argument0: UInt64
    let argument1: UInt64
    let argument2: UInt64
    let argument3: UInt64
    let argument4: UInt64
    let argument5: UInt64

    var operation: FileSystemOperation? {
        FileSystemOperation(rawValue: operationRaw)
    }

    func argument(at index: Int) -> UInt64? {
        switch index {
        case 0: return argument0
        case 1: return argument1
        case 2: return argument2
        case 3: return argument3
        case 4: return argument4
        case 5: return argument5
        default: return nil
        }
    }
}

struct FileSystemResult {
    var operationRaw: UInt16 = 0
    var payload: FileSystemResultPayload = .none
    var status: FileSystemStatus = .success
    var detail: UInt32 = 0
    var value0: UInt64 = 0
    var value1: UInt64 = 0
    var value2: UInt64 = 0
    var value3: UInt64 = 0
    var value4: UInt64 = 0
    var value5: UInt64 = 0
    var value6: UInt64 = 0
    var value7: UInt64 = 0
    var value8: UInt64 = 0
    var value9: UInt64 = 0
    var value10: UInt64 = 0
    var value11: UInt64 = 0
    var value12: UInt64 = 0

    mutating func setValue(_ value: UInt64, at index: Int) -> Bool {
        switch index {
        case 0: value0 = value
        case 1: value1 = value
        case 2: value2 = value
        case 3: value3 = value
        case 4: value4 = value
        case 5: value5 = value
        case 6: value6 = value
        case 7: value7 = value
        case 8: value8 = value
        case 9: value9 = value
        case 10: value10 = value
        case 11: value11 = value
        case 12: value12 = value
        default: return false
        }
        return true
    }

    func value(at index: Int) -> UInt64? {
        switch index {
        case 0: return value0
        case 1: return value1
        case 2: return value2
        case 3: return value3
        case 4: return value4
        case 5: return value5
        case 6: return value6
        case 7: return value7
        case 8: return value8
        case 9: return value9
        case 10: return value10
        case 11: return value11
        case 12: return value12
        default: return nil
        }
    }
}

enum FileSystemRequestDecodeResult {
    case request(FileSystemRequest)
    case failure(FileSystemStatus)
}

/// Byte codec shared by the dispatcher and host ABI tests. It never binds user
/// memory to a Swift type and tolerates unaligned scratch buffers.
enum FileSystemSyscallCodec {
    static func decodeRequest(
        _ bytes: UnsafeRawBufferPointer
    ) -> FileSystemRequestDecodeResult {
        guard bytes.count == FileSystemSyscallABI.requestByteCount else {
            return .failure(.invalidRequest)
        }
        guard read32(bytes, at: 0) == FileSystemSyscallABI.requestMagic,
              read16(bytes, at: 6)
                == UInt16(FileSystemSyscallABI.requestByteCount)
        else { return .failure(.invalidRequest) }
        guard read16(bytes, at: 4) == FileSystemSyscallABI.version else {
            return .failure(.unsupportedVersion)
        }
        return .request(
            FileSystemRequest(
                operationRaw: read16(bytes, at: 8),
                flags: read16(bytes, at: 10),
                requestedAccessRaw: read16(bytes, at: 12),
                reserved: read16(bytes, at: 14),
                argument0: read64(bytes, at: 16),
                argument1: read64(bytes, at: 24),
                argument2: read64(bytes, at: 32),
                argument3: read64(bytes, at: 40),
                argument4: read64(bytes, at: 48),
                argument5: read64(bytes, at: 56)
            )
        )
    }

    static func encodeResult(
        _ result: FileSystemResult,
        into bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard bytes.count >= FileSystemSyscallABI.resultByteCount else {
            return false
        }
        zero(bytes, count: FileSystemSyscallABI.resultByteCount)
        write32(FileSystemSyscallABI.resultMagic, to: bytes, at: 0)
        write16(FileSystemSyscallABI.version, to: bytes, at: 4)
        write16(
            UInt16(FileSystemSyscallABI.resultByteCount),
            to: bytes,
            at: 6
        )
        write16(result.operationRaw, to: bytes, at: 8)
        write16(result.payload.rawValue, to: bytes, at: 10)
        write32(UInt32(bitPattern: result.status.rawValue), to: bytes, at: 12)
        write32(result.detail, to: bytes, at: 16)
        // Bytes 20...23 are reserved and remain zero.
        var index = 0
        while index < FileSystemSyscallABI.resultValueCount {
            write64(result.value(at: index)!, to: bytes, at: 24 + index * 8)
            index += 1
        }
        return true
    }

    static func encodeRequest(
        _ request: FileSystemRequest,
        into bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard bytes.count >= FileSystemSyscallABI.requestByteCount else {
            return false
        }
        zero(bytes, count: FileSystemSyscallABI.requestByteCount)
        write32(FileSystemSyscallABI.requestMagic, to: bytes, at: 0)
        write16(FileSystemSyscallABI.version, to: bytes, at: 4)
        write16(
            UInt16(FileSystemSyscallABI.requestByteCount),
            to: bytes,
            at: 6
        )
        write16(request.operationRaw, to: bytes, at: 8)
        write16(request.flags, to: bytes, at: 10)
        write16(request.requestedAccessRaw, to: bytes, at: 12)
        write16(request.reserved, to: bytes, at: 14)
        var index = 0
        while index < FileSystemSyscallABI.requestArgumentCount {
            write64(request.argument(at: index)!, to: bytes, at: 16 + index * 8)
            index += 1
        }
        return true
    }

    static func readEncodedResultStatus(
        _ bytes: UnsafeRawBufferPointer
    ) -> FileSystemStatus? {
        guard bytes.count >= FileSystemSyscallABI.resultByteCount,
              read32(bytes, at: 0) == FileSystemSyscallABI.resultMagic,
              read16(bytes, at: 4) == FileSystemSyscallABI.version,
              read16(bytes, at: 6)
                == UInt16(FileSystemSyscallABI.resultByteCount)
        else { return nil }
        return FileSystemStatus(rawValue: Int32(bitPattern: read32(bytes, at: 12)))
    }

    static func readEncodedResultValue(
        _ bytes: UnsafeRawBufferPointer,
        at index: Int
    ) -> UInt64? {
        guard index >= 0, index < FileSystemSyscallABI.resultValueCount,
              bytes.count >= FileSystemSyscallABI.resultByteCount
        else { return nil }
        return read64(bytes, at: 24 + index * 8)
    }

    static func readEncodedResultPayload(
        _ bytes: UnsafeRawBufferPointer
    ) -> FileSystemResultPayload? {
        guard bytes.count >= FileSystemSyscallABI.resultByteCount else {
            return nil
        }
        return FileSystemResultPayload(rawValue: read16(bytes, at: 10))
    }

    static func readEncodedResultDetail(
        _ bytes: UnsafeRawBufferPointer
    ) -> UInt32? {
        guard bytes.count >= FileSystemSyscallABI.resultByteCount else {
            return nil
        }
        return read32(bytes, at: 16)
    }

    private static func read16(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func read32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func read64(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        var index = 0
        while index < 8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
            index += 1
        }
        return value
    }

    private static func write16(
        _ value: UInt16,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func write32(
        _ value: UInt32,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        var index = 0
        while index < 4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
            index += 1
        }
    }

    private static func write64(
        _ value: UInt64,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        var index = 0
        while index < 8 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
            index += 1
        }
    }

    private static func zero(
        _ bytes: UnsafeMutableRawBufferPointer,
        count: Int
    ) {
        var index = 0
        while index < count {
            bytes[index] = 0
            index += 1
        }
    }
}
