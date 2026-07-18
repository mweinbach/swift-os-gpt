struct RamFramebuffer {
    static let width = 800
    static let height = 600
    static let bytesPerPixel = 4
    static let stride = width * bytesPerPixel

    private static let configurationSize: UInt32 = 28
    private static let xrgb8888: UInt32 = 0x3432_5258

    static func publish(using firmware: FirmwareConfiguration) -> Bool {
        guard firmware.isAvailable(),
              let file = firmware.file(named: "etc/ramfb"),
              file.size == configurationSize
        else {
            return false
        }

        let scratch = AArch64.dmaScratchAddress
        let configuration = scratch + 64
        let framebuffer = AArch64.framebufferAddress

        PhysicalBytes.writeBE64(framebuffer, at: configuration)
        PhysicalBytes.writeBE32(xrgb8888, at: configuration + 8)
        PhysicalBytes.writeBE32(0, at: configuration + 12)
        PhysicalBytes.writeBE32(UInt32(width), at: configuration + 16)
        PhysicalBytes.writeBE32(UInt32(height), at: configuration + 20)
        PhysicalBytes.writeBE32(UInt32(stride), at: configuration + 24)
        AArch64.synchronizeData()

        return firmware.write(
            file: file,
            bytesAt: configuration,
            count: configurationSize,
            descriptorAt: scratch
        )
    }
}

