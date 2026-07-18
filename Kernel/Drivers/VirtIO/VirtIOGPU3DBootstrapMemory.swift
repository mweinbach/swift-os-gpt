/// One short-lived, allocator-owned DMA workspace for the VirtIO-GPU 3D
/// bootstrap. The allocation domain and device address are supplied by the
/// platform; this type only validates and partitions them. QEMU currently uses
/// an identity device address, while a future translated transport can provide
/// a contiguous IOVA without changing the session.
struct VirtIOGPU3DBootstrapMemory: Equatable {
    static let pageCount: UInt64 = 3

    let allocation: ClassifiedPageAllocationToken
    let commandArena: DMAMapping
    let request: DMAMapping
    let response: DMAMapping

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
              coherency != .hardwareCoherent
                || allocation.classification.capabilities.contains(
                    .cacheCoherent
                ),
              MemoryPageGeometry.isPageAligned(deviceBaseAddress)
        else {
            return nil
        }

        let pageSize = MemoryPageGeometry.pageSize
        let cpuBase = allocation.range.baseAddress
        let requestDeviceAddress = deviceBaseAddress.addingReportingOverflow(
            pageSize
        )
        let responseDeviceAddress = deviceBaseAddress.addingReportingOverflow(
            pageSize * 2
        )
        guard !requestDeviceAddress.overflow,
              !responseDeviceAddress.overflow
        else {
            return nil
        }
        guard let command = DMAMapping(
                  cpuPhysicalAddress: cpuBase,
                  deviceAddress: deviceBaseAddress,
                  byteCount: pageSize,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let request = DMAMapping(
                  cpuPhysicalAddress: cpuBase + pageSize,
                  deviceAddress: requestDeviceAddress.partialValue,
                  byteCount: pageSize,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let response = DMAMapping(
                  cpuPhysicalAddress: cpuBase + pageSize * 2,
                  deviceAddress: responseDeviceAddress.partialValue,
                  byteCount: pageSize,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              )
        else {
            return nil
        }

        self.allocation = allocation
        commandArena = command
        self.request = request
        self.response = response
    }
}
