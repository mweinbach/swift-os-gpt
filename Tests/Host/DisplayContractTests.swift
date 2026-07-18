@main
struct DisplayContractTests {
    static func main() {
        testModeAndPixelFormat()
        testDMAAddressDomains()
        testScanoutValidation()
        testDamageClipping()
        testBackendPolicy()
        print("display contract host tests: 5 groups passed")
    }

    private static func testModeAndPixelFormat() {
        expect(
            PixelFormat.xrgb8888 == .b8g8r8x8,
            "XRGB word layout must correspond to B8G8R8X8 memory order"
        )
        expect(
            PixelFormat.b8g8r8x8.rawValue == 0x3432_5258,
            "B8G8R8X8 fourcc"
        )
        expect(
            PixelFormat.b8g8r8x8.packXRGB(
                red: 0x12,
                green: 0x34,
                blue: 0x56
            ) == 0x0012_3456,
            "XRGB packing"
        )

        let mode = requireMode(width: 800, height: 600)
        expect(mode.minimumBytesPerRow == 3_200, "minimum row size")
        expect(mode.minimumByteCount == 1_920_000, "minimum scanout size")
        expect(
            DisplayMode(
                widthInPixels: 0,
                heightInPixels: 600,
                refreshRateMilliHertz: 60_000,
                pixelFormat: .b8g8r8x8
            ) == nil,
            "zero-width mode accepted"
        )
        expect(
            DisplayMode(
                widthInPixels: UInt32.max,
                heightInPixels: UInt32.max,
                refreshRateMilliHertz: 60_000,
                pixelFormat: .b8g8r8x8
            ) == nil,
            "overflowing mode byte count accepted"
        )
    }

    private static func testDMAAddressDomains() {
        expect(DMAAddressWidth(bitCount: 0) == nil, "zero-bit DMA width")
        expect(DMAAddressWidth(bitCount: 65) == nil, "oversized DMA width")
        expect(
            DMAAddressWidth(bitCount: 36)?.highestAddress == 0x0f_ffff_ffff,
            "nonstandard DMA width"
        )

        let translated = DMAMapping(
            cpuPhysicalAddress: 0x1_2000_0000,
            deviceAddress: 0x2000_0000,
            byteCount: 0x20_0000,
            deviceAddressWidth: .bits32,
            coherency: .softwareManaged
        )
        expect(translated != nil, "translated 32-bit DMA mapping")
        expect(translated?.isIdentityMapped == false, "DMA domains collapsed")
        expect(
            translated?.coherency.requiresCPUCacheMaintenance == true,
            "software coherency contract"
        )

        expect(
            DMAMapping(
                cpuPhysicalAddress: 0x1000,
                deviceAddress: 0xffff_f000,
                byteCount: 0x2000,
                deviceAddressWidth: .bits32,
                coherency: .hardwareCoherent
            ) == nil,
            "mapping crossed device address width"
        )
        expect(
            DMAMapping(
                cpuPhysicalAddress: UInt64.max,
                deviceAddress: 0,
                byteCount: 2,
                deviceAddressWidth: .bits64,
                coherency: .hardwareCoherent
            ) == nil,
            "CPU physical range overflow"
        )
    }

    private static func testScanoutValidation() {
        let mode = requireMode(width: 640, height: 480)
        let mapping = requireMapping(byteCount: 640 * 4 * 480 + 0x1000)
        let scanout = ScanoutBuffer(
            mode: mode,
            bytesPerRow: 640 * 4,
            mapping: mapping
        )
        expect(scanout?.requiredByteCount == 1_228_800, "scanout size")
        expect(
            ScanoutBuffer(
                mode: mode,
                bytesPerRow: 639 * 4,
                mapping: mapping
            ) == nil,
            "short scanout stride accepted"
        )
        expect(
            ScanoutBuffer(
                mode: mode,
                bytesPerRow: 640 * 4 + 1,
                mapping: mapping
            ) == nil,
            "unaligned scanout stride accepted"
        )
        expect(
            ScanoutBuffer(
                mode: mode,
                bytesPerRow: 0x10_0000,
                mapping: mapping
            ) == nil,
            "undersized DMA mapping accepted"
        )
    }

    private static func testDamageClipping() {
        let mode = requireMode(width: 800, height: 600)
        let clipped = DamageRectangle.clipped(
            x: -20,
            y: 590,
            width: 50,
            height: 40,
            to: mode
        )
        expect(clipped?.x == 0, "clipped damage x")
        expect(clipped?.y == 590, "clipped damage y")
        expect(clipped?.width == 30, "clipped damage width")
        expect(clipped?.height == 10, "clipped damage height")
        expect(
            DamageRectangle.clipped(
                x: Int64.max - 5,
                y: 0,
                width: 100,
                height: 1,
                to: mode
            ) == nil,
            "overflowed offscreen damage"
        )
        expect(
            DamageRectangle.clipped(
                x: -100,
                y: -100,
                width: 20,
                height: 20,
                to: mode
            ) == nil,
            "offscreen damage accepted"
        )
        expect(
            DamageRectangle.clipped(
                x: 1,
                y: 1,
                width: 0,
                height: 10,
                to: mode
            ) == nil,
            "empty damage accepted"
        )
        let full = DamageRectangle.fullMode(mode)
        expect(full.x == 0, "full-mode damage x")
        expect(full.y == 0, "full-mode damage y")
        expect(full.width == 800, "full-mode damage width")
        expect(full.height == 600, "full-mode damage height")
    }

    private static func testBackendPolicy() {
        expect(
            DisplayBackendSelectionPolicy.automatic.priority(for: .virtIOGPU)
                == 0,
            "automatic GPU priority"
        )
        expect(
            DisplayBackendSelectionPolicy.automatic.priority(
                for: .firmwareRAMFramebuffer
            ) == 2,
            "automatic firmware priority"
        )

        let preferred = DisplayBackendSelectionPolicy.prefer(
            .firmwareRAMFramebuffer
        )
        expect(
            preferred.priority(for: .firmwareRAMFramebuffer) == 0,
            "preferred backend priority"
        )
        expect(
            preferred.priority(for: .virtIOGPU) == 1,
            "preferred fallback priority"
        )

        let required = DisplayBackendSelectionPolicy.require(.platformFramebuffer)
        expect(
            required.priority(for: .platformFramebuffer) == 0,
            "required backend allowed"
        )
        expect(
            required.priority(for: .virtIOGPU) == nil,
            "non-required backend allowed"
        )
    }

    private static func requireMode(width: UInt32, height: UInt32) -> DisplayMode {
        guard let mode = DisplayMode(
            widthInPixels: width,
            heightInPixels: height,
            refreshRateMilliHertz: 60_000,
            pixelFormat: .b8g8r8x8
        ) else {
            fatalError("valid mode fixture rejected")
        }
        return mode
    }

    private static func requireMapping(byteCount: UInt64) -> DMAMapping {
        guard let mapping = DMAMapping(
            cpuPhysicalAddress: 0x4800_0000,
            deviceAddress: 0x0800_0000,
            byteCount: byteCount,
            deviceAddressWidth: .bits32,
            coherency: .hardwareCoherent
        ) else {
            fatalError("valid DMA fixture rejected")
        }
        return mapping
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("display contract assertion failed: \(message)")
        }
    }
}
