/// GICv3 driver using a device-tree distributor/redistributor description and
/// the architectural system-register CPU interface.
struct GICv3: InterruptControllerDriver {
    private static let distributorControl: UInt64 = 0x000
    private static let distributorEnableClear: UInt64 = 0x180
    private static let distributorRWP: UInt32 = 1 << 31
    private static let affinityRoutingNonSecure: UInt32 = 1 << 4
    private static let enableGroup1NonSecure: UInt32 = 1

    private static let redistributorType: UInt64 = 0x008
    private static let redistributorWaker: UInt64 = 0x014
    private static let redistributorFrameSize: UInt64 = 0x20_000
    private static let redistributorVLPIFrameSize: UInt64 = 0x40_000
    private static let redistributorSGIOffset: UInt64 = 0x10_000
    private static let processorSleep: UInt32 = 1 << 1
    private static let childrenAsleep: UInt32 = 1 << 2
    private static let redistributorLast: UInt64 = 1 << 4
    private static let supportsVLPIs: UInt64 = 1 << 1

    private static let interruptGroup: UInt64 = 0x080
    private static let enableSet: UInt64 = 0x100
    private static let enableClear: UInt64 = 0x180
    private static let pendingClear: UInt64 = 0x280
    private static let priority: UInt64 = 0x400
    private static let configuration1: UInt64 = 0xc04

    private static let maximumPollCount = 100_000
    private static let maximumRedistributorCount = 256

    private let configurationValue: GICv3Configuration
    private var redistributorBase: UInt64 = 0

    var timerInterruptID: UInt32 {
        configurationValue.timerInterruptID
    }

    init(configuration: GICv3Configuration) {
        configurationValue = configuration
    }

    mutating func initialize() -> Bool {
        guard validResource(configurationValue.distributor),
              validResource(configurationValue.redistributor),
              contains(
                  configurationValue.distributor,
                  offset: Self.distributorControl,
                  width: 4
              ),
              timerInterruptID >= 16,
              timerInterruptID < 32,
              let frame = findRedistributor(
                  affinity: AArch64.redistributorAffinity
              )
        else {
            return false
        }
        redistributorBase = frame

        guard wakeRedistributor(),
              AArch64.enableGICv3SystemRegisters()
        else {
            return false
        }
        AArch64.prepareGICv3Control()
        AArch64.setGICv3Group1Enabled(false)

        let sgiBase = UInt(redistributorBase + Self.redistributorSGIOffset)
        let timerBit = UInt32(1) << (timerInterruptID & 31)
        MMIO.store32(timerBit, at: sgiBase + UInt(Self.enableClear))

        let group = MMIO.load32(at: sgiBase + UInt(Self.interruptGroup))
        MMIO.store32(
            group | timerBit,
            at: sgiBase + UInt(Self.interruptGroup)
        )
        MMIO.store32(timerBit, at: sgiBase + UInt(Self.pendingClear))
        MMIO.store8(
            0x80,
            at: sgiBase + UInt(Self.priority) + UInt(timerInterruptID)
        )

        let triggerShift = UInt32((timerInterruptID - 16) * 2 + 1)
        var trigger = MMIO.load32(
            at: sgiBase + UInt(Self.configuration1)
        )
        trigger &= ~(UInt32(1) << triggerShift)
        MMIO.store32(
            trigger,
            at: sgiBase + UInt(Self.configuration1)
        )
        MMIO.store32(timerBit, at: sgiBase + UInt(Self.enableSet))

        guard enableDistributor() else {
            return false
        }
        AArch64.setGICv3PriorityMask(0xff)
        AArch64.setGICv3BinaryPoint(0)
        AArch64.setGICv3Group1Enabled(true)
        AArch64.synchronizeData()
        return true
    }

    @inline(__always)
    func acknowledge() -> InterruptAcknowledgeToken? {
        let raw = AArch64.acknowledgeGICv3Group1()
        let interruptID = UInt32(truncatingIfNeeded: raw & 0x00ff_ffff)
        guard interruptID < 1_020 else {
            return nil
        }
        return InterruptAcknowledgeToken(
            rawValue: raw,
            interruptID: interruptID
        )
    }

    @inline(__always)
    func end(_ token: InterruptAcknowledgeToken) {
        AArch64.endGICv3Group1(token.rawValue)
    }

    func disable(interruptID: UInt32) {
        if interruptID < 32 {
            guard redistributorBase != 0 else { return }
            MMIO.store32(
                UInt32(1) << interruptID,
                at: UInt(redistributorBase + Self.redistributorSGIOffset)
                    + UInt(Self.enableClear)
            )
        } else if interruptID < 1_020 {
            let registerOffset = Self.distributorEnableClear
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
        } else {
            // LPIs require ITS property-table management, which is outside this
            // controller's present scope. They are still EOIed by the caller.
            return
        }
        AArch64.synchronizeData()
    }

    private mutating func findRedistributor(
        affinity: UInt32
    ) -> UInt64? {
        var offset: UInt64 = 0
        var inspected = 0
        while inspected < Self.maximumRedistributorCount,
              contains(
                  configurationValue.redistributor,
                  offset: offset + Self.redistributorType,
                  width: 8
              ) {
            let frame = configurationValue.redistributor.baseAddress + offset
            let type = MMIO.load64(
                at: UInt(frame + Self.redistributorType)
            )
            if UInt32(truncatingIfNeeded: type >> 32) == affinity {
                guard contains(
                    configurationValue.redistributor,
                    offset: offset + Self.redistributorSGIOffset,
                    width: Self.configuration1 + 4
                ) else {
                    return nil
                }
                return frame
            }
            if type & Self.redistributorLast != 0 {
                return nil
            }
            let stride = type & Self.supportsVLPIs == 0
                ? Self.redistributorFrameSize
                : Self.redistributorVLPIFrameSize
            guard offset <= UInt64.max - stride else { return nil }
            offset += stride
            inspected += 1
        }
        return nil
    }

    private func wakeRedistributor() -> Bool {
        let wakerAddress = UInt(
            redistributorBase + Self.redistributorWaker
        )
        var waker = MMIO.load32(at: wakerAddress)
        waker &= ~Self.processorSleep
        MMIO.store32(waker, at: wakerAddress)
        AArch64.synchronizeData()

        var pollCount = 0
        while pollCount < Self.maximumPollCount {
            if MMIO.load32(at: wakerAddress) & Self.childrenAsleep == 0 {
                return true
            }
            AArch64.spinHint()
            pollCount += 1
        }
        return false
    }

    private func enableDistributor() -> Bool {
        let controlAddress = UInt(
            configurationValue.distributor.baseAddress
                + Self.distributorControl
        )
        var control = MMIO.load32(at: controlAddress)
        if control & Self.affinityRoutingNonSecure == 0 {
            // Affinity routing can only change while Group 1 delivery is off.
            control &= ~Self.enableGroup1NonSecure
            MMIO.store32(control, at: controlAddress)
            guard waitForDistributorWrites() else { return false }
            control |= Self.affinityRoutingNonSecure
            MMIO.store32(control, at: controlAddress)
            guard waitForDistributorWrites() else { return false }
        }
        control |= Self.enableGroup1NonSecure
        MMIO.store32(control, at: controlAddress)
        return waitForDistributorWrites()
    }

    private func waitForDistributorWrites() -> Bool {
        let controlAddress = UInt(
            configurationValue.distributor.baseAddress
                + Self.distributorControl
        )
        var pollCount = 0
        while pollCount < Self.maximumPollCount {
            if MMIO.load32(at: controlAddress) & Self.distributorRWP == 0 {
                return true
            }
            AArch64.spinHint()
            pollCount += 1
        }
        return false
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
