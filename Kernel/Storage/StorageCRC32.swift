/// Incremental IEEE CRC-32 used by persistent storage records. This is a data
/// integrity checksum, not an authenticity primitive.
struct StorageCRC32 {
    private var state: UInt32 = 0xffff_ffff

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        for byte in bytes {
            var value = state ^ UInt32(byte)
            var bit = 0
            while bit < 8 {
                let mask = UInt32(0) &- (value & 1)
                value = (value >> 1) ^ (0xedb8_8320 & mask)
                bit += 1
            }
            state = value
        }
    }

    var value: UInt32 { state ^ 0xffff_ffff }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc = Self()
        crc.update(bytes)
        return crc.value
    }
}
