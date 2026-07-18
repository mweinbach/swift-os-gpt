enum BitmapFont {
    static func glyph(for rawCharacter: UInt8) -> UInt64 {
        let character: UInt8
        if rawCharacter >= 97 && rawCharacter <= 122 {
            character = rawCharacter - 32
        } else {
            character = rawCharacter
        }

        switch character {
        case 32: return 0
        case 45: return pack(0, 0, 0, 31, 0, 0, 0)
        case 46: return pack(0, 0, 0, 0, 0, 12, 12)
        case 47: return pack(1, 2, 4, 8, 16, 0, 0)
        case 48: return pack(14, 17, 19, 21, 25, 17, 14)
        case 49: return pack(4, 12, 4, 4, 4, 4, 14)
        case 50: return pack(14, 17, 1, 2, 4, 8, 31)
        case 51: return pack(30, 1, 1, 14, 1, 1, 30)
        case 52: return pack(2, 6, 10, 18, 31, 2, 2)
        case 53: return pack(31, 16, 16, 30, 1, 1, 30)
        case 54: return pack(14, 16, 16, 30, 17, 17, 14)
        case 55: return pack(31, 1, 2, 4, 8, 8, 8)
        case 56: return pack(14, 17, 17, 14, 17, 17, 14)
        case 57: return pack(14, 17, 17, 15, 1, 1, 14)
        case 58: return pack(0, 12, 12, 0, 12, 12, 0)
        case 62: return pack(16, 8, 4, 2, 4, 8, 16)
        case 64: return pack(14, 17, 23, 21, 23, 16, 14)
        case 65: return pack(14, 17, 17, 31, 17, 17, 17)
        case 66: return pack(30, 17, 17, 30, 17, 17, 30)
        case 67: return pack(14, 17, 16, 16, 16, 17, 14)
        case 68: return pack(30, 17, 17, 17, 17, 17, 30)
        case 69: return pack(31, 16, 16, 30, 16, 16, 31)
        case 70: return pack(31, 16, 16, 30, 16, 16, 16)
        case 71: return pack(14, 17, 16, 23, 17, 17, 15)
        case 72: return pack(17, 17, 17, 31, 17, 17, 17)
        case 73: return pack(14, 4, 4, 4, 4, 4, 14)
        case 74: return pack(7, 2, 2, 2, 2, 18, 12)
        case 75: return pack(17, 18, 20, 24, 20, 18, 17)
        case 76: return pack(16, 16, 16, 16, 16, 16, 31)
        case 77: return pack(17, 27, 21, 21, 17, 17, 17)
        case 78: return pack(17, 25, 21, 19, 17, 17, 17)
        case 79: return pack(14, 17, 17, 17, 17, 17, 14)
        case 80: return pack(30, 17, 17, 30, 16, 16, 16)
        case 81: return pack(14, 17, 17, 17, 21, 18, 13)
        case 82: return pack(30, 17, 17, 30, 20, 18, 17)
        case 83: return pack(15, 16, 16, 14, 1, 1, 30)
        case 84: return pack(31, 4, 4, 4, 4, 4, 4)
        case 85: return pack(17, 17, 17, 17, 17, 17, 14)
        case 86: return pack(17, 17, 17, 17, 17, 10, 4)
        case 87: return pack(17, 17, 17, 21, 21, 21, 10)
        case 88: return pack(17, 17, 10, 4, 10, 17, 17)
        case 89: return pack(17, 17, 10, 4, 4, 4, 4)
        case 90: return pack(31, 1, 2, 4, 8, 16, 31)
        case 91: return pack(14, 8, 8, 8, 8, 8, 14)
        case 93: return pack(14, 2, 2, 2, 2, 2, 14)
        case 95: return pack(0, 0, 0, 0, 0, 0, 31)
        case 126: return pack(0, 0, 9, 22, 0, 0, 0)
        default: return pack(31, 17, 21, 17, 21, 17, 31)
        }
    }

    private static func pack(
        _ row0: UInt64,
        _ row1: UInt64,
        _ row2: UInt64,
        _ row3: UInt64,
        _ row4: UInt64,
        _ row5: UInt64,
        _ row6: UInt64
    ) -> UInt64 {
        row0
            | row1 << 5
            | row2 << 10
            | row3 << 15
            | row4 << 20
            | row5 << 25
            | row6 << 30
    }
}
