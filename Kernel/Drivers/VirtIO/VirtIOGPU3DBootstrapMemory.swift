/// One short-lived, allocator-owned DMA workspace for the VirtIO-GPU 3D
/// bootstrap. The allocation domain and device address are supplied by the
/// platform; this type only validates and partitions them. QEMU currently uses
/// an identity device address, while a future translated transport can provide
/// a contiguous IOVA without changing the session.
struct VirtIOGPU3DBootstrapMemory: Equatable {
    static let commandArenaPageCount: UInt64 = 2
    static let requestPageCount: UInt64 = 2
    static let responsePageCount: UInt64 = 1
    static let pageCount = commandArenaPageCount
        + requestPageCount
        + responsePageCount

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
        let commandByteCount = pageSize * Self.commandArenaPageCount
        let requestByteCount = pageSize * Self.requestPageCount
        let requestDeviceAddress = deviceBaseAddress.addingReportingOverflow(
            commandByteCount
        )
        let responseDeviceAddress = deviceBaseAddress.addingReportingOverflow(
            commandByteCount + requestByteCount
        )
        guard !requestDeviceAddress.overflow,
              !responseDeviceAddress.overflow
        else {
            return nil
        }
        guard let command = DMAMapping(
                  cpuPhysicalAddress: cpuBase,
                  deviceAddress: deviceBaseAddress,
                  byteCount: commandByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let request = DMAMapping(
                  cpuPhysicalAddress: cpuBase + commandByteCount,
                  deviceAddress: requestDeviceAddress.partialValue,
                  byteCount: requestByteCount,
                  deviceAddressWidth: deviceAddressWidth,
                  coherency: coherency
              ),
              let response = DMAMapping(
                  cpuPhysicalAddress:
                    cpuBase + commandByteCount + requestByteCount,
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
