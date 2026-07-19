/// Common, allocation-free primitives shared by the SwiftOS network codecs.
///
/// Multi-byte integer values are represented in host integers and serialized
/// in network byte order. All externally supplied spans are validated before
/// an indexed access is made.
enum NetworkWire {
    @inline(__always)
    static func contains(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int,
        count: Int
    ) -> Bool {
        guard offset >= 0,
              count >= 0,
              offset <= bytes.count,
              count <= bytes.count - offset
        else {
            return false
        }
        return count == 0 || bytes.baseAddress != nil
    }

    @inline(__always)
    static func contains(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> Bool {
        guard offset >= 0,
              count >= 0,
              offset <= bytes.count,
              count <= bytes.count - offset
        else {
            return false
        }
        return count == 0 || bytes.baseAddress != nil
    }

    @inline(__always)
    static func readUInt16BE(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16? {
        guard contains(bytes, offset: offset, count: 2) else { return nil }
        return UInt16(bytes[offset]) << 8
            | UInt16(bytes[offset + 1])
    }

    @inline(__always)
    static func readUInt32BE(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32? {
        guard contains(bytes, offset: offset, count: 4) else { return nil }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    @discardableResult
    @inline(__always)
    static func writeUInt16BE(
        _ value: UInt16,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> Bool {
        guard contains(bytes, offset: offset, count: 2) else { return false }
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
        return true
    }

    @discardableResult
    @inline(__always)
    static func writeUInt32BE(
        _ value: UInt32,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> Bool {
        guard contains(bytes, offset: offset, count: 4) else { return false }
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
        return true
    }

    @discardableResult
    static func copy(
        _ source: UnsafeRawBufferPointer,
        into destination: UnsafeMutableRawBufferPointer,
        at destinationOffset: Int
    ) -> Bool {
        guard contains(source, offset: 0, count: source.count),
              contains(
                  destination,
                  offset: destinationOffset,
                  count: source.count
              )
        else {
            return false
        }

        var index = 0
        while index < source.count {
            destination[destinationOffset + index] = source[index]
            index += 1
        }
        return true
    }

    @discardableResult
    static func zero(
        _ destination: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> Bool {
        guard contains(destination, offset: offset, count: count) else {
            return false
        }
        var index = 0
        while index < count {
            destination[offset + index] = 0
            index += 1
        }
        return true
    }

    static func view(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int,
        count: Int
    ) -> UnsafeRawBufferPointer? {
        guard contains(bytes, offset: offset, count: count) else { return nil }
        if count == 0 {
            return UnsafeRawBufferPointer(start: nil, count: 0)
        }
        guard let baseAddress = bytes.baseAddress else { return nil }
        return UnsafeRawBufferPointer(
            start: baseAddress.advanced(by: offset),
            count: count
        )
    }
}

/// Six-octet IEEE 802 hardware address with no storage allocation.
struct MACAddress: Equatable {
    static let byteCount = 6

    let octet0: UInt8
    let octet1: UInt8
    let octet2: UInt8
    let octet3: UInt8
    let octet4: UInt8
    let octet5: UInt8

    static let zero = MACAddress(0, 0, 0, 0, 0, 0)
    static let broadcast = MACAddress(
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    )

    init(
        _ octet0: UInt8,
        _ octet1: UInt8,
        _ octet2: UInt8,
        _ octet3: UInt8,
        _ octet4: UInt8,
        _ octet5: UInt8
    ) {
        self.octet0 = octet0
        self.octet1 = octet1
        self.octet2 = octet2
        self.octet3 = octet3
        self.octet4 = octet4
        self.octet5 = octet5
    }

    var isZero: Bool { self == .zero }
    var isBroadcast: Bool { self == .broadcast }
    var isMulticast: Bool { octet0 & 1 != 0 }
    var isUnicast: Bool { !isZero && !isMulticast }

    static func decode(
        from bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> MACAddress? {
        guard NetworkWire.contains(bytes, offset: offset, count: byteCount)
        else {
            return nil
        }
        return MACAddress(
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
            bytes[offset + 4],
            bytes[offset + 5]
        )
    }

    @discardableResult
    func encode(
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> Bool {
        guard NetworkWire.contains(bytes, offset: offset, count: Self.byteCount)
        else {
            return false
        }
        bytes[offset] = octet0
        bytes[offset + 1] = octet1
        bytes[offset + 2] = octet2
        bytes[offset + 3] = octet3
        bytes[offset + 4] = octet4
        bytes[offset + 5] = octet5
        return true
    }
}

/// IPv4 address stored as the canonical 32-bit network-order value.
struct IPv4Address: RawRepresentable, Equatable {
    let rawValue: UInt32

    static let unspecified = IPv4Address(rawValue: 0)
    static let limitedBroadcast = IPv4Address(rawValue: UInt32.max)

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init(_ octet0: UInt8, _ octet1: UInt8, _ octet2: UInt8, _ octet3: UInt8) {
        rawValue = UInt32(octet0) << 24
            | UInt32(octet1) << 16
            | UInt32(octet2) << 8
            | UInt32(octet3)
    }

    var octet0: UInt8 { UInt8(truncatingIfNeeded: rawValue >> 24) }
    var octet1: UInt8 { UInt8(truncatingIfNeeded: rawValue >> 16) }
    var octet2: UInt8 { UInt8(truncatingIfNeeded: rawValue >> 8) }
    var octet3: UInt8 { UInt8(truncatingIfNeeded: rawValue) }
    var isUnspecified: Bool { rawValue == 0 }
    var isLimitedBroadcast: Bool { rawValue == UInt32.max }
    var isMulticast: Bool { octet0 >= 224 && octet0 <= 239 }

    static func decode(
        from bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> IPv4Address? {
        guard let value = NetworkWire.readUInt32BE(bytes, at: offset) else {
            return nil
        }
        return IPv4Address(rawValue: value)
    }

    @discardableResult
    func encode(
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> Bool {
        NetworkWire.writeUInt32BE(rawValue, to: bytes, at: offset)
    }
}

/// Incremental RFC 1071 Internet checksum accumulator.
///
/// Segment boundaries may occur on odd byte offsets; a pending high byte is
/// joined to the first byte of the next segment. This is required when a UDP
/// pseudo-header and payload are checksummed without assembling a temporary
/// buffer.
struct InternetChecksumAccumulator {
    private var foldedSum: UInt32 = 0
    private var pendingHighByte: UInt8 = 0
    private var hasPendingHighByte = false

    mutating func update(_ bytes: UnsafeRawBufferPointer) -> Bool {
        update(bytes, offset: 0, count: bytes.count)
    }

    mutating func update(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int,
        count: Int
    ) -> Bool {
        guard NetworkWire.contains(bytes, offset: offset, count: count) else {
            return false
        }
        var index = offset
        let end = offset + count
        while index < end {
            update(byte: bytes[index])
            index += 1
        }
        return true
    }

    mutating func update(byte: UInt8) {
        if hasPendingHighByte {
            add(word: UInt16(pendingHighByte) << 8 | UInt16(byte))
            hasPendingHighByte = false
        } else {
            pendingHighByte = byte
            hasPendingHighByte = true
        }
    }

    mutating func updateUInt16BE(_ value: UInt16) {
        update(byte: UInt8(truncatingIfNeeded: value >> 8))
        update(byte: UInt8(truncatingIfNeeded: value))
    }

    mutating func updateUInt32BE(_ value: UInt32) {
        updateUInt16BE(UInt16(truncatingIfNeeded: value >> 16))
        updateUInt16BE(UInt16(truncatingIfNeeded: value))
    }

    var value: UInt16 {
        var copy = self
        return copy.finalize()
    }

    private mutating func add(word: UInt16) {
        let sum = foldedSum + UInt32(word)
        foldedSum = (sum & 0xffff) + (sum >> 16)
    }

    private mutating func finalize() -> UInt16 {
        if hasPendingHighByte {
            add(word: UInt16(pendingHighByte) << 8)
            hasPendingHighByte = false
        }
        foldedSum = (foldedSum & 0xffff) + (foldedSum >> 16)
        return ~UInt16(truncatingIfNeeded: foldedSum)
    }
}

enum InternetChecksum {
    static func compute(_ bytes: UnsafeRawBufferPointer) -> UInt16? {
        var accumulator = InternetChecksumAccumulator()
        guard accumulator.update(bytes) else { return nil }
        return accumulator.value
    }

    static func verifies(_ bytes: UnsafeRawBufferPointer) -> Bool {
        compute(bytes) == 0
    }
}
