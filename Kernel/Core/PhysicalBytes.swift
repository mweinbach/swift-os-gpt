enum PhysicalBytes {
    @inline(__always)
    static func write8(_ value: UInt8, at address: UInt64) {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(address)) else {
            return
        }
        pointer.storeBytes(of: value, as: UInt8.self)
    }

    static func writeBE32(_ value: UInt32, at address: UInt64) {
        write8(UInt8(truncatingIfNeeded: value >> 24), at: address)
        write8(UInt8(truncatingIfNeeded: value >> 16), at: address + 1)
        write8(UInt8(truncatingIfNeeded: value >> 8), at: address + 2)
        write8(UInt8(truncatingIfNeeded: value), at: address + 3)
    }

    static func writeBE64(_ value: UInt64, at address: UInt64) {
        writeBE32(UInt32(truncatingIfNeeded: value >> 32), at: address)
        writeBE32(UInt32(truncatingIfNeeded: value), at: address + 4)
    }

    @inline(__always)
    static func read8(at address: UInt64) -> UInt8 {
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else {
            return 0
        }
        return pointer.load(as: UInt8.self)
    }

    static func writeLE16(_ value: UInt16, at address: UInt64) {
        write8(UInt8(truncatingIfNeeded: value), at: address)
        write8(UInt8(truncatingIfNeeded: value >> 8), at: address + 1)
    }

    static func writeLE32(_ value: UInt32, at address: UInt64) {
        writeLE16(UInt16(truncatingIfNeeded: value), at: address)
        writeLE16(UInt16(truncatingIfNeeded: value >> 16), at: address + 2)
    }

    static func writeLE64(_ value: UInt64, at address: UInt64) {
        writeLE32(UInt32(truncatingIfNeeded: value), at: address)
        writeLE32(UInt32(truncatingIfNeeded: value >> 32), at: address + 4)
    }

    static func readLE16(at address: UInt64) -> UInt16 {
        UInt16(read8(at: address))
            | UInt16(read8(at: address + 1)) << 8
    }

    static func readLE32(at address: UInt64) -> UInt32 {
        UInt32(readLE16(at: address))
            | UInt32(readLE16(at: address + 2)) << 16
    }

    static func readLE64(at address: UInt64) -> UInt64 {
        UInt64(readLE32(at: address))
            | UInt64(readLE32(at: address + 4)) << 32
    }

    static func zero(address: UInt64, byteCount: UInt64) -> Bool {
        guard address <= UInt64(UInt.max),
              byteCount <= UInt64(Int.max),
              byteCount <= UInt64.max - address,
              UnsafeMutableRawPointer(bitPattern: UInt(address)) != nil
        else {
            return false
        }
        var offset: UInt64 = 0
        while offset < byteCount {
            write8(0, at: address + offset)
            offset += 1
        }
        return true
    }
}
