struct VirtIONetworkMMIORegisterAccess: VirtIONetworkRegisterAccess {
    private let baseAddress: UInt

    init?(resource: DeviceResource) {
        guard resource.baseAddress <= UInt64(UInt.max),
              resource.baseAddress & 0x3 == 0,
              resource.length
                  >= VirtIONetworkMMIORegisterLayout.minimumApertureLength,
              resource.length <= UInt64.max - resource.baseAddress
        else {
            return nil
        }
        baseAddress = UInt(resource.baseAddress)
    }

    @inline(__always)
    func read8(at offset: UInt) -> UInt8 {
        MMIO.load8(at: baseAddress + offset)
    }

    @inline(__always)
    func read16(at offset: UInt) -> UInt16 {
        MMIO.load16(at: baseAddress + offset)
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

typealias VirtIONetworkMMIODevice =
    VirtIONetworkDevice<VirtIONetworkMMIORegisterAccess>

extension VirtIONetworkDevice
where Registers == VirtIONetworkMMIORegisterAccess {
    init?(
        resource: DeviceResource,
        storage: VirtIONetworkDMAStorage,
        maximumPollCount: UInt64 = 5_000_000
    ) {
        guard let registers = VirtIONetworkMMIORegisterAccess(resource: resource)
        else {
            return nil
        }
        self.init(
            registers: registers,
            storage: storage,
            maximumPollCount: maximumPollCount
        )
    }
}
