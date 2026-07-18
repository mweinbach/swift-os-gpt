struct KernelTerminal {
    static let columns = 70
    static let rows = 32
    static let characterStorageOffset: UInt = 0
    static let colorStorageOffset: UInt = 4096

    static let white: UInt8 = 0
    static let cyan: UInt8 = 1
    static let green: UInt8 = 2
    static let yellow: UInt8 = 3
    static let red: UInt8 = 4
    static let muted: UInt8 = 5

    private static let origin = Point(x: 68, y: 126)
    private static let cellWidth = 6
    private static let cellHeight = 9

    private let framebuffer: LinearFramebuffer
    private let storageAddress: UInt
    private(set) var cursorColumn = 0
    private(set) var cursorRow = 0

    init(framebuffer: LinearFramebuffer, storageAddress: UInt64) {
        self.framebuffer = framebuffer
        self.storageAddress = UInt(storageAddress)
    }

    mutating func clear() {
        guard let characters = characterPointer,
              let colors = colorPointer
        else {
            return
        }
        var index = 0
        while index < Self.columns * Self.rows {
            characters[index] = 32
            colors[index] = Self.white
            index += 1
        }
        cursorColumn = 0
        cursorRow = 0
        framebuffer.fill(
            Rectangle(
                x: Self.origin.x,
                y: Self.origin.y,
                width: Self.columns * Self.cellWidth,
                height: Self.rows * Self.cellHeight
            ),
            color: .terminal
        )
    }

    mutating func write(_ text: StaticString, color: UInt8 = white) {
        text.withUTF8Buffer { bytes in
            for byte in bytes {
                write(byte: byte, color: color)
            }
        }
    }

    mutating func write(byte: UInt8, color: UInt8 = white) {
        if byte == 10 {
            newLine()
            return
        }
        if byte == 13 {
            return
        }
        guard byte >= 32 && byte <= 126,
              let characters = characterPointer,
              let colors = colorPointer
        else {
            return
        }

        let index = cursorRow * Self.columns + cursorColumn
        characters[index] = byte
        colors[index] = color
        renderCell(index: index, character: byte, colorCode: color)
        cursorColumn += 1
        if cursorColumn >= Self.columns {
            newLine()
        }
    }

    mutating func backspace() {
        guard cursorColumn > 0,
              let characters = characterPointer,
              let colors = colorPointer
        else {
            return
        }
        cursorColumn -= 1
        let index = cursorRow * Self.columns + cursorColumn
        characters[index] = 32
        colors[index] = Self.white
        renderCell(index: index, character: 32, colorCode: Self.white)
    }

    mutating func newLine() {
        cursorColumn = 0
        cursorRow += 1
        if cursorRow >= Self.rows {
            scroll()
            cursorRow = Self.rows - 1
        }
    }

    mutating func writeUnsigned(_ value: UInt64, color: UInt8 = white) {
        if value >= 10 {
            writeUnsigned(value / 10, color: color)
        }
        write(byte: 48 + UInt8(value % 10), color: color)
    }

    mutating func writeHex(_ value: UInt64, color: UInt8 = white) {
        write("0X", color: color)
        var shift = 60
        while shift >= 0 {
            let nibble = UInt8(truncatingIfNeeded: value >> UInt64(shift)) & 0xf
            write(
                byte: nibble < 10 ? 48 + nibble : 55 + nibble,
                color: color
            )
            shift -= 4
        }
    }

    private mutating func scroll() {
        guard let characters = characterPointer,
              let colors = colorPointer
        else {
            return
        }
        let visibleCount = Self.columns * Self.rows
        var index = 0
        while index < visibleCount - Self.columns {
            characters[index] = characters[index + Self.columns]
            colors[index] = colors[index + Self.columns]
            index += 1
        }
        while index < visibleCount {
            characters[index] = 32
            colors[index] = Self.white
            index += 1
        }
        redraw()
    }

    private func redraw() {
        guard let characters = characterPointer,
              let colors = colorPointer
        else {
            return
        }
        var index = 0
        while index < Self.columns * Self.rows {
            renderCell(
                index: index,
                character: characters[index],
                colorCode: colors[index]
            )
            index += 1
        }
    }

    private func renderCell(index: Int, character: UInt8, colorCode: UInt8) {
        let column = index % Self.columns
        let row = index / Self.columns
        let point = Point(
            x: Self.origin.x + column * Self.cellWidth,
            y: Self.origin.y + row * Self.cellHeight
        )
        framebuffer.fill(
            Rectangle(
                x: point.x,
                y: point.y,
                width: Self.cellWidth,
                height: Self.cellHeight
            ),
            color: .terminal
        )
        if character != 32 {
            framebuffer.drawCharacter(
                character,
                at: Point(x: point.x, y: point.y + 1),
                color: color(for: colorCode),
                scale: 1
            )
        }
    }

    private func color(for code: UInt8) -> PixelColor {
        switch code {
        case Self.cyan: return .cyan
        case Self.green: return .green
        case Self.yellow: return .yellow
        case Self.red: return .red
        case Self.muted: return .muted
        default: return .white
        }
    }

    private var characterPointer: UnsafeMutablePointer<UInt8>? {
        UnsafeMutableRawPointer(
            bitPattern: storageAddress + Self.characterStorageOffset
        )?.assumingMemoryBound(to: UInt8.self)
    }

    private var colorPointer: UnsafeMutablePointer<UInt8>? {
        UnsafeMutableRawPointer(
            bitPattern: storageAddress + Self.colorStorageOffset
        )?.assumingMemoryBound(to: UInt8.self)
    }
}
