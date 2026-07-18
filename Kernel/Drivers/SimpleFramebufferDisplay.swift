/// Driver for a firmware-configured Device Tree `simple-framebuffer` scanout.
/// The renderer remains shared with VirtIO-GPU and ramfb; this driver owns only
/// validation, boot-resource handoff, and CPU-cache visibility on present.
struct SimpleFramebufferDisplayDriver {
    static let readyMarker: StaticString = "SWIFTOS:SIMPLE_FB_OK\n"

    let scanout: ScanoutBuffer
    let memoryResource: DriverMemoryResource

    init?(description: SimpleFramebufferDescription) {
        let pixelFormat: PixelFormat
        switch description.format {
        case .x8r8g8b8:
            pixelFormat = .b8g8r8x8
        case .a8r8g8b8:
            pixelFormat = .b8g8r8a8
        case .r5g6b5:
            // The shared renderer is 32-bit today. Do not reinterpret a 16-bit
            // firmware surface and corrupt memory while support is added.
            return nil
        }

        guard description.resource.baseAddress != 0,
              description.resource.baseAddress
                % pixelFormat.bytesPerPixel == 0,
              description.resource.length > 0,
              description.resource.length
                <= UInt64.max - description.resource.baseAddress,
              let mode = DisplayMode(
                  widthInPixels: description.widthInPixels,
                  heightInPixels: description.heightInPixels,
                  refreshRateMilliHertz: nil,
                  pixelFormat: pixelFormat
              ),
              let mapping = DMAMapping(
                  cpuPhysicalAddress: description.resource.baseAddress,
                  deviceAddress: description.resource.baseAddress,
                  byteCount: description.resource.length,
                  deviceAddressWidth: .bits64,
                  coherency: .softwareManaged
              ),
              let scanout = ScanoutBuffer(
                  mode: mode,
                  bytesPerRow: UInt64(description.bytesPerRow),
                  mapping: mapping
              ),
              let memoryResource = DriverMemoryResource(
                  baseAddress: description.resource.baseAddress,
                  length: description.resource.length,
                  role: .kernelData,
                  reservesSystemMemory: true
              )
        else {
            return nil
        }
        self.scanout = scanout
        self.memoryResource = memoryResource
    }

    func present(_ damage: DamageRectangle) -> Bool {
        let bytesPerPixel = scanout.mode.pixelFormat.bytesPerPixel
        let firstRowOffset = UInt64(damage.y).multipliedReportingOverflow(
            by: scanout.bytesPerRow
        )
        let firstColumnOffset = UInt64(damage.x).multipliedReportingOverflow(
            by: bytesPerPixel
        )
        let lastRow = UInt64(damage.y) + UInt64(damage.height) - 1
        let finalRowOffset = lastRow.multipliedReportingOverflow(
            by: scanout.bytesPerRow
        )
        let finalColumn = UInt64(damage.x) + UInt64(damage.width)
        let finalColumnOffset = finalColumn.multipliedReportingOverflow(
            by: bytesPerPixel
        )
        guard !firstRowOffset.overflow,
              !firstColumnOffset.overflow,
              !finalRowOffset.overflow,
              !finalColumnOffset.overflow
        else {
            return false
        }
        let firstOffset = firstRowOffset.partialValue.addingReportingOverflow(
            firstColumnOffset.partialValue
        )
        let finalOffset = finalRowOffset.partialValue.addingReportingOverflow(
            finalColumnOffset.partialValue
        )
        guard !firstOffset.overflow,
              !finalOffset.overflow,
              finalOffset.partialValue > firstOffset.partialValue,
              finalOffset.partialValue <= scanout.requiredByteCount,
              scanout.mapping.cpuPhysicalAddress
                <= UInt64.max - firstOffset.partialValue
        else {
            return false
        }
        return AArch64.cleanDataCache(
            address: scanout.mapping.cpuPhysicalAddress
                + firstOffset.partialValue,
            byteCount: finalOffset.partialValue - firstOffset.partialValue
        )
    }
}

struct PlatformDriverBootstrap {
    let resources: BootDriverResourceSet
    let display: SimpleFramebufferDisplayDriver?

    static func discover(platform: Platform) -> PlatformDriverBootstrap? {
        var resources = BootDriverResourceSet()
        if let mailbox = platform.firmwareMailbox,
           !resources.append(mmio: mailbox) {
            return nil
        }
        if let graphics = platform.graphicsResources {
            var index = 0
            while index < PlatformGraphicsResources.maximumMMIOResourceCount {
                guard let resource = graphics.mmioResource(at: index),
                      resources.append(mmio: resource)
                else {
                    return nil
                }
                index += 1
            }
        }

        var display: SimpleFramebufferDisplayDriver?
        if let description = platform.simpleFramebuffer {
            guard let memoryResource = DriverMemoryResource(
                      baseAddress: description.resource.baseAddress,
                      length: description.resource.length,
                      role: .kernelData,
                      reservesSystemMemory: true
                  ),
                  resources.append(memory: memoryResource)
            else {
                return nil
            }
            display = SimpleFramebufferDisplayDriver(
                description: description
            )
        }
        return PlatformDriverBootstrap(
            resources: resources,
            display: display
        )
    }
}
