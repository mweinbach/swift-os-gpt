/// GICv2 driver for the memory-mapped CPU interface used by BCM2712's GIC-400.
struct GICv2: InterruptControllerDriver {
    private static let distributorControl: UInt64 = 0x000
    private static let interruptGroup: UInt64 = 0x080
    private static let enableSet: UInt64 = 0x100
    private static let enableClear: UInt64 = 0x180
    private static let pendingClear: UInt64 = 0x280
    private static let priority: UInt64 = 0x400
    private static let configuration: UInt64 = 0xc00

    private static let cpuControl: UInt64 = 0x000
    private static let cpuPriorityMask: UInt64 = 0x004
    private static let cpuBinaryPoint: UInt64 = 0x008
    private static let cpuAcknowledge: UInt64 = 0x00c
    private static let cpuEndOfInterrupt: UInt64 = 0x010

    private let configurationValue: GICv2Configuration

    var timerInterruptID: UInt32 {
        configurationValue.timerInterruptID
    }

    init(configuration: GICv2Configuration) {
        configurationValue = configuration
    }

    mutating func initialize() -> Bool {
        guard validResource(configurationValue.distributor),
              validResource(configurationValue.cpuInterface),
              contains(
                  configurationValue.distributor,
                  offset: Self.configuration + 4,
                  width: 4
              ),
              contains(
                  configurationValue.cpuInterface,
                  offset: Self.cpuEndOfInterrupt,
                  width: 4
              ),
              timerInterruptID >= 16,
              timerInterruptID < 32
        else {
            return false
        }

        let distributor = UInt(configurationValue.distributor.baseAddress)
        let cpu = UInt(configurationValue.cpuInterface.baseAddress)
        let timerBit = UInt32(1) << (timerInterruptID & 31)

        MMIO.store32(0, at: cpu + UInt(Self.cpuControl))

        // Banked PPI state belongs to the current processing element.
        MMIO.store32(
            timerBit,
            at: distributor + UInt(Self.enableClear)
        )
        let group = MMIO.load32(
            at: distributor + UInt(Self.interruptGroup)
        )
        MMIO.store32(
            group | timerBit,
            at: distributor + UInt(Self.interruptGroup)
        )
        MMIO.store32(
            timerBit,
            at: distributor + UInt(Self.pendingClear)
        )
        MMIO.store8(
            0x80,
            at: distributor + UInt(Self.priority) + UInt(timerInterruptID)
        )

        let configurationOffset = Self.configuration + 4
        let triggerShift = UInt32((timerInterruptID - 16) * 2 + 1)
        var trigger = MMIO.load32(
            at: distributor + UInt(configurationOffset)
        )
        trigger &= ~(UInt32(1) << triggerShift)
        MMIO.store32(
            trigger,
            at: distributor + UInt(configurationOffset)
        )

        MMIO.store32(
            timerBit,
            at: distributor + UInt(Self.enableSet)
        )
        MMIO.store32(0xff, at: cpu + UInt(Self.cpuPriorityMask))
        MMIO.store32(0, at: cpu + UInt(Self.cpuBinaryPoint))

        // In a non-secure view, bit zero enables delivery of Group 1 IRQs.
        MMIO.store32(1, at: distributor + UInt(Self.distributorControl))
        MMIO.store32(1, at: cpu + UInt(Self.cpuControl))
        AArch64.synchronizeData()
        return true
    }

    @inline(__always)
    func acknowledge() -> InterruptAcknowledgeToken? {
        let raw = MMIO.load32(
            at: UInt(configurationValue.cpuInterface.baseAddress)
                + UInt(Self.cpuAcknowledge)
        )
        let interruptID = raw & 0x3ff
        guard interruptID < 1_020 else {
            return nil
        }
        return InterruptAcknowledgeToken(
            rawValue: UInt64(raw),
            interruptID: interruptID
        )
    }

    @inline(__always)
    func end(_ token: InterruptAcknowledgeToken) {
        MMIO.store32(
            UInt32(truncatingIfNeeded: token.rawValue),
            at: UInt(configurationValue.cpuInterface.baseAddress)
                + UInt(Self.cpuEndOfInterrupt)
        )
    }

    func disable(interruptID: UInt32) {
        guard interruptID < 1_020 else { return }
        let registerOffset = Self.enableClear
            + UInt64(interruptID / 32) * 4
        guard contains(
            configurationValue.distributor,
            offset: registerOffset,
            width: 4
        ) else {
            return
        }
        MMIO.store32(
            UInt32(1) << (interruptID & 31),
            at: UInt(configurationValue.distributor.baseAddress)
                + UInt(registerOffset)
        )
        AArch64.synchronizeData()
    }

    private func validResource(_ resource: DeviceResource) -> Bool {
        resource.baseAddress != 0
            && resource.baseAddress <= UInt64(UInt.max)
            && resource.length <= UInt64(UInt.max)
    }

    private func contains(
        _ resource: DeviceResource,
        offset: UInt64,
        width: UInt64
    ) -> Bool {
        offset <= resource.length
            && width <= resource.length - offset
            && resource.baseAddress <= UInt64.max - offset
            && resource.baseAddress + offset <= UInt64(UInt.max)
    }
}
