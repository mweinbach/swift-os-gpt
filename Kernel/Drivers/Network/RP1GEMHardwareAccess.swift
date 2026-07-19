/// RP1-specific preparation remains injected. A later board policy can own the
/// clock controller, GPIO function selection, external PHY reset timing, and
/// PCIe/BAR sequencing without introducing any of those concerns into GEM.
protocol RP1GEMHardwarePreparation {
    mutating func prepareRP1Ethernet(
        maximumPollCount: UInt64
    ) -> CadenceGEMBoardPreparationResult
}

protocol RP1GEMConfigurationRegisterAccess {
    func read32(at offset: UInt) -> UInt32
}

enum RP1GEMConfigurationRegisterLayout {
    static let minimumApertureLength: UInt64 = 8
    static let status: UInt = 0x04
}

/// Combines an injected RP1 bring-up sequence with the read-only RGMII status
/// exported by ETH_CFG. The official RP1 status register also reports illegal
/// AXI burst lengths, which are promoted to a persistent link fault here.
struct RP1GEMBoardControl<
    Preparation: RP1GEMHardwarePreparation,
    StatusRegisters: RP1GEMConfigurationRegisterAccess
>: CadenceGEMBoardControl {
    private var preparation: Preparation
    private let statusRegisters: StatusRegisters

    init(preparation: Preparation, statusRegisters: StatusRegisters) {
        self.preparation = preparation
        self.statusRegisters = statusRegisters
    }

    mutating func prepareHardware(
        maximumPollCount: UInt64
    ) -> CadenceGEMBoardPreparationResult {
        preparation.prepareRP1Ethernet(maximumPollCount: maximumPollCount)
    }

    func currentLinkStatus() -> CadenceGEMBoardLinkStatus {
        let status = statusRegisters.read32(
            at: RP1GEMConfigurationRegisterLayout.status
        )
        let illegalAXIBurst = status & ((1 << 5) | (1 << 4)) != 0
        guard !illegalAXIBurst else { return .faulted }
        guard status & 1 != 0 else { return .down }

        let fullDuplex = status & (1 << 3) != 0
        switch (status >> 1) & 3 {
        case 0:
            return .up(
                fullDuplex ? .megabit10FullDuplex : .megabit10HalfDuplex
            )
        case 1:
            return .up(
                fullDuplex ? .megabit100FullDuplex : .megabit100HalfDuplex
            )
        case 2:
            return .up(
                fullDuplex ? .gigabitFullDuplex : .gigabitHalfDuplex
            )
        default:
            return .faulted
        }
    }
}

/// Volatile access to the Cadence GEM aperture discovered behind RP1's PCIe
/// endpoint. The resource is expected to have already crossed DT/PCIe address
/// translation; this type never embeds a Raspberry Pi physical address.
struct RP1GEMMMIORegisterAccess: CadenceGEMRegisterAccess {
    private let baseAddress: UInt

    init?(resource: DeviceResource) {
        guard resource.baseAddress <= UInt64(UInt.max),
              resource.baseAddress & 3 == 0,
              resource.length >= CadenceGEMRegisterLayout.minimumApertureLength,
              resource.length <= UInt64.max - resource.baseAddress
        else {
            return nil
        }
        baseAddress = UInt(resource.baseAddress)
    }

    @inline(__always)
    func read32(at offset: UInt) -> UInt32 {
        MMIO.load32(at: baseAddress + offset)
    }

    @inline(__always)
    mutating func write32(_ value: UInt32, at offset: UInt) {
        MMIO.store32(value, at: baseAddress + offset)
        // RP1 register writes are posted across PCIe. A same-aperture readback
        // prevents a later ownership transition from passing the write.
        _ = MMIO.load32(at: baseAddress + offset)
    }

    @inline(__always)
    func counterValue() -> UInt64 {
        AArch64.counterValue
    }

    @inline(__always)
    func spinWaitHint() {
        AArch64.spinHint()
    }
}

/// Volatile view of RP1 ETH_CFG, separate from the Cadence GEM aperture.
struct RP1GEMConfigurationMMIORegisterAccess:
    RP1GEMConfigurationRegisterAccess
{
    private let baseAddress: UInt

    init?(resource: DeviceResource) {
        guard resource.baseAddress <= UInt64(UInt.max),
              resource.baseAddress & 3 == 0,
              resource.length
                  >= RP1GEMConfigurationRegisterLayout.minimumApertureLength,
              resource.length <= UInt64.max - resource.baseAddress
        else {
            return nil
        }
        baseAddress = UInt(resource.baseAddress)
    }

    @inline(__always)
    func read32(at offset: UInt) -> UInt32 {
        MMIO.load32(at: baseAddress + offset)
    }
}

/// CPU-side access for descriptor pages mapped non-cacheable and packet pages
/// identity-mapped write-back. The page-table owner must establish those exact
/// attributes before constructing `CadenceGEMDMARegion` values.
struct RP1GEMSoftwareManagedDMAAccess: CadenceGEMDMAAccess {
    @inline(__always)
    func loadDescriptorWord(at cpuAddress: UInt64) -> UInt32 {
        MMIO.load32(at: UInt(cpuAddress))
    }

    @inline(__always)
    mutating func storeDescriptorWord(
        _ value: UInt32,
        at cpuAddress: UInt64
    ) {
        MMIO.store32(value, at: UInt(cpuAddress))
    }

    func copyIntoDMA(
        _ source: UnsafeRawBufferPointer,
        destinationCPUAddress: UInt64
    ) -> Bool {
        guard source.count > 0,
              source.baseAddress != nil,
              destinationCPUAddress <= UInt64(UInt.max),
              UInt64(source.count) <= UInt64.max - destinationCPUAddress,
              let destination = UnsafeMutableRawPointer(
                  bitPattern: UInt(destinationCPUAddress)
              )
        else {
            return false
        }
        var index = 0
        while index < source.count {
            destination.storeBytes(
                of: source[index],
                toByteOffset: index,
                as: UInt8.self
            )
            index += 1
        }
        return true
    }

    func copyFromDMA(
        sourceCPUAddress: UInt64,
        byteCount: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard byteCount > 0,
              destination.count >= byteCount,
              destination.baseAddress != nil,
              sourceCPUAddress <= UInt64(UInt.max),
              UInt64(byteCount) <= UInt64.max - sourceCPUAddress,
              let source = UnsafeRawPointer(
                  bitPattern: UInt(sourceCPUAddress)
              )
        else {
            return false
        }
        var index = 0
        while index < byteCount {
            destination[index] = source.load(
                fromByteOffset: index,
                as: UInt8.self
            )
            index += 1
        }
        return true
    }

    @inline(__always)
    mutating func cleanForDevice(
        cpuAddress: UInt64,
        byteCount: UInt64
    ) -> Bool {
        AArch64.cleanDataCache(address: cpuAddress, byteCount: byteCount)
    }

    @inline(__always)
    mutating func invalidateForCPU(
        cpuAddress: UInt64,
        byteCount: UInt64
    ) -> Bool {
        AArch64.invalidateDataCache(address: cpuAddress, byteCount: byteCount)
    }

    @inline(__always)
    mutating func synchronizeOwnership() {
        AArch64.synchronizeData()
    }
}
