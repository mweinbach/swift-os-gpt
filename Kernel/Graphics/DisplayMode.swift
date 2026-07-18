enum PixelFormat: UInt32, Equatable {
    // On little-endian AArch64, an XRGB8888 UInt32 is stored as B, G, R, X.
    // The raw value is the DRM/ramfb XR24 fourcc.
    case b8g8r8x8 = 0x3432_5258

    static var xrgb8888: PixelFormat { .b8g8r8x8 }

    var bytesPerPixel: UInt64 {
        switch self {
        case .b8g8r8x8:
            return 4
        }
    }

    func packXRGB(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        switch self {
        case .b8g8r8x8:
            return UInt32(red) << 16
                | UInt32(green) << 8
                | UInt32(blue)
        }
    }
}

struct DisplayMode: Equatable {
    let widthInPixels: UInt32
    let heightInPixels: UInt32
    let refreshRateMilliHertz: UInt32
    let pixelFormat: PixelFormat

    init?(
        widthInPixels: UInt32,
        heightInPixels: UInt32,
        refreshRateMilliHertz: UInt32,
        pixelFormat: PixelFormat
    ) {
        guard widthInPixels > 0,
              heightInPixels > 0,
              refreshRateMilliHertz > 0
        else {
            return nil
        }

        let pixelCount = UInt64(widthInPixels) * UInt64(heightInPixels)
        guard pixelCount <= UInt64.max / pixelFormat.bytesPerPixel else {
            return nil
        }

        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        self.refreshRateMilliHertz = refreshRateMilliHertz
        self.pixelFormat = pixelFormat
    }

    var minimumBytesPerRow: UInt64 {
        UInt64(widthInPixels) * pixelFormat.bytesPerPixel
    }

    var minimumByteCount: UInt64 {
        minimumBytesPerRow * UInt64(heightInPixels)
    }
}
