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
}

