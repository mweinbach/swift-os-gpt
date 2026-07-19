struct VirtIOBlockMMIORegisterAccess: VirtIOBlockRegisterAccess {
    private let baseAddress: UInt

    init?(resource: DeviceResource) {
        guard resource.baseAddress <= UInt64(UInt.max),
              resource.baseAddress & 0x3 == 0,
              resource.length
                >= VirtIOBlockMMIORegisterLayout.minimumApertureLength,
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
    func write32(_ value: UInt32, at offset: UInt) {
        MMIO.store32(value, at: baseAddress + offset)
    }

    @inline(__always)
    func loadDMAUInt16(at cpuAddress: UInt64) -> UInt16 {
        MMIO.load16(at: UInt(cpuAddress))
    }

    @inline(__always)
    func storeDMAUInt16(_ value: UInt16, at cpuAddress: UInt64) {
        MMIO.store16(value, at: UInt(cpuAddress))
    }

    @inline(__always)
    func synchronizeDMA() {
        AArch64.synchronizeData()
    }

    @inline(__always)
    func spinWaitHint() {
        AArch64.spinHint()
    }
}

typealias VirtIOBlockMMIODevice =
    VirtIOBlockDevice<VirtIOBlockMMIORegisterAccess>

extension VirtIOBlockDevice
where Registers == VirtIOBlockMMIORegisterAccess {
    static func initialize(
        resource: DeviceResource,
        storage: VirtIOBlockDMAStorage,
        maximumPollCount: UInt64 = 5_000_000
    ) -> VirtIOBlockInitializationResult<VirtIOBlockMMIORegisterAccess> {
        guard let registers = VirtIOBlockMMIORegisterAccess(resource: resource)
        else {
            return .failure(.wrongDevice)
        }
        return initialize(
            registers: registers,
            storage: storage,
            maximumPollCount: maximumPollCount
        )
    }
}
