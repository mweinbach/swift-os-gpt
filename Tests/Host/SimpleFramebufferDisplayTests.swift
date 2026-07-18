// Minimal host-side platform and architecture shims keep this test focused on
// the boot-driver handoff and simple-framebuffer implementation. No MMIO or
// cache-maintenance instruction is executed by the host process.
struct DeviceResource: Equatable {
    let baseAddress: UInt64
    let length: UInt64
}

enum SimpleFramebufferFormat: UInt8, Equatable {
    case r5g6b5
    case a8r8g8b8
    case x8r8g8b8
}

struct SimpleFramebufferDescription: Equatable {
    let resource: DeviceResource
    let widthInPixels: UInt32
    let heightInPixels: UInt32
    let bytesPerRow: UInt32
    let format: SimpleFramebufferFormat
}

struct Platform {
    let firmwareMailbox: DeviceResource?
    let simpleFramebuffer: SimpleFramebufferDescription?
}

struct MemoryRegionRole: Equatable {
    private let value: UInt8

    static let kernelData = MemoryRegionRole(value: 0)
    static let device = MemoryRegionRole(value: 1)
}

enum AArch64 {
    nonisolated(unsafe) private(set) static var cleanCallCount = 0
    nonisolated(unsafe) private(set) static var lastCleanAddress: UInt64 = 0
    nonisolated(unsafe) private(set) static var lastCleanByteCount: UInt64 = 0
    nonisolated(unsafe) static var cleanResult = true

    static func resetCacheCleanSpy(result: Bool = true) {
        cleanCallCount = 0
        lastCleanAddress = 0
        lastCleanByteCount = 0
        cleanResult = result
    }

    static func cleanDataCache(address: UInt64, byteCount: UInt64) -> Bool {
        cleanCallCount += 1
        lastCleanAddress = address
        lastCleanByteCount = byteCount
        return cleanResult
    }
}

@main
struct SimpleFramebufferDisplayTests {
    static func main() {
        testSupportedFramebufferFormats()
        testFramebufferValidation()
        testDamageCacheCleanRange()
        testMemoryResourceCapacityAndOverlap()
        testMMIOResourceCapacityAndOverlap()
        testPlatformDriverDiscovery()
        print("simple-framebuffer display host tests: 6 groups passed")
    }

    private static func testSupportedFramebufferFormats() {
        let xrgb = requireDriver(
            description(
                baseAddress: 0x20_0000,
                length: 0x1_0000,
                width: 64,
                height: 32,
                stride: 320,
                format: .x8r8g8b8
            )
        )
        expect(
            xrgb.scanout.mode.pixelFormat == .b8g8r8x8,
            "x8r8g8b8 did not select the shared XRGB format"
        )
        expect(
            xrgb.scanout.mode.refreshRateMilliHertz == nil,
            "simple-framebuffer invented a refresh rate"
        )
        expect(xrgb.scanout.bytesPerRow == 320, "scanout lost its stride")
        expect(
            xrgb.scanout.mapping.cpuPhysicalAddress == 0x20_0000
                && xrgb.scanout.mapping.deviceAddress == 0x20_0000,
            "firmware scanout was not identity mapped"
        )
        expect(
            xrgb.scanout.mapping.coherency == .softwareManaged,
            "firmware scanout must require explicit CPU cache maintenance"
        )
        expect(
            xrgb.memoryResource.baseAddress == 0x20_0000
                && xrgb.memoryResource.length == 0x1_0000
                && xrgb.memoryResource.role == .kernelData
                && xrgb.memoryResource.reservesSystemMemory,
            "scanout memory was not handed to the boot resource set"
        )

        let argb = requireDriver(
            description(
                baseAddress: 0x30_0000,
                length: 0x1_0000,
                width: 64,
                height: 32,
                stride: 256,
                format: .a8r8g8b8
            )
        )
        expect(
            argb.scanout.mode.pixelFormat == .b8g8r8a8,
            "a8r8g8b8 did not preserve its alpha-bearing format"
        )
    }

    private static func testFramebufferValidation() {
        expect(
            SimpleFramebufferDisplayDriver(
                description: description(
                    baseAddress: 0,
                    length: 0x1_0000,
                    width: 64,
                    height: 32,
                    stride: 256,
                    format: .x8r8g8b8
                )
            ) == nil,
            "zero-address framebuffer was accepted"
        )
        expect(
            SimpleFramebufferDisplayDriver(
                description: description(
                    baseAddress: 0x40_0002,
                    length: 0x1_0000,
                    width: 64,
                    height: 32,
                    stride: 256,
                    format: .x8r8g8b8
                )
            ) == nil,
            "pixel-misaligned framebuffer was accepted"
        )
        expect(
            SimpleFramebufferDisplayDriver(
                description: description(
                    baseAddress: 0x40_0000,
                    length: 0x1_0000,
                    width: 64,
                    height: 32,
                    stride: 128,
                    format: .r5g6b5
                )
            ) == nil,
            "unsupported 16-bit firmware scanout was accepted"
        )
        expect(
            SimpleFramebufferDisplayDriver(
                description: description(
                    baseAddress: 0x40_0000,
                    length: 0x1_0000,
                    width: 64,
                    height: 32,
                    stride: 252,
                    format: .x8r8g8b8
                )
            ) == nil,
            "short framebuffer stride was accepted"
        )
        expect(
            SimpleFramebufferDisplayDriver(
                description: description(
                    baseAddress: 0x40_0000,
                    length: 0x1000,
                    width: 64,
                    height: 32,
                    stride: 256,
                    format: .x8r8g8b8
                )
            ) == nil,
            "undersized framebuffer resource was accepted"
        )
        expect(
            SimpleFramebufferDisplayDriver(
                description: description(
                    baseAddress: UInt64.max - 0xff,
                    length: 0x100,
                    width: 1,
                    height: 1,
                    stride: 4,
                    format: .x8r8g8b8
                )
            ) == nil,
            "overflowing framebuffer resource was accepted"
        )
    }

    private static func testDamageCacheCleanRange() {
        let driver = requireDriver(
            description(
                baseAddress: 0x50_0000,
                length: 0x1000,
                width: 8,
                height: 4,
                stride: 40,
                format: .x8r8g8b8
            )
        )
        let damage = DamageRectangle.clipped(
            x: 2,
            y: 1,
            width: 3,
            height: 2,
            to: driver.scanout.mode
        )!

        AArch64.resetCacheCleanSpy()
        expect(driver.present(damage), "valid damage was not presented")
        expect(AArch64.cleanCallCount == 1, "damage was cleaned more than once")
        expect(
            AArch64.lastCleanAddress == 0x50_0030,
            "cache clean did not begin at the first damaged pixel"
        )
        expect(
            AArch64.lastCleanByteCount == 52,
            "cache clean did not span padded rows through the last pixel"
        )

        AArch64.resetCacheCleanSpy(result: false)
        expect(!driver.present(damage), "cache-maintenance failure was hidden")
        expect(AArch64.cleanCallCount == 1, "failed clean was not attempted")

        let largerMode = requireMode(width: 64, height: 64)
        AArch64.resetCacheCleanSpy()
        expect(
            !driver.present(.fullMode(largerMode)),
            "damage outside the driver scanout was accepted"
        )
        expect(
            AArch64.cleanCallCount == 0,
            "invalid damage reached the architecture cache operation"
        )
    }

    private static func testMemoryResourceCapacityAndOverlap() {
        var resources = BootDriverResourceSet()
        var index = 0
        while index < BootDriverResourceSet.maximumMemoryResourceCount {
            let resource = requireMemoryResource(
                baseAddress: 0x100_0000 + UInt64(index) * 0x2000,
                length: 0x1000
            )
            expect(
                resources.append(memory: resource),
                "valid memory resource did not fit advertised capacity"
            )
            index += 1
        }
        expect(
            resources.memoryResourceCount
                == BootDriverResourceSet.maximumMemoryResourceCount,
            "memory resource count did not reach capacity"
        )
        expect(
            !resources.append(
                memory: requireMemoryResource(
                    baseAddress: 0x200_0000,
                    length: 0x1000
                )
            ),
            "memory resource set exceeded fixed capacity"
        )
        expect(resources.memoryResource(at: -1) == nil, "negative index")
        expect(
            resources.memoryResource(
                at: BootDriverResourceSet.maximumMemoryResourceCount
            ) == nil,
            "out-of-range memory index"
        )

        var overlap = BootDriverResourceSet()
        let first = requireMemoryResource(
            baseAddress: 0x300_0000,
            length: 0x1000
        )
        let touching = requireMemoryResource(
            baseAddress: 0x300_1000,
            length: 0x1000
        )
        let expandedOverlap = requireMemoryResource(
            baseAddress: 0x300_0f00,
            length: 0x200
        )
        expect(overlap.append(memory: first), "first memory resource")
        expect(overlap.append(memory: touching), "touching memory resource")
        expect(
            !overlap.append(memory: expandedOverlap),
            "page-aligned memory overlap was accepted"
        )
        expect(
            expandedOverlap.baseAddress == 0x300_0000
                && expandedOverlap.endAddress == 0x300_2000,
            "driver memory resource did not align outward"
        )
        expect(
            DriverMemoryResource(
                baseAddress: 0x400_0000,
                length: 0,
                role: .kernelData,
                reservesSystemMemory: true
            ) == nil,
            "empty memory resource was accepted"
        )
        expect(
            DriverMemoryResource(
                baseAddress: 0x400_0000,
                length: 0x1000,
                role: .device,
                reservesSystemMemory: false
            ) == nil,
            "non-kernel-data driver memory was accepted"
        )
        expect(
            DriverMemoryResource(
                baseAddress: UInt64.max - 0x7ff,
                length: 0x7ff,
                role: .kernelData,
                reservesSystemMemory: true
            ) == nil,
            "memory range whose aligned end overflows was accepted"
        )
    }

    private static func testMMIOResourceCapacityAndOverlap() {
        var resources = BootDriverResourceSet()
        var index = 0
        while index < BootDriverResourceSet.maximumMMIOResourceCount {
            expect(
                resources.append(
                    mmio: DeviceResource(
                        baseAddress: 0x500_0000 + UInt64(index) * 0x2000,
                        length: 0x1000
                    )
                ),
                "valid MMIO resource did not fit advertised capacity"
            )
            index += 1
        }
        expect(
            !resources.append(
                mmio: DeviceResource(
                    baseAddress: 0x600_0000,
                    length: 0x1000
                )
            ),
            "MMIO resource set exceeded fixed capacity"
        )

        var overlap = BootDriverResourceSet()
        expect(
            overlap.append(
                mmio: DeviceResource(
                    baseAddress: 0x700_0000,
                    length: 0x1000
                )
            ),
            "first MMIO resource"
        )
        expect(
            overlap.append(
                mmio: DeviceResource(
                    baseAddress: 0x700_1000,
                    length: 0x1000
                )
            ),
            "touching MMIO resource"
        )
        expect(
            !overlap.append(
                mmio: DeviceResource(
                    baseAddress: 0x700_0800,
                    length: 0x100
                )
            ),
            "overlapping MMIO resource was accepted"
        )

        var pageOverlap = BootDriverResourceSet()
        expect(
            pageOverlap.append(
                mmio: DeviceResource(
                    baseAddress: 0x710_0010,
                    length: 0x20
                )
            ),
            "first partial-page MMIO resource"
        )
        expect(
            !pageOverlap.append(
                mmio: DeviceResource(
                    baseAddress: 0x710_0800,
                    length: 0x20
                )
            ),
            "MMIO aliases within one mapped page were accepted"
        )

        var crossType = BootDriverResourceSet()
        expect(
            crossType.append(
                memory: requireMemoryResource(
                    baseAddress: 0x720_0000,
                    length: 0x1000
                )
            ),
            "cross-type memory fixture"
        )
        expect(
            !crossType.append(
                mmio: DeviceResource(
                    baseAddress: 0x720_0400,
                    length: 0x40
                )
            ),
            "MMIO overlapping retained memory was accepted"
        )

        var reverseCrossType = BootDriverResourceSet()
        expect(
            reverseCrossType.append(
                mmio: DeviceResource(
                    baseAddress: 0x730_0000,
                    length: 0x40
                )
            ),
            "cross-type MMIO fixture"
        )
        expect(
            !reverseCrossType.append(
                memory: requireMemoryResource(
                    baseAddress: 0x730_0800,
                    length: 0x100
                )
            ),
            "retained memory overlapping MMIO was accepted"
        )
        expect(
            !overlap.append(
                mmio: DeviceResource(baseAddress: 0x800_0000, length: 0)
            ),
            "empty MMIO resource was accepted"
        )
        expect(
            !overlap.append(
                mmio: DeviceResource(baseAddress: UInt64.max, length: 2)
            ),
            "overflowing MMIO resource was accepted"
        )
        expect(overlap.mmioResource(at: -1) == nil, "negative MMIO index")
        expect(
            overlap.mmioResource(at: overlap.mmioResourceCount) == nil,
            "out-of-range MMIO index"
        )
    }

    private static func testPlatformDriverDiscovery() {
        let mailbox = DeviceResource(baseAddress: 0x10_0000, length: 0x40)
        let framebuffer = description(
            baseAddress: 0x900_0000,
            length: 0x1_0000,
            width: 64,
            height: 32,
            stride: 256,
            format: .x8r8g8b8
        )
        let bootstrap = PlatformDriverBootstrap.discover(
            platform: Platform(
                firmwareMailbox: mailbox,
                simpleFramebuffer: framebuffer
            )
        )
        expect(bootstrap != nil, "platform driver discovery failed")
        expect(bootstrap?.resources.mmioResourceCount == 1, "mailbox missing")
        expect(
            bootstrap?.resources.memoryResourceCount == 1,
            "framebuffer memory missing"
        )
        expect(bootstrap?.display != nil, "framebuffer display missing")

        let unsupported = PlatformDriverBootstrap.discover(
            platform: Platform(
                firmwareMailbox: nil,
                simpleFramebuffer: description(
                    baseAddress: 0xa00_0000,
                    length: 0x1_0000,
                    width: 64,
                    height: 32,
                    stride: 128,
                    format: .r5g6b5
                )
            )
        )
        expect(
            unsupported?.display == nil
                && unsupported?.resources.memoryResourceCount == 1,
            "unsupported framebuffer memory was not retained"
        )
        expect(
            unsupported?.resources.memoryResource(at: 0)?.baseAddress
                == 0xa00_0000
                && unsupported?.resources.memoryResource(at: 0)?.length
                    == 0x1_0000,
            "unsupported framebuffer retained the wrong memory range"
        )
    }

    private static func description(
        baseAddress: UInt64,
        length: UInt64,
        width: UInt32,
        height: UInt32,
        stride: UInt32,
        format: SimpleFramebufferFormat
    ) -> SimpleFramebufferDescription {
        SimpleFramebufferDescription(
            resource: DeviceResource(
                baseAddress: baseAddress,
                length: length
            ),
            widthInPixels: width,
            heightInPixels: height,
            bytesPerRow: stride,
            format: format
        )
    }

    private static func requireDriver(
        _ description: SimpleFramebufferDescription
    ) -> SimpleFramebufferDisplayDriver {
        guard let driver = SimpleFramebufferDisplayDriver(
            description: description
        ) else {
            fatalError("expected valid simple-framebuffer driver")
        }
        return driver
    }

    private static func requireMemoryResource(
        baseAddress: UInt64,
        length: UInt64
    ) -> DriverMemoryResource {
        guard let resource = DriverMemoryResource(
            baseAddress: baseAddress,
            length: length,
            role: .kernelData,
            reservesSystemMemory: true
        ) else {
            fatalError("expected valid driver memory resource")
        }
        return resource
    }

    private static func requireMode(
        width: UInt32,
        height: UInt32
    ) -> DisplayMode {
        guard let mode = DisplayMode(
            widthInPixels: width,
            heightInPixels: height,
            refreshRateMilliHertz: nil,
            pixelFormat: .b8g8r8x8
        ) else {
            fatalError("expected valid display mode")
        }
        return mode
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("simple-framebuffer test failed: \(message)")
        }
    }
}
