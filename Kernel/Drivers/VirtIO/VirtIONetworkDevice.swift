/// Register and DMA visibility boundary for a modern VirtIO-net MMIO device.
/// The concrete QEMU implementation performs volatile accesses and AArch64
/// barriers; host tests provide a deterministic in-memory implementation.
protocol VirtIONetworkRegisterAccess {
    func read8(at offset: UInt) -> UInt8
    func read16(at offset: UInt) -> UInt16
    func read32(at offset: UInt) -> UInt32
    func write32(_ value: UInt32, at offset: UInt)

    func loadDMAUInt16(at cpuAddress: UInt64) -> UInt16
    func storeDMAUInt16(_ value: UInt16, at cpuAddress: UInt64)
    func synchronizeDMA()
    func spinWaitHint()
}

enum VirtIONetworkMMIORegisterLayout {
    static let minimumApertureLength: UInt64 = 0x10c

    static let magic: UInt = 0x000
    static let version: UInt = 0x004
    static let deviceID: UInt = 0x008
    static let vendorID: UInt = 0x00c
    static let deviceFeatures: UInt = 0x010
    static let deviceFeaturesSelect: UInt = 0x014
    static let driverFeatures: UInt = 0x020
    static let driverFeaturesSelect: UInt = 0x024
    static let queueSelect: UInt = 0x030
    static let queueMaximum: UInt = 0x034
    static let queueSize: UInt = 0x038
    static let queueReady: UInt = 0x044
    static let queueNotify: UInt = 0x050
    static let interruptStatus: UInt = 0x060
    static let interruptAcknowledge: UInt = 0x064
    static let status: UInt = 0x070
    static let queueDescriptorLow: UInt = 0x080
    static let queueDescriptorHigh: UInt = 0x084
    static let queueDriverLow: UInt = 0x090
    static let queueDriverHigh: UInt = 0x094
    static let queueDeviceLow: UInt = 0x0a0
    static let queueDeviceHigh: UInt = 0x0a4
    static let configurationGeneration: UInt = 0x0fc
    static let deviceConfiguration: UInt = 0x100
}

struct VirtIONetworkMMIOIdentity: Equatable {
    let version: UInt32
    let deviceID: UInt32
    let vendorID: UInt32
}

enum VirtIONetworkInitializationResult: Equatable {
    case ready
    case invalidState
    case invalidPollLimit
    case wrongDevice
    case legacyTransport
    case deviceResetFailed
    case missingRequiredFeature
    case featureNegotiationFailed
    case queueUnavailable(index: UInt16)
    case invalidDeviceConfiguration
}

private enum VirtIONetworkDeviceState: UInt8 {
    case cold
    case ready
    case faulted
}

enum VirtIONetworkFeature {
    static let mtu: UInt64 = 1 << 3
    static let mac: UInt64 = 1 << 5
    static let mergeableReceiveBuffers: UInt64 = 1 << 15
    static let status: UInt64 = 1 << 16
}

enum VirtIONetworkConfiguration {
    static let defaultMTU: UInt16 = 1_500
    static let minimumSupportedMTU: UInt16 = 68
    static let maximumSupportedMTU: UInt16 = 1_500
    static let ethernetHeaderByteCount = 14
    // SwiftOS requires VIRTIO_NET_F_MRG_RXBUF so `num_buffers` is present.
    // A 1,536-byte buffer holds the largest supported Ethernet frame and its
    // header, so a conforming device must complete each supported frame in one
    // descriptor; larger or multi-buffer packets are rejected explicitly.
    static let virtioHeaderByteCount = 12
    static let packetBufferByteCount: UInt64 = 1_536
}

/// Network-specific size policy over the transport-neutral split-ring layout.
/// The trailing event fields retain their standard storage slots but are
/// ignored because this polling driver never negotiates EVENT_IDX.
struct VirtIONetworkSplitQueueLayout: Equatable {
    private let layout: VirtIOSplitQueueLayout

    var size: UInt16 { layout.size }
    var descriptorOffset: UInt64 { layout.descriptorOffset }
    var availableOffset: UInt64 { layout.availableOffset }
    var usedOffset: UInt64 { layout.usedOffset }
    var requiredByteCount: UInt64 { layout.requiredByteCount }

    init?(size: UInt16) {
        guard size <= 256,
              let layout = VirtIOSplitQueueLayout(size: size)
        else {
            return nil
        }
        self.layout = layout
    }
}

/// Caller-owned coherent storage for the RX and TX split rings and packet
/// buffers. The four mappings must be disjoint in both CPU and device address
/// spaces. QEMU `virt` advertises coherent VirtIO MMIO DMA; a non-coherent
/// physical NIC uses a different backend and cache-ownership policy.
struct VirtIONetworkDMAStorage: Equatable {
    let receiveQueue: DMAMapping
    let transmitQueue: DMAMapping
    let receiveBuffers: DMAMapping
    let transmitBuffer: DMAMapping
    let receiveQueueLayout: VirtIONetworkSplitQueueLayout
    let transmitQueueLayout: VirtIONetworkSplitQueueLayout

    init?(
        receiveQueue: DMAMapping,
        receiveQueueSize: UInt16,
        transmitQueue: DMAMapping,
        transmitQueueSize: UInt16,
        receiveBuffers: DMAMapping,
        transmitBuffer: DMAMapping
    ) {
        guard let receiveLayout = VirtIONetworkSplitQueueLayout(
                  size: receiveQueueSize
              ),
              let transmitLayout = VirtIONetworkSplitQueueLayout(
                  size: transmitQueueSize
              ),
              Self.isUsable(
                  receiveQueue,
                  minimumByteCount: receiveLayout.requiredByteCount,
                  alignment: 16
              ),
              Self.isUsable(
                  transmitQueue,
                  minimumByteCount: transmitLayout.requiredByteCount,
                  alignment: 16
              ),
              UInt64(receiveQueueSize)
                  <= UInt64.max / VirtIONetworkConfiguration.packetBufferByteCount,
              Self.isUsable(
                  receiveBuffers,
                  minimumByteCount: UInt64(receiveQueueSize)
                      * VirtIONetworkConfiguration.packetBufferByteCount,
                  alignment: 16
              ),
              Self.isUsable(
                  transmitBuffer,
                  minimumByteCount:
                      VirtIONetworkConfiguration.packetBufferByteCount,
                  alignment: 16
              ),
              Self.disjoint(receiveQueue, transmitQueue),
              Self.disjoint(receiveQueue, receiveBuffers),
              Self.disjoint(receiveQueue, transmitBuffer),
              Self.disjoint(transmitQueue, receiveBuffers),
              Self.disjoint(transmitQueue, transmitBuffer),
              Self.disjoint(receiveBuffers, transmitBuffer)
        else {
            return nil
        }
        self.receiveQueue = receiveQueue
        self.transmitQueue = transmitQueue
        self.receiveBuffers = receiveBuffers
        self.transmitBuffer = transmitBuffer
        receiveQueueLayout = receiveLayout
        transmitQueueLayout = transmitLayout
    }

    private static func isUsable(
        _ mapping: DMAMapping,
        minimumByteCount: UInt64,
        alignment: UInt64
    ) -> Bool {
        guard mapping.coherency == .hardwareCoherent,
              mapping.byteCount >= minimumByteCount,
              mapping.cpuPhysicalAddress > 0,
              mapping.cpuPhysicalAddress & (alignment - 1) == 0,
              mapping.deviceAddress & (alignment - 1) == 0,
              mapping.cpuPhysicalAddress <= UInt64(UInt.max),
              mapping.byteCount - 1
                  <= UInt64(UInt.max) - mapping.cpuPhysicalAddress
        else {
            return false
        }
        return true
    }

    private static func disjoint(_ first: DMAMapping, _ second: DMAMapping) -> Bool {
        !overlap(
            first.cpuPhysicalAddress,
            first.byteCount,
            second.cpuPhysicalAddress,
            second.byteCount
        ) && !overlap(
            first.deviceAddress,
            first.byteCount,
            second.deviceAddress,
            second.byteCount
        )
    }

    private static func overlap(
        _ firstAddress: UInt64,
        _ firstByteCount: UInt64,
        _ secondAddress: UInt64,
        _ secondByteCount: UInt64
    ) -> Bool {
        let firstLast = firstAddress + firstByteCount - 1
        let secondLast = secondAddress + secondByteCount - 1
        return firstAddress <= secondLast && secondAddress <= firstLast
    }
}

/// Modern VirtIO 1.x Ethernet device using RX queue 0 and TX queue 1. All
/// operations are bounded and polling. The device owns no allocator, timer,
/// interrupt-controller, IP, or board policy.
struct VirtIONetworkDevice<Registers: VirtIONetworkRegisterAccess>: NetworkLink {
    static var magicValue: UInt32 { 0x7472_6976 }
    static var modernVersion: UInt32 { 2 }
    static var networkDeviceID: UInt32 { 1 }

    private enum Status {
        static var acknowledge: UInt32 { 1 }
        static var driver: UInt32 { 2 }
        static var driverOK: UInt32 { 4 }
        static var featuresOK: UInt32 { 8 }
        static var deviceNeedsReset: UInt32 { 64 }
        static var failed: UInt32 { 128 }
    }

    private enum DescriptorFlag {
        static var deviceWrites: UInt16 { 2 }
    }

    private let registers: Registers
    private let storage: VirtIONetworkDMAStorage
    private let maximumPollCount: UInt64
    private var state: VirtIONetworkDeviceState = .cold
    private var receiveUsedIndex: UInt16 = 0
    private var receiveAvailableIndex: UInt16 = 0
    private var transmitUsedIndex: UInt16 = 0
    private var transmitAvailableIndex: UInt16 = 0

    private(set) var offeredFeatures: UInt64 = 0
    private(set) var negotiatedFeatures: UInt64 = 0
    private(set) var macAddress: MACAddress = .zero
    private(set) var mtu: UInt16 = VirtIONetworkConfiguration.defaultMTU

    init(
        registers: Registers,
        storage: VirtIONetworkDMAStorage,
        maximumPollCount: UInt64 = 5_000_000
    ) {
        self.registers = registers
        self.storage = storage
        self.maximumPollCount = maximumPollCount
    }

    var identity: VirtIONetworkMMIOIdentity {
        VirtIONetworkMMIOIdentity(
            version: registers.read32(
                at: VirtIONetworkMMIORegisterLayout.version
            ),
            deviceID: registers.read32(
                at: VirtIONetworkMMIORegisterLayout.deviceID
            ),
            vendorID: registers.read32(
                at: VirtIONetworkMMIORegisterLayout.vendorID
            )
        )
    }

    var linkState: NetworkLinkState {
        guard state == .ready else {
            return state == .faulted ? .faulted : .down
        }
        guard !deviceNeedsReset else { return .faulted }
        guard negotiatedFeatures & VirtIONetworkFeature.status != 0 else {
            return .up
        }
        let raw = registers.read16(
            at: VirtIONetworkMMIORegisterLayout.deviceConfiguration + 6
        )
        return raw & 1 != 0 ? .up : .down
    }

    mutating func initialize() -> VirtIONetworkInitializationResult {
        guard state == .cold else { return .invalidState }
        guard maximumPollCount > 0 else {
            return rejectInitialization(.invalidPollLimit)
        }
        guard registers.read32(at: VirtIONetworkMMIORegisterLayout.magic)
                == Self.magicValue,
              identity.deviceID == Self.networkDeviceID
        else {
            return rejectInitialization(.wrongDevice)
        }
        guard identity.version == Self.modernVersion else {
            return rejectInitialization(.legacyTransport)
        }

        registers.write32(0, at: VirtIONetworkMMIORegisterLayout.status)
        var resetPollCount: UInt64 = 0
        while resetPollCount < maximumPollCount,
              registers.read32(at: VirtIONetworkMMIORegisterLayout.status) != 0 {
            resetPollCount += 1
            registers.spinWaitHint()
        }
        guard resetPollCount < maximumPollCount else {
            return failInitialization(.deviceResetFailed)
        }
        guard zeroDMAStorage() else {
            return failInitialization(.invalidDeviceConfiguration)
        }
        var deviceStatus = Status.acknowledge
        registers.write32(deviceStatus, at: VirtIONetworkMMIORegisterLayout.status)
        deviceStatus |= Status.driver
        registers.write32(deviceStatus, at: VirtIONetworkMMIORegisterLayout.status)

        let offered = readDeviceFeatures()
        offeredFeatures = offered
        let required = VirtIOTransportFeature.version1
            | VirtIONetworkFeature.mac
            | VirtIONetworkFeature.mergeableReceiveBuffers
        let optional = VirtIONetworkFeature.status | VirtIONetworkFeature.mtu
        guard let selection = VirtIOFeatureSelection.select(
                  offered: offered,
                  required: required,
                  optional: optional
              )
        else {
            return failInitialization(.missingRequiredFeature)
        }
        negotiatedFeatures = selection.accepted
        writeDriverFeatures(selection.accepted)
        deviceStatus |= Status.featuresOK
        registers.write32(deviceStatus, at: VirtIONetworkMMIORegisterLayout.status)
        guard registers.read32(at: VirtIONetworkMMIORegisterLayout.status)
                & Status.featuresOK != 0
        else {
            return failInitialization(.featureNegotiationFailed)
        }

        guard readStableConfiguration(maximumAttempts: 8) else {
            return failInitialization(.invalidDeviceConfiguration)
        }
        guard configureQueue(
                  index: 0,
                  mapping: storage.receiveQueue,
                  layout: storage.receiveQueueLayout
              )
        else {
            return failInitialization(.queueUnavailable(index: 0))
        }
        guard configureQueue(
                  index: 1,
                  mapping: storage.transmitQueue,
                  layout: storage.transmitQueueLayout
              )
        else {
            return failInitialization(.queueUnavailable(index: 1))
        }
        prepareReceiveDescriptors()
        prepareTransmitQueue()

        deviceStatus |= Status.driverOK
        registers.synchronizeDMA()
        registers.write32(deviceStatus, at: VirtIONetworkMMIORegisterLayout.status)
        let completedStatus = registers.read32(
            at: VirtIONetworkMMIORegisterLayout.status
        )
        guard completedStatus & (Status.failed | Status.deviceNeedsReset) == 0,
              completedStatus & Status.driverOK != 0
        else {
            return failInitialization(.featureNegotiationFailed)
        }
        registers.write32(0, at: VirtIONetworkMMIORegisterLayout.queueNotify)
        state = .ready
        return .ready
    }

    mutating func pollReceive(
        into output: UnsafeMutableRawBufferPointer
    ) -> NetworkLinkReceiveResult {
        guard state == .ready else { return .deviceFault }
        guard !deviceNeedsReset else {
            faultDevice()
            return .deviceFault
        }
        let queue = storage.receiveQueue
        let layout = storage.receiveQueueLayout
        let observedUsedIndex = registers.loadDMAUInt16(
            at: queue.cpuPhysicalAddress + layout.usedOffset + 2
        )
        let pending = observedUsedIndex &- receiveUsedIndex
        guard pending > 0 else { return .noPacket }
        guard pending <= layout.size else {
            faultDevice()
            return .deviceFault
        }
        registers.synchronizeDMA()

        let usedSlot = UInt64(receiveUsedIndex % layout.size)
        let usedElement = queue.cpuPhysicalAddress
            + layout.usedOffset + 4 + usedSlot * 8
        let descriptorID = PhysicalBytes.readLE32(at: usedElement)
        let totalByteCount = PhysicalBytes.readLE32(at: usedElement + 4)
        receiveUsedIndex &+= 1
        guard descriptorID < UInt32(layout.size),
              totalByteCount >= UInt32(
                  VirtIONetworkConfiguration.virtioHeaderByteCount
                      + VirtIONetworkConfiguration.ethernetHeaderByteCount
              ),
              UInt64(totalByteCount)
                  <= VirtIONetworkConfiguration.packetBufferByteCount
        else {
            faultDevice()
            return .deviceFault
        }

        let packetAddress = storage.receiveBuffers.cpuPhysicalAddress
            + UInt64(descriptorID)
                * VirtIONetworkConfiguration.packetBufferByteCount
        guard validVirtioHeader(at: packetAddress) else {
            faultDevice()
            return .malformedFrame
        }
        let frameByteCount = Int(totalByteCount)
            - VirtIONetworkConfiguration.virtioHeaderByteCount
        guard frameByteCount
                <= VirtIONetworkConfiguration.ethernetHeaderByteCount + Int(mtu)
        else {
            faultDevice()
            return .malformedFrame
        }

        let result: NetworkLinkReceiveResult
        if output.count < frameByteCount ||
            (frameByteCount > 0 && output.baseAddress == nil) {
            result = .outputTooSmall(requiredByteCount: frameByteCount)
        } else {
            copyPhysicalBytes(
                from: packetAddress
                    + UInt64(VirtIONetworkConfiguration.virtioHeaderByteCount),
                into: output,
                byteCount: frameByteCount
            )
            result = .received(byteCount: frameByteCount)
        }
        recycleReceiveDescriptor(UInt16(descriptorID))
        acknowledgeInterrupts()
        return result
    }

    mutating func transmit(
        _ frame: UnsafeRawBufferPointer
    ) -> NetworkLinkTransmitResult {
        guard state == .ready else { return .deviceFault }
        guard !deviceNeedsReset else {
            faultDevice()
            return .deviceFault
        }
        guard linkState == .up else { return .linkDown }
        let maximumFrameByteCount =
            VirtIONetworkConfiguration.ethernetHeaderByteCount + Int(mtu)
        guard frame.count >= VirtIONetworkConfiguration.ethernetHeaderByteCount,
              frame.count <= maximumFrameByteCount,
              frame.baseAddress != nil
        else {
            return .invalidFrame
        }

        let packetAddress = storage.transmitBuffer.cpuPhysicalAddress
        var headerOffset = 0
        while headerOffset < VirtIONetworkConfiguration.virtioHeaderByteCount {
            PhysicalBytes.write8(0, at: packetAddress + UInt64(headerOffset))
            headerOffset += 1
        }
        var frameOffset = 0
        while frameOffset < frame.count {
            PhysicalBytes.write8(
                frame[frameOffset],
                at: packetAddress
                    + UInt64(VirtIONetworkConfiguration.virtioHeaderByteCount)
                    + UInt64(frameOffset)
            )
            frameOffset += 1
        }
        let submittedByteCount = UInt32(
            VirtIONetworkConfiguration.virtioHeaderByteCount + frame.count
        )
        writeDescriptor(
            queue: storage.transmitQueue,
            layout: storage.transmitQueueLayout,
            index: 0,
            deviceAddress: storage.transmitBuffer.deviceAddress,
            byteCount: submittedByteCount,
            flags: 0
        )
        let queue = storage.transmitQueue
        let layout = storage.transmitQueueLayout
        let availableSlot = UInt64(transmitAvailableIndex % layout.size)
        PhysicalBytes.writeLE16(
            0,
            at: queue.cpuPhysicalAddress
                + layout.availableOffset + 4 + availableSlot * 2
        )
        registers.synchronizeDMA()
        transmitAvailableIndex &+= 1
        registers.storeDMAUInt16(
            transmitAvailableIndex,
            at: queue.cpuPhysicalAddress + layout.availableOffset + 2
        )
        registers.synchronizeDMA()
        registers.write32(1, at: VirtIONetworkMMIORegisterLayout.queueNotify)

        let expectedUsedIndex = transmitUsedIndex &+ 1
        var pollCount: UInt64 = 0
        while pollCount < maximumPollCount {
            let observed = registers.loadDMAUInt16(
                at: queue.cpuPhysicalAddress + layout.usedOffset + 2
            )
            if observed == expectedUsedIndex {
                registers.synchronizeDMA()
                break
            }
            let pending = observed &- transmitUsedIndex
            if pending != 0 || deviceNeedsReset {
                faultDevice()
                return .deviceFault
            }
            pollCount += 1
            registers.spinWaitHint()
        }
        guard pollCount < maximumPollCount else {
            faultDevice()
            return .timedOut
        }

        let usedSlot = UInt64(transmitUsedIndex % layout.size)
        let usedElement = queue.cpuPhysicalAddress
            + layout.usedOffset + 4 + usedSlot * 8
        let descriptorID = PhysicalBytes.readLE32(at: usedElement)
        let deviceWrittenByteCount = PhysicalBytes.readLE32(at: usedElement + 4)
        guard descriptorID == 0,
              deviceWrittenByteCount == 0
        else {
            faultDevice()
            return .deviceFault
        }
        transmitUsedIndex = expectedUsedIndex
        acknowledgeInterrupts()
        return .sent
    }

    private var deviceNeedsReset: Bool {
        registers.read32(at: VirtIONetworkMMIORegisterLayout.status)
            & Status.deviceNeedsReset != 0
    }

    private mutating func failInitialization(
        _ result: VirtIONetworkInitializationResult
    ) -> VirtIONetworkInitializationResult {
        faultDevice()
        return result
    }

    private mutating func rejectInitialization(
        _ result: VirtIONetworkInitializationResult
    ) -> VirtIONetworkInitializationResult {
        state = .faulted
        return result
    }

    private mutating func faultDevice() {
        state = .faulted
        let current = registers.read32(at: VirtIONetworkMMIORegisterLayout.status)
        registers.write32(
            current | Status.failed,
            at: VirtIONetworkMMIORegisterLayout.status
        )
    }

    private func readDeviceFeatures() -> UInt64 {
        registers.write32(
            0,
            at: VirtIONetworkMMIORegisterLayout.deviceFeaturesSelect
        )
        let low = UInt64(
            registers.read32(at: VirtIONetworkMMIORegisterLayout.deviceFeatures)
        )
        registers.write32(
            1,
            at: VirtIONetworkMMIORegisterLayout.deviceFeaturesSelect
        )
        let high = UInt64(
            registers.read32(at: VirtIONetworkMMIORegisterLayout.deviceFeatures)
        )
        return low | high << 32
    }

    private func writeDriverFeatures(_ features: UInt64) {
        registers.write32(
            0,
            at: VirtIONetworkMMIORegisterLayout.driverFeaturesSelect
        )
        registers.write32(
            UInt32(truncatingIfNeeded: features),
            at: VirtIONetworkMMIORegisterLayout.driverFeatures
        )
        registers.write32(
            1,
            at: VirtIONetworkMMIORegisterLayout.driverFeaturesSelect
        )
        registers.write32(
            UInt32(truncatingIfNeeded: features >> 32),
            at: VirtIONetworkMMIORegisterLayout.driverFeatures
        )
    }

    private mutating func readStableConfiguration(
        maximumAttempts: Int
    ) -> Bool {
        var attempt = 0
        while attempt < maximumAttempts {
            let before = registers.read32(
                at: VirtIONetworkMMIORegisterLayout.configurationGeneration
            ) & 0xff
            let base = VirtIONetworkMMIORegisterLayout.deviceConfiguration
            let address = MACAddress(
                registers.read8(at: base),
                registers.read8(at: base + 1),
                registers.read8(at: base + 2),
                registers.read8(at: base + 3),
                registers.read8(at: base + 4),
                registers.read8(at: base + 5)
            )
            let discoveredMTU: UInt16
            if negotiatedFeatures & VirtIONetworkFeature.mtu != 0 {
                discoveredMTU = registers.read16(at: base + 10)
            } else {
                discoveredMTU = VirtIONetworkConfiguration.defaultMTU
            }
            let after = registers.read32(
                at: VirtIONetworkMMIORegisterLayout.configurationGeneration
            ) & 0xff
            if before == after {
                guard address.isUnicast,
                      discoveredMTU
                          >= VirtIONetworkConfiguration.minimumSupportedMTU,
                      discoveredMTU
                          <= VirtIONetworkConfiguration.maximumSupportedMTU
                else {
                    return false
                }
                macAddress = address
                mtu = discoveredMTU
                return true
            }
            attempt += 1
        }
        return false
    }

    private func configureQueue(
        index: UInt16,
        mapping: DMAMapping,
        layout: VirtIONetworkSplitQueueLayout
    ) -> Bool {
        registers.write32(
            UInt32(index),
            at: VirtIONetworkMMIORegisterLayout.queueSelect
        )
        guard registers.read32(at: VirtIONetworkMMIORegisterLayout.queueReady) == 0,
              registers.read32(at: VirtIONetworkMMIORegisterLayout.queueMaximum)
                  >= UInt32(layout.size)
        else {
            return false
        }
        registers.write32(
            UInt32(layout.size),
            at: VirtIONetworkMMIORegisterLayout.queueSize
        )
        writeAddress(
            mapping.deviceAddress + layout.descriptorOffset,
            low: VirtIONetworkMMIORegisterLayout.queueDescriptorLow,
            high: VirtIONetworkMMIORegisterLayout.queueDescriptorHigh
        )
        writeAddress(
            mapping.deviceAddress + layout.availableOffset,
            low: VirtIONetworkMMIORegisterLayout.queueDriverLow,
            high: VirtIONetworkMMIORegisterLayout.queueDriverHigh
        )
        writeAddress(
            mapping.deviceAddress + layout.usedOffset,
            low: VirtIONetworkMMIORegisterLayout.queueDeviceLow,
            high: VirtIONetworkMMIORegisterLayout.queueDeviceHigh
        )
        registers.synchronizeDMA()
        registers.write32(1, at: VirtIONetworkMMIORegisterLayout.queueReady)
        return registers.read32(at: VirtIONetworkMMIORegisterLayout.queueReady) == 1
    }

    private func writeAddress(_ value: UInt64, low: UInt, high: UInt) {
        registers.write32(UInt32(truncatingIfNeeded: value), at: low)
        registers.write32(UInt32(truncatingIfNeeded: value >> 32), at: high)
    }

    private mutating func prepareReceiveDescriptors() {
        let queue = storage.receiveQueue
        let layout = storage.receiveQueueLayout
        var index: UInt16 = 0
        PhysicalBytes.writeLE16(
            1,
            at: queue.cpuPhysicalAddress + layout.availableOffset
        )
        while index < layout.size {
            writeDescriptor(
                queue: queue,
                layout: layout,
                index: index,
                deviceAddress: storage.receiveBuffers.deviceAddress
                    + UInt64(index)
                        * VirtIONetworkConfiguration.packetBufferByteCount,
                byteCount: UInt32(
                    VirtIONetworkConfiguration.packetBufferByteCount
                ),
                flags: DescriptorFlag.deviceWrites
            )
            PhysicalBytes.writeLE16(
                index,
                at: queue.cpuPhysicalAddress
                    + layout.availableOffset + 4 + UInt64(index) * 2
            )
            index &+= 1
        }
        registers.synchronizeDMA()
        receiveAvailableIndex = layout.size
        registers.storeDMAUInt16(
            receiveAvailableIndex,
            at: queue.cpuPhysicalAddress + layout.availableOffset + 2
        )
        registers.synchronizeDMA()
    }

    private func prepareTransmitQueue() {
        PhysicalBytes.writeLE16(
            1,
            at: storage.transmitQueue.cpuPhysicalAddress
                + storage.transmitQueueLayout.availableOffset
        )
    }

    private func writeDescriptor(
        queue: DMAMapping,
        layout: VirtIONetworkSplitQueueLayout,
        index: UInt16,
        deviceAddress: UInt64,
        byteCount: UInt32,
        flags: UInt16
    ) {
        let address = queue.cpuPhysicalAddress
            + layout.descriptorOffset + UInt64(index) * 16
        PhysicalBytes.writeLE64(deviceAddress, at: address)
        PhysicalBytes.writeLE32(byteCount, at: address + 8)
        PhysicalBytes.writeLE16(flags, at: address + 12)
        PhysicalBytes.writeLE16(0, at: address + 14)
    }

    private mutating func recycleReceiveDescriptor(_ descriptorID: UInt16) {
        let queue = storage.receiveQueue
        let layout = storage.receiveQueueLayout
        let availableSlot = UInt64(receiveAvailableIndex % layout.size)
        PhysicalBytes.writeLE16(
            descriptorID,
            at: queue.cpuPhysicalAddress
                + layout.availableOffset + 4 + availableSlot * 2
        )
        registers.synchronizeDMA()
        receiveAvailableIndex &+= 1
        registers.storeDMAUInt16(
            receiveAvailableIndex,
            at: queue.cpuPhysicalAddress + layout.availableOffset + 2
        )
        registers.synchronizeDMA()
        registers.write32(0, at: VirtIONetworkMMIORegisterLayout.queueNotify)
    }

    private func validVirtioHeader(at address: UInt64) -> Bool {
        PhysicalBytes.read8(at: address) == 0
            && PhysicalBytes.read8(at: address + 1) == 0
            && PhysicalBytes.readLE16(at: address + 10) == 1
    }

    private func copyPhysicalBytes(
        from sourceAddress: UInt64,
        into output: UnsafeMutableRawBufferPointer,
        byteCount: Int
    ) {
        var index = 0
        while index < byteCount {
            output[index] = PhysicalBytes.read8(
                at: sourceAddress + UInt64(index)
            )
            index += 1
        }
    }

    private func acknowledgeInterrupts() {
        let pending = registers.read32(
            at: VirtIONetworkMMIORegisterLayout.interruptStatus
        )
        if pending != 0 {
            registers.write32(
                pending,
                at: VirtIONetworkMMIORegisterLayout.interruptAcknowledge
            )
        }
    }

    private func zeroDMAStorage() -> Bool {
        PhysicalBytes.zero(
            address: storage.receiveQueue.cpuPhysicalAddress,
            byteCount: storage.receiveQueueLayout.requiredByteCount
        ) && PhysicalBytes.zero(
            address: storage.transmitQueue.cpuPhysicalAddress,
            byteCount: storage.transmitQueueLayout.requiredByteCount
        ) && PhysicalBytes.zero(
            address: storage.transmitBuffer.cpuPhysicalAddress,
            byteCount: VirtIONetworkConfiguration.packetBufferByteCount
        )
    }
}
