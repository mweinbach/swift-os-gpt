/// One allocator-owned coherent page for a synchronous VirtIO block queue.
/// Queue metadata, request header, bounce block, and status byte are disjoint
/// on both CPU and device address axes.
struct VirtIOBlockBootstrapMemory: Equatable {
    static let pageCount: UInt64 = 1
    static let requestQueueOffset: UInt64 = 0
    static let requestQueueByteCount: UInt64 = 256
    static let requestHeaderOffset: UInt64 = 256
    static let requestHeaderByteCount: UInt64 = 16
    static let dataOffset: UInt64 = 512
    static let dataByteCount: UInt64 = 512
    static let statusOffset: UInt64 = 1_024
    static let statusByteCount: UInt64 = 1

    let allocation: ClassifiedPageAllocationToken
    let storage: VirtIOBlockDMAStorage

    init?(
        allocation: ClassifiedPageAllocationToken,
        deviceBaseAddress: UInt64,
        deviceAddressWidth: DMAAddressWidth,
        coherency: DMACoherency
    ) {
        let requiredCapabilities = PhysicalMemoryCapabilities.cpuAccessible
            .union(.deviceAccessible)
        guard let queueLayout = VirtIOSplitQueueLayout(
                  size: VirtIOBlockDMAStorage.requestQueueSize
              ),
              allocation.identifier != 0,
              allocation.range.pageCount == Self.pageCount,
              allocation.classification.capabilities.contains(
                  requiredCapabilities
              ),
              allocation.classification.capabilities.contains(.cacheCoherent),
              coherency == .hardwareCoherent,
              MemoryPageGeometry.isPageAligned(deviceBaseAddress),
              Self.requestQueueByteCount >= queueLayout.requiredByteCount,
              Self.statusOffset + Self.statusByteCount
                <= allocation.range.byteCount,
              let queueDeviceAddress = Self.adding(
                  deviceBaseAddress,
                  Self.requestQueueOffset
              ),
              let headerDeviceAddress = Self.adding(
                  deviceBaseAddress,
                  Self.requestHeaderOffset
              ),
              let dataDeviceAddress = Self.adding(
                  deviceBaseAddress,
                  Self.dataOffset
              ),
              let statusDeviceAddress = Self.adding(
                  deviceBaseAddress,
                  Self.statusOffset
              ),
              let queue = DMAMapping(
                  cpuPhysicalAddress: allocation.range.baseAddress
                    + Self.requestQueueOffset,
                  deviceAddress: queueDeviceAddress,
                  byteCount: Self.requestQueueByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let header = DMAMapping(
                  cpuPhysicalAddress: allocation.range.baseAddress
                    + Self.requestHeaderOffset,
                  deviceAddress: headerDeviceAddress,
                  byteCount: Self.requestHeaderByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let data = DMAMapping(
                  cpuPhysicalAddress: allocation.range.baseAddress
                    + Self.dataOffset,
                  deviceAddress: dataDeviceAddress,
                  byteCount: Self.dataByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let status = DMAMapping(
                  cpuPhysicalAddress: allocation.range.baseAddress
                    + Self.statusOffset,
                  deviceAddress: statusDeviceAddress,
                  byteCount: Self.statusByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let storage = VirtIOBlockDMAStorage(
                  requestQueue: queue,
                  requestHeader: header,
                  data: data,
                  status: status
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
