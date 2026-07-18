enum PixelFormat: UInt32, Equatable {
    // On little-endian AArch64, an XRGB8888 UInt32 is stored as B, G, R, X.
    // The raw value is the DRM/ramfb XR24 fourcc.
    case b8g8r8x8 = 0x3432_5258
    // DRM AR24: a UInt32 is A8R8G8B8 and little-endian memory is B, G, R, A.
    case b8g8r8a8 = 0x3432_5241

    static var xrgb8888: PixelFormat { .b8g8r8x8 }

    var bytesPerPixel: UInt64 {
        switch self {
        case .b8g8r8x8, .b8g8r8a8:
            return 4
        }
    }

    func packXRGB(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        switch self {
        case .b8g8r8x8:
            return UInt32(red) << 16
                | UInt32(green) << 8
                | UInt32(blue)
        case .b8g8r8a8:
            return 0xff00_0000
                | UInt32(red) << 16
                | UInt32(green) << 8
                | UInt32(blue)
        }
    }
}

struct DisplayMode: Equatable {
    let widthInPixels: UInt32
    let heightInPixels: UInt32
    /// The observed or programmed frame refresh rate. Firmware scanout
    /// handoffs such as Device Tree simple-framebuffer do not always expose
    /// timing, so unknown is distinct from an invented 60 Hz value.
    let refreshRateMilliHertz: UInt32?
    let pixelFormat: PixelFormat

    init?(
        widthInPixels: UInt32,
        heightInPixels: UInt32,
        refreshRateMilliHertz: UInt32?,
        pixelFormat: PixelFormat
    ) {
        guard widthInPixels > 0, heightInPixels > 0 else {
            return nil
        }
        if let refreshRateMilliHertz, refreshRateMilliHertz == 0 {
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
