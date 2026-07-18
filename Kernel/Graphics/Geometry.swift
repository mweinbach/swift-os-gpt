struct Point {
    let x: Int
    let y: Int
}

struct Rectangle {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct PixelColor: Equatable {
    let xrgb: UInt32

    static let transparentBlack = PixelColor(xrgb: 0x0000_0000)
    static let white = PixelColor(xrgb: 0x00f8_fafc)
    static let muted = PixelColor(xrgb: 0x0094_a3b8)
    static let cyan = PixelColor(xrgb: 0x0022_d3ee)
    static let blue = PixelColor(xrgb: 0x003b_82f6)
    static let green = PixelColor(xrgb: 0x0022_c55e)
    static let yellow = PixelColor(xrgb: 0x00e_ab308)
    static let red = PixelColor(xrgb: 0x00ef_4444)
    static let wallpaper = PixelColor(xrgb: 0x000b_1020)
    static let chrome = PixelColor(xrgb: 0x0011_1827)
    static let panel = PixelColor(xrgb: 0x001e_293b)
    static let terminal = PixelColor(xrgb: 0x0008_0e1a)
    static let shadow = PixelColor(xrgb: 0x0004_0710)
}

