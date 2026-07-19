/// Allocation-free SHA-256 used to verify the integrity of a staged kernel
/// update before its metadata can be sealed. Authenticity and activation are
/// separate policy layers. This implementation owns no platform or transport
/// policy and is suitable for the freestanding Embedded Swift guest.
struct USBKernelUpdateSHA256Digest: Equatable {
    let word0: UInt32
    let word1: UInt32
    let word2: UInt32
    let word3: UInt32
    let word4: UInt32
    let word5: UInt32
    let word6: UInt32
    let word7: UInt32

    init(
        _ word0: UInt32,
        _ word1: UInt32,
        _ word2: UInt32,
        _ word3: UInt32,
        _ word4: UInt32,
        _ word5: UInt32,
        _ word6: UInt32,
        _ word7: UInt32
    ) {
        self.word0 = word0
        self.word1 = word1
        self.word2 = word2
        self.word3 = word3
        self.word4 = word4
        self.word5 = word5
        self.word6 = word6
        self.word7 = word7
    }

    init?(bytes: UnsafeRawBufferPointer) {
        guard bytes.count == 32 else { return nil }
        self.init(
            Self.readWord(bytes, at: 0),
            Self.readWord(bytes, at: 4),
            Self.readWord(bytes, at: 8),
            Self.readWord(bytes, at: 12),
            Self.readWord(bytes, at: 16),
            Self.readWord(bytes, at: 20),
            Self.readWord(bytes, at: 24),
            Self.readWord(bytes, at: 28)
        )
    }

    func write(
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int = 0
    ) -> Bool {
        guard offset >= 0, offset <= bytes.count,
              bytes.count - offset >= 32
        else { return false }
        Self.writeWord(word0, to: bytes, at: offset)
        Self.writeWord(word1, to: bytes, at: offset + 4)
        Self.writeWord(word2, to: bytes, at: offset + 8)
        Self.writeWord(word3, to: bytes, at: offset + 12)
        Self.writeWord(word4, to: bytes, at: offset + 16)
        Self.writeWord(word5, to: bytes, at: offset + 20)
        Self.writeWord(word6, to: bytes, at: offset + 24)
        Self.writeWord(word7, to: bytes, at: offset + 28)
        return true
    }

    private static func readWord(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func writeWord(
        _ word: UInt32,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: word >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: word >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: word >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: word)
    }
}

struct USBKernelUpdateSHA256 {
    private var state0: UInt32 = 0x6a09_e667
    private var state1: UInt32 = 0xbb67_ae85
    private var state2: UInt32 = 0x3c6e_f372
    private var state3: UInt32 = 0xa54f_f53a
    private var state4: UInt32 = 0x510e_527f
    private var state5: UInt32 = 0x9b05_688c
    private var state6: UInt32 = 0x1f83_d9ab
    private var state7: UInt32 = 0x5be0_cd19

    private var block = USBKernelUpdateSHA256Block()
    private var blockByteCount = 0
    private var messageByteCount: UInt64 = 0

    /// Returns false only if the SHA-256 bit-length field would overflow.
    mutating func update(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard UInt64(bytes.count) <= UInt64.max - messageByteCount,
              messageByteCount + UInt64(bytes.count) <= UInt64.max / 8
        else { return false }

        messageByteCount += UInt64(bytes.count)
        var index = 0
        while index < bytes.count {
            absorb(bytes[index])
            index += 1
        }
        return true
    }

    /// Finalization works on a copy, so callers may inspect a digest without
    /// consuming the streaming state.
    func finalizedDigest() -> USBKernelUpdateSHA256Digest {
        var copy = self
        return copy.finalizeInPlace()
    }

    private mutating func finalizeInPlace() -> USBKernelUpdateSHA256Digest {
        let bitLength = messageByteCount * 8
        absorb(0x80)
        while blockByteCount != 56 {
            absorb(0)
        }
        var shift = 56
        while shift >= 0 {
            absorb(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
            shift -= 8
        }
        return USBKernelUpdateSHA256Digest(
            state0, state1, state2, state3,
            state4, state5, state6, state7
        )
    }

    private mutating func absorb(_ byte: UInt8) {
        block.setByte(byte, at: blockByteCount)
        blockByteCount += 1
        if blockByteCount == 64 {
            compress()
            block = USBKernelUpdateSHA256Block()
            blockByteCount = 0
        }
    }

    private mutating func compress() {
        var schedule = block
        var a = state0
        var b = state1
        var c = state2
        var d = state3
        var e = state4
        var f = state5
        var g = state6
        var h = state7

        var round = 0
        while round < 64 {
            let word: UInt32
            if round < 16 {
                word = schedule.word(at: round)
            } else {
                let s0Word = schedule.word(at: (round - 15) & 15)
                let s1Word = schedule.word(at: (round - 2) & 15)
                let smallSigma0 = Self.rotateRight(s0Word, by: 7)
                    ^ Self.rotateRight(s0Word, by: 18) ^ (s0Word >> 3)
                let smallSigma1 = Self.rotateRight(s1Word, by: 17)
                    ^ Self.rotateRight(s1Word, by: 19) ^ (s1Word >> 10)
                word = schedule.word(at: round & 15)
                    &+ smallSigma0
                    &+ schedule.word(at: (round - 7) & 15)
                    &+ smallSigma1
                schedule.setWord(word, at: round & 15)
            }

            let largeSigma1 = Self.rotateRight(e, by: 6)
                ^ Self.rotateRight(e, by: 11)
                ^ Self.rotateRight(e, by: 25)
            let choose = (e & f) ^ (~e & g)
            let temporary1 = h &+ largeSigma1 &+ choose
                &+ Self.constant(at: round) &+ word
            let largeSigma0 = Self.rotateRight(a, by: 2)
                ^ Self.rotateRight(a, by: 13)
                ^ Self.rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = largeSigma0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
            round += 1
        }

        state0 &+= a
        state1 &+= b
        state2 &+= c
        state3 &+= d
        state4 &+= e
        state5 &+= f
        state6 &+= g
        state7 &+= h
    }

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        value >> count | value << (32 - count)
    }

    private static func constant(at index: Int) -> UInt32 {
        switch index {
        case 0: return 0x428a_2f98
        case 1: return 0x7137_4491
        case 2: return 0xb5c0_fbcf
        case 3: return 0xe9b5_dba5
        case 4: return 0x3956_c25b
        case 5: return 0x59f1_11f1
        case 6: return 0x923f_82a4
        case 7: return 0xab1c_5ed5
        case 8: return 0xd807_aa98
        case 9: return 0x1283_5b01
        case 10: return 0x2431_85be
        case 11: return 0x550c_7dc3
        case 12: return 0x72be_5d74
        case 13: return 0x80de_b1fe
        case 14: return 0x9bdc_06a7
        case 15: return 0xc19b_f174
        case 16: return 0xe49b_69c1
        case 17: return 0xefbe_4786
        case 18: return 0x0fc1_9dc6
        case 19: return 0x240c_a1cc
        case 20: return 0x2de9_2c6f
        case 21: return 0x4a74_84aa
        case 22: return 0x5cb0_a9dc
        case 23: return 0x76f9_88da
        case 24: return 0x983e_5152
        case 25: return 0xa831_c66d
        case 26: return 0xb003_27c8
        case 27: return 0xbf59_7fc7
        case 28: return 0xc6e0_0bf3
        case 29: return 0xd5a7_9147
        case 30: return 0x06ca_6351
        case 31: return 0x1429_2967
        case 32: return 0x27b7_0a85
        case 33: return 0x2e1b_2138
        case 34: return 0x4d2c_6dfc
        case 35: return 0x5338_0d13
        case 36: return 0x650a_7354
        case 37: return 0x766a_0abb
        case 38: return 0x81c2_c92e
        case 39: return 0x9272_2c85
        case 40: return 0xa2bf_e8a1
        case 41: return 0xa81a_664b
        case 42: return 0xc24b_8b70
        case 43: return 0xc76c_51a3
        case 44: return 0xd192_e819
        case 45: return 0xd699_0624
        case 46: return 0xf40e_3585
        case 47: return 0x106a_a070
        case 48: return 0x19a4_c116
        case 49: return 0x1e37_6c08
        case 50: return 0x2748_774c
        case 51: return 0x34b0_bcb5
        case 52: return 0x391c_0cb3
        case 53: return 0x4ed8_aa4a
        case 54: return 0x5b9c_ca4f
        case 55: return 0x682e_6ff3
        case 56: return 0x748f_82ee
        case 57: return 0x78a5_636f
        case 58: return 0x84c8_7814
        case 59: return 0x8cc7_0208
        case 60: return 0x90be_fffa
        case 61: return 0xa450_6ceb
        case 62: return 0xbef9_a3f7
        default: return 0xc671_78f2
        }
    }
}

/// Sixteen words are both the input block and the rolling message schedule.
/// Explicit fields keep the implementation allocation-free in Embedded Swift.
private struct USBKernelUpdateSHA256Block {
    private var word0: UInt32 = 0
    private var word1: UInt32 = 0
    private var word2: UInt32 = 0
    private var word3: UInt32 = 0
    private var word4: UInt32 = 0
    private var word5: UInt32 = 0
    private var word6: UInt32 = 0
    private var word7: UInt32 = 0
    private var word8: UInt32 = 0
    private var word9: UInt32 = 0
    private var word10: UInt32 = 0
    private var word11: UInt32 = 0
    private var word12: UInt32 = 0
    private var word13: UInt32 = 0
    private var word14: UInt32 = 0
    private var word15: UInt32 = 0

    func word(at index: Int) -> UInt32 {
        switch index {
        case 0: return word0
        case 1: return word1
        case 2: return word2
        case 3: return word3
        case 4: return word4
        case 5: return word5
        case 6: return word6
        case 7: return word7
        case 8: return word8
        case 9: return word9
        case 10: return word10
        case 11: return word11
        case 12: return word12
        case 13: return word13
        case 14: return word14
        default: return word15
        }
    }

    mutating func setWord(_ value: UInt32, at index: Int) {
        switch index {
        case 0: word0 = value
        case 1: word1 = value
        case 2: word2 = value
        case 3: word3 = value
        case 4: word4 = value
        case 5: word5 = value
        case 6: word6 = value
        case 7: word7 = value
        case 8: word8 = value
        case 9: word9 = value
        case 10: word10 = value
        case 11: word11 = value
        case 12: word12 = value
        case 13: word13 = value
        case 14: word14 = value
        default: word15 = value
        }
    }

    mutating func setByte(_ byte: UInt8, at index: Int) {
        let wordIndex = index >> 2
        let shift = UInt32(24 - (index & 3) * 8)
        let mask = ~(UInt32(0xff) << shift)
        let value = word(at: wordIndex) & mask | UInt32(byte) << shift
        setWord(value, at: wordIndex)
    }
}
