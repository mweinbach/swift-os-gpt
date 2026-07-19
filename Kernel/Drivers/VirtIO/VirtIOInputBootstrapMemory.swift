/// One allocator-owned coherent DMA page for a VirtIO input event queue.
///
/// Queue metadata and device-writable event records receive non-overlapping
/// CPU and device subranges. The allocation token remains attached so the
/// kernel cannot accidentally release the page while the device owns it.
struct VirtIOInputBootstrapMemory: Equatable {
    static let pageCount: UInt64 = 1
    static let eventQueueOffset: UInt64 = 0
    static let eventQueueByteCount: UInt64 = 2_048
    static let eventBufferOffset: UInt64 = 2_048
    static let eventBufferByteCount: UInt64 =
        VirtIOInputDMAStorage.requiredEventBufferByteCount

    let allocation: ClassifiedPageAllocationToken
    let storage: VirtIOInputDMAStorage

    init?(
        allocation: ClassifiedPageAllocationToken,
        deviceBaseAddress: UInt64,
        deviceAddressWidth: DMAAddressWidth,
        coherency: DMACoherency
    ) {
        let requiredCapabilities = PhysicalMemoryCapabilities.cpuAccessible
            .union(.deviceAccessible)
        guard let queueLayout = VirtIOSplitQueueLayout(
                  size: VirtIOInputDMAStorage.eventQueueSize
              ),
              allocation.identifier != 0,
              allocation.range.pageCount == Self.pageCount,
              allocation.classification.capabilities.contains(
                  requiredCapabilities
              ),
              allocation.classification.capabilities.contains(.cacheCoherent),
              coherency == .hardwareCoherent,
              MemoryPageGeometry.isPageAligned(deviceBaseAddress),
              Self.eventQueueByteCount >= queueLayout.requiredByteCount,
              Self.eventBufferOffset + Self.eventBufferByteCount
                  <= allocation.range.byteCount,
              let eventBufferDeviceAddress = Self.adding(
                  deviceBaseAddress,
                  Self.eventBufferOffset
              ),
              let eventQueue = DMAMapping(
                  cpuPhysicalAddress: allocation.range.baseAddress
                      + Self.eventQueueOffset,
                  deviceAddress: deviceBaseAddress + Self.eventQueueOffset,
                  byteCount: Self.eventQueueByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let eventBuffers = DMAMapping(
                  cpuPhysicalAddress: allocation.range.baseAddress
                      + Self.eventBufferOffset,
                  deviceAddress: eventBufferDeviceAddress,
                  byteCount: Self.eventBufferByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let storage = VirtIOInputDMAStorage(
                  eventQueue: eventQueue,
                  eventBuffers: eventBuffers
              )
        else {
            return nil
        }

        self.allocation = allocation
        self.storage = storage
    }

    private static func adding(_ left: UInt64, _ right: UInt64) -> UInt64? {
        guard right <= UInt64.max - left else { return nil }
        return left + right
    }
}
