/// One allocator-owned DMA workspace for the polling VirtIO network backend.
///
/// The platform supplies both the CPU allocation and the device-visible base.
/// QEMU uses an identity mapping today, while an IOMMU-backed machine can hand
/// this partitioner a contiguous IOVA without changing the queue driver.
struct VirtIONetworkBootstrapMemory: Equatable {
    static let receiveQueueSize: UInt16 = 8
    static let transmitQueueSize: UInt16 = 1
    static let pageCount: UInt64 = 8

    let allocation: ClassifiedPageAllocationToken
    let storage: VirtIONetworkDMAStorage
    let receiveScratchAddress: UInt64
    let transmitScratchAddress: UInt64
    let scratchByteCount: UInt64

    init?(
        allocation: ClassifiedPageAllocationToken,
        deviceBaseAddress: UInt64,
        deviceAddressWidth: DMAAddressWidth,
        coherency: DMACoherency
    ) {
        let requiredCapabilities = PhysicalMemoryCapabilities.cpuAccessible
            .union(.deviceAccessible)
        guard allocation.identifier != 0,
              allocation.range.pageCount == Self.pageCount,
              allocation.classification.capabilities.contains(
                  requiredCapabilities
              ),
              coherency == .hardwareCoherent,
              allocation.classification.capabilities.contains(
                  .cacheCoherent
              ),
              MemoryPageGeometry.isPageAligned(deviceBaseAddress)
        else {
            return nil
        }

        let pageSize = MemoryPageGeometry.pageSize
        let receiveBufferPageCount: UInt64 = 3
        let receiveBufferByteCount = receiveBufferPageCount * pageSize
        let cpuBase = allocation.range.baseAddress
        guard let receiveQueue = Self.mapping(
                  cpuAddress: cpuBase,
                  deviceAddress: deviceBaseAddress,
                  byteCount: pageSize,
                  width: deviceAddressWidth,
                  coherency: coherency
              ),
              let transmitQueue = Self.mapping(
                  cpuAddress: cpuBase + pageSize,
                  deviceAddress: Self.adding(deviceBaseAddress, pageSize),
                  byteCount: pageSize,
                  width: deviceAddressWidth,
                  coherency: coherency
              ),
              let receiveBuffers = Self.mapping(
                  cpuAddress: cpuBase + pageSize * 2,
                  deviceAddress: Self.adding(deviceBaseAddress, pageSize * 2),
                  byteCount: receiveBufferByteCount,
                  width: deviceAddressWidth,
                  coherency: coherency
              ),
              let transmitBuffer = Self.mapping(
                  cpuAddress: cpuBase + pageSize * 5,
                  deviceAddress: Self.adding(deviceBaseAddress, pageSize * 5),
                  byteCount: pageSize,
                  width: deviceAddressWidth,
                  coherency: coherency
              ),
              let storage = VirtIONetworkDMAStorage(
                  receiveQueue: receiveQueue,
                  receiveQueueSize: Self.receiveQueueSize,
                  transmitQueue: transmitQueue,
                  transmitQueueSize: Self.transmitQueueSize,
                  receiveBuffers: receiveBuffers,
                  transmitBuffer: transmitBuffer
              )
        else {
            return nil
        }

        self.allocation = allocation
        self.storage = storage
        receiveScratchAddress = cpuBase + pageSize * 6
        transmitScratchAddress = cpuBase + pageSize * 7
        scratchByteCount = pageSize
    }

    private static func mapping(
        cpuAddress: UInt64,
        deviceAddress: UInt64?,
        byteCount: UInt64,
        width: DMAAddressWidth,
        coherency: DMACoherency
    ) -> DMAMapping? {
        guard let deviceAddress else { return nil }
        return DMAMapping(
            cpuPhysicalAddress: cpuAddress,
            deviceAddress: deviceAddress,
            byteCount: byteCount,
            deviceAddressWidth: width,
            coherency: coherency
        )
    }

    private static func adding(_ left: UInt64, _ right: UInt64) -> UInt64? {
        guard right <= UInt64.max - left else { return nil }
        return left + right
    }
}
