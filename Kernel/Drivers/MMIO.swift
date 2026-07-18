import _Volatile

enum MMIO {
    @inline(__always)
    static func load8(at address: UInt) -> UInt8 {
        VolatileMappedRegister<UInt8>(unsafeBitPattern: address).load()
    }

    @inline(__always)
    static func store8(_ value: UInt8, at address: UInt) {
        VolatileMappedRegister<UInt8>(unsafeBitPattern: address).store(value)
    }

    @inline(__always)
    static func load16(at address: UInt) -> UInt16 {
        VolatileMappedRegister<UInt16>(unsafeBitPattern: address).load()
    }

    @inline(__always)
    static func store16(_ value: UInt16, at address: UInt) {
        VolatileMappedRegister<UInt16>(unsafeBitPattern: address).store(value)
    }

    @inline(__always)
    static func load32(at address: UInt) -> UInt32 {
        VolatileMappedRegister<UInt32>(unsafeBitPattern: address).load()
    }

    @inline(__always)
    static func store32(_ value: UInt32, at address: UInt) {
        VolatileMappedRegister<UInt32>(unsafeBitPattern: address).store(value)
    }

    @inline(__always)
    static func load64(at address: UInt) -> UInt64 {
        VolatileMappedRegister<UInt64>(unsafeBitPattern: address).load()
    }

    @inline(__always)
    static func store64(_ value: UInt64, at address: UInt) {
        VolatileMappedRegister<UInt64>(unsafeBitPattern: address).store(value)
    }
}

