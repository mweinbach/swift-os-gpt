/// Register and DMA visibility boundary for one modern VirtIO block device.
/// The production implementation performs volatile MMIO accesses; host tests
/// model the device while exercising exactly the same queue policy.
protocol VirtIOBlockRegisterAccess {
    func read32(at offset: UInt) -> UInt32
    func write32(_ value: UInt32, at offset: UInt)

    func loadDMAUInt16(at cpuAddress: UInt64) -> UInt16
    func storeDMAUInt16(_ value: UInt16, at cpuAddress: UInt64)
    func synchronizeDMA()
    func spinWaitHint()
}

enum VirtIOBlockMMIORegisterLayout {
    static let minimumApertureLength: UInt64 = 0x108

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

struct VirtIOBlockMMIOIdentity: Equatable {
    let version: UInt32
    let deviceID: UInt32
    let vendorID: UInt32
}

/// Caller-owned coherent memory for one synchronous request. SwiftOS exposes
/// 512-byte logical blocks even if a device advertises a larger preferred I/O
/// size, which keeps the generic BlockDevice contract compatible with SDHCI.
struct VirtIOBlockDMAStorage: Equatable {
    static let requestQueueSize: UInt16 = 8
    static let requestHeaderByteCount: UInt64 = 16
    static let dataByteCount: UInt64 = 512
    static let statusByteCount: UInt64 = 1

    let requestQueue: DMAMapping
    let requestHeader: DMAMapping
    let data: DMAMapping
    let status: DMAMapping
    let requestQueueLayout: VirtIOSplitQueueLayout

    init?(
        requestQueue: DMAMapping,
        requestHeader: DMAMapping,
        data: DMAMapping,
        status: DMAMapping
    ) {
        guard let layout = VirtIOSplitQueueLayout(
                  size: Self.requestQueueSize
              ),
              Self.isUsable(
                  requestQueue,
                  minimumByteCount: layout.requiredByteCount,
                  alignment: 16
              ),
              Self.isUsable(
                  requestHeader,
                  minimumByteCount: Self.requestHeaderByteCount,
                  alignment: 8
              ),
              Self.isUsable(
                  data,
                  minimumByteCount: Self.dataByteCount,
                  alignment: 16
              ),
              Self.isUsable(
                  status,
                  minimumByteCount: Self.statusByteCount,
                  alignment: 1
              ),
              Self.allDisjoint(
                  requestQueue,
                  requestHeader,
                  data,
                  status
              )
        else {
            return nil
        }
        self.requestQueue = requestQueue
        self.requestHeader = requestHeader
        self.data = data
        self.status = status
        requestQueueLayout = layout
    }

    private static func isUsable(
        _ mapping: DMAMapping,
        minimumByteCount: UInt64,
        alignment: UInt64
    ) -> Bool {
        mapping.coherency == .hardwareCoherent
            && mapping.byteCount >= minimumByteCount
            && mapping.cpuPhysicalAddress > 0
            && mapping.cpuPhysicalAddress & (alignment - 1) == 0
            && mapping.deviceAddress & (alignment - 1) == 0
            && mapping.cpuPhysicalAddress <= UInt64(UInt.max)
            && mapping.byteCount - 1
                <= UInt64(UInt.max) - mapping.cpuPhysicalAddress
    }

    private static func allDisjoint(
        _ first: DMAMapping,
        _ second: DMAMapping,
        _ third: DMAMapping,
        _ fourth: DMAMapping
    ) -> Bool {
        let mappings = (first, second, third, fourth)
        return disjoint(mappings.0, mappings.1)
            && disjoint(mappings.0, mappings.2)
            && disjoint(mappings.0, mappings.3)
            && disjoint(mappings.1, mappings.2)
            && disjoint(mappings.1, mappings.3)
            && disjoint(mappings.2, mappings.3)
    }

    private static func disjoint(
        _ first: DMAMapping,
        _ second: DMAMapping
    ) -> Bool {
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

enum VirtIOBlockInitializationFailure: Equatable {
    case invalidPollLimit
    case invalidDMAStorage
    case wrongDevice
    case legacyTransport
    case deviceResetFailed
    case missingRequiredFeature
    case featureNegotiationFailed
    case unstableConfiguration
    case invalidCapacity
    case queueUnavailable
    /// Reset did not complete after queue memory was published. The caller
    /// must retain the DMA storage until a later reset attempt succeeds or a
    /// platform reset makes device access impossible.
    case dmaStorageQuarantineRequired

    var dmaStorageDisposition: VirtIOBlockDMAStorageDisposition {
        switch self {
        case .invalidPollLimit, .invalidDMAStorage, .wrongDevice,
             .legacyTransport, .deviceResetFailed, .missingRequiredFeature,
             .featureNegotiationFailed, .unstableConfiguration,
             .invalidCapacity, .queueUnavailable:
            return .safeToRelease
        case .dmaStorageQuarantineRequired:
            return .quarantineRequired
        }
    }
}

enum VirtIOBlockInitializationResult<Registers: VirtIOBlockRegisterAccess> {
    case ready(VirtIOBlockDevice<Registers>)
    case failure(VirtIOBlockInitializationFailure)
}

/// Whether caller-owned DMA storage can be returned to the allocator.
///
/// A live device can still observe its queue. Quarantined storage must remain
/// allocated until a later `teardown()` call observes reset completion, or an
/// out-of-band platform reset provides the same guarantee.
enum VirtIOBlockDMAStorageDisposition: UInt8, Equatable {
    case deviceMayAccess
    case safeToRelease
    case quarantineRequired
}

private enum VirtIOBlockDeviceState: UInt8 {
    case ready
    case reset
    case quarantined
}

private enum VirtIOBlockQueueConfigurationResult: UInt8 {
    case ready
    case unavailable
    case storagePublished
}

/// Modern VirtIO 1.x block device using one bounded synchronous request queue.
/// Transport DMA never sees caller buffers: each complete logical block is
/// copied through the allocator-owned bounce page before or after queue use.
struct VirtIOBlockDevice<Registers: VirtIOBlockRegisterAccess>: BlockDevice {
    static var magicValue: UInt32 { 0x7472_6976 }
    static var modernVersion: UInt32 { 2 }
    static var blockDeviceID: UInt32 { 2 }

    private enum Status {
        static var acknowledge: UInt32 { 1 }
        static var driver: UInt32 { 2 }
        static var driverOK: UInt32 { 4 }
        static var featuresOK: UInt32 { 8 }
        static var deviceNeedsReset: UInt32 { 64 }
        static var failed: UInt32 { 128 }
    }

    private enum Interrupt {
        static var usedBuffer: UInt32 { 1 }
        static var configurationChanged: UInt32 { 2 }
        static var known: UInt32 { usedBuffer | configurationChanged }
    }

    private enum Feature {
        static var readOnly: UInt64 { 1 << 5 }
        static var flush: UInt64 { 1 << 9 }
        static var supportedOptional: UInt64 { readOnly | flush }
    }

    private enum RequestType {
        static var read: UInt32 { 0 }
        static var write: UInt32 { 1 }
        static var flush: UInt32 { 4 }
    }

    private enum RequestStatus {
        static var success: UInt8 { 0 }
        static var ioError: UInt8 { 1 }
        static var unsupported: UInt8 { 2 }
        static var pending: UInt8 { 0xff }
    }

    private enum DescriptorFlag {
        static var next: UInt16 { 1 }
        static var deviceWrites: UInt16 { 2 }
    }

    private enum AvailableFlag {
        static var noInterrupt: UInt16 { 1 }
    }

    private let registers: Registers
    private let storage: VirtIOBlockDMAStorage
    private let maximumPollCount: UInt64
    private var state: VirtIOBlockDeviceState
    private var availableIndex: UInt16
    private var usedIndex: UInt16

    let geometry: BlockDeviceGeometry
    let isReadOnly: Bool
    let supportsFlush: Bool
    let offeredFeatures: UInt64
    let negotiatedFeatures: UInt64

    var dmaStorageDisposition: VirtIOBlockDMAStorageDisposition {
        switch state {
        case .ready:
            return .deviceMayAccess
        case .reset:
            return .safeToRelease
        case .quarantined:
            return .quarantineRequired
        }
    }

    private init(
        registers: Registers,
        storage: VirtIOBlockDMAStorage,
        maximumPollCount: UInt64,
        geometry: BlockDeviceGeometry,
        isReadOnly: Bool,
        supportsFlush: Bool,
        offeredFeatures: UInt64,
        negotiatedFeatures: UInt64,
        state: VirtIOBlockDeviceState,
        availableIndex: UInt16,
        usedIndex: UInt16
    ) {
        self.registers = registers
        self.storage = storage
        self.maximumPollCount = maximumPollCount
        self.geometry = geometry
        self.isReadOnly = isReadOnly
        self.supportsFlush = supportsFlush
        self.offeredFeatures = offeredFeatures
        self.negotiatedFeatures = negotiatedFeatures
        self.state = state
        self.availableIndex = availableIndex
        self.usedIndex = usedIndex
    }

    var identity: VirtIOBlockMMIOIdentity {
        VirtIOBlockMMIOIdentity(
            version: registers.read32(at: VirtIOBlockMMIORegisterLayout.version),
            deviceID: registers.read32(
                at: VirtIOBlockMMIORegisterLayout.deviceID
            ),
            vendorID: registers.read32(
                at: VirtIOBlockMMIORegisterLayout.vendorID
            )
        )
    }

    static func initialize(
        registers: Registers,
        storage: VirtIOBlockDMAStorage,
        maximumPollCount: UInt64 = 5_000_000
    ) -> VirtIOBlockInitializationResult<Registers> {
        guard maximumPollCount > 0 else {
            return .failure(.invalidPollLimit)
        }
        // ACCESS_PLATFORM is deliberately not negotiated yet. Until it is,
        // VirtIO requires queue and request addresses to be CPU physical
        // addresses rather than translated bus addresses.
        guard storageUsesIdentityMappings(storage), zero(storage) else {
            return .failure(.invalidDMAStorage)
        }
        guard registers.read32(at: VirtIOBlockMMIORegisterLayout.magic)
                == Self.magicValue else {
            return .failure(.wrongDevice)
        }
        guard registers.read32(at: VirtIOBlockMMIORegisterLayout.version)
                == Self.modernVersion
        else {
            return .failure(.legacyTransport)
        }
        guard registers.read32(at: VirtIOBlockMMIORegisterLayout.deviceID)
                == Self.blockDeviceID else {
            return .failure(.wrongDevice)
        }

        guard resetAndWait(
                  registers,
                  maximumPollCount: maximumPollCount
              )
        else {
            return .failure(.deviceResetFailed)
        }

        var deviceStatus = Status.acknowledge
        registers.write32(deviceStatus, at: VirtIOBlockMMIORegisterLayout.status)
        deviceStatus |= Status.driver
        registers.write32(deviceStatus, at: VirtIOBlockMMIORegisterLayout.status)

        let offered = readDeviceFeatures(registers)
        guard let selection = VirtIOFeatureSelection.select(
                  offered: offered,
                  required: VirtIOTransportFeature.version1,
                  optional: Feature.supportedOptional
              )
        else {
            failInitialization(registers)
            return .failure(.missingRequiredFeature)
        }
        writeDriverFeatures(selection.accepted, registers: registers)
        deviceStatus |= Status.featuresOK
        registers.write32(deviceStatus, at: VirtIOBlockMMIORegisterLayout.status)
        guard registers.read32(at: VirtIOBlockMMIORegisterLayout.status)
                & Status.featuresOK != 0
        else {
            failInitialization(registers)
            return .failure(.featureNegotiationFailed)
        }

        guard let sectorCount = readStableCapacity(registers) else {
            failInitialization(registers)
            return .failure(.unstableConfiguration)
        }
        guard let geometry = BlockDeviceGeometry(
                  logicalBlockByteCount: Int(VirtIOBlockDMAStorage.dataByteCount),
                  logicalBlockCount: sectorCount
              )
        else {
            failInitialization(registers)
            return .failure(.invalidCapacity)
        }

        acknowledgeInterrupts(registers, mask: Interrupt.known)
        switch configureQueue(registers, storage: storage) {
        case .ready:
            break
        case .unavailable:
            failInitialization(registers)
            return .failure(.queueUnavailable)
        case .storagePublished:
            failInitialization(registers)
            guard resetAndWait(
                      registers,
                      maximumPollCount: maximumPollCount
                  )
            else {
                return .failure(.dmaStorageQuarantineRequired)
            }
            return .failure(.queueUnavailable)
        }

        deviceStatus |= Status.driverOK
        registers.synchronizeDMA()
        registers.write32(deviceStatus, at: VirtIOBlockMMIORegisterLayout.status)
        let completedStatus = registers.read32(
            at: VirtIOBlockMMIORegisterLayout.status
        )
        guard completedStatus & (Status.failed | Status.deviceNeedsReset) == 0,
              completedStatus & Status.driverOK != 0
        else {
            failInitialization(registers)
            guard resetAndWait(
                      registers,
                      maximumPollCount: maximumPollCount
                  )
            else {
                return .failure(.dmaStorageQuarantineRequired)
            }
            return .failure(.featureNegotiationFailed)
        }

        return .ready(
            Self(
                registers: registers,
                storage: storage,
                maximumPollCount: maximumPollCount,
                geometry: geometry,
                isReadOnly: selection.accepted & Feature.readOnly != 0,
                supportsFlush: selection.accepted & Feature.flush != 0,
                offeredFeatures: offered,
                negotiatedFeatures: selection.accepted,
                state: .ready,
                availableIndex: 0,
                usedIndex: 0
            )
        )
    }

    /// Stops the device and waits until its status reads as zero. The caller
    /// may release DMA storage only after `.safeToRelease` is returned.
    /// A failed reset is retryable, but the storage remains quarantined between
    /// attempts because the device may still complete an exposed descriptor.
    mutating func teardown() -> VirtIOBlockDMAStorageDisposition {
        guard state != .reset else { return .safeToRelease }
        if Self.resetAndWait(
            registers,
            maximumPollCount: maximumPollCount
        ) {
            state = .reset
            return .safeToRelease
        }
        state = .quarantined
        return .quarantineRequired
    }

    mutating func readBlock(
        at logicalBlock: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
        guard output.count >= geometry.logicalBlockByteCount,
              output.baseAddress != nil
        else {
            return .invalidBuffer
        }
        let result = submit(
            type: RequestType.read,
            logicalBlock: logicalBlock,
            includesData: true,
            deviceWritesData: true
        )
        guard result == .success else { return result }
        guard let bytes = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
        else { return .invalidBuffer }
        var index = 0
        while index < geometry.logicalBlockByteCount {
            bytes[index] = PhysicalBytes.read8(
                at: storage.data.cpuPhysicalAddress + UInt64(index)
            )
            index += 1
        }
        return .success
    }

    mutating func writeBlock(
        at logicalBlock: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
        guard !isReadOnly else { return .readOnly }
        guard input.count >= geometry.logicalBlockByteCount,
              input.baseAddress != nil
        else {
            return .invalidBuffer
        }
        guard let bytes = input.baseAddress?.assumingMemoryBound(to: UInt8.self)
        else { return .invalidBuffer }
        var index = 0
        while index < geometry.logicalBlockByteCount {
            PhysicalBytes.write8(
                bytes[index],
                at: storage.data.cpuPhysicalAddress + UInt64(index)
            )
            index += 1
        }
        return submit(
            type: RequestType.write,
            logicalBlock: logicalBlock,
            includesData: true,
            deviceWritesData: false
        )
    }

    mutating func synchronize() -> BlockDeviceIOResult {
        guard state == .ready else { return .transportFailure }
        // A device that omits VIRTIO_BLK_F_FLUSH promises no flush command.
        // The common BlockDevice barrier is therefore already satisfied once
        // its completed write request becomes visible.
        guard supportsFlush else { return .success }
        return submit(
            type: RequestType.flush,
            logicalBlock: 0,
            includesData: false,
            deviceWritesData: false
        )
    }

    private mutating func submit(
        type: UInt32,
        logicalBlock: UInt64,
        includesData: Bool,
        deviceWritesData: Bool
    ) -> BlockDeviceIOResult {
        guard state == .ready else { return .transportFailure }
        let status = registers.read32(at: VirtIOBlockMMIORegisterLayout.status)
        guard status & (Status.failed | Status.deviceNeedsReset) == 0 else {
            return failAndReset()
        }
        let interrupts = registers.read32(
            at: VirtIOBlockMMIORegisterLayout.interruptStatus
        )
        guard interrupts & Interrupt.configurationChanged == 0 else {
            Self.acknowledgeInterrupts(registers, mask: Interrupt.known)
            return failAndReset()
        }

        prepareRequestHeader(type: type, logicalBlock: logicalBlock)
        PhysicalBytes.write8(
            RequestStatus.pending,
            at: storage.status.cpuPhysicalAddress
        )
        prepareDescriptors(
            includesData: includesData,
            deviceWritesData: deviceWritesData
        )

        let queue = storage.requestQueue
        let layout = storage.requestQueueLayout
        let availableSlot = UInt64(availableIndex % layout.size)
        PhysicalBytes.writeLE16(
            0,
            at: queue.cpuPhysicalAddress
                + layout.availableOffset + 4 + availableSlot * 2
        )
        availableIndex &+= 1
        registers.synchronizeDMA()
        registers.storeDMAUInt16(
            availableIndex,
            at: queue.cpuPhysicalAddress + layout.availableOffset + 2
        )
        registers.synchronizeDMA()
        registers.write32(0, at: VirtIOBlockMMIORegisterLayout.queueNotify)

        var pollCount: UInt64 = 0
        var observedUsedIndex = registers.loadDMAUInt16(
            at: queue.cpuPhysicalAddress + layout.usedOffset + 2
        )
        while observedUsedIndex == usedIndex, pollCount < maximumPollCount {
            let currentStatus = registers.read32(
                at: VirtIOBlockMMIORegisterLayout.status
            )
            if currentStatus & (Status.failed | Status.deviceNeedsReset) != 0 {
                return failAndReset()
            }
            pollCount += 1
            registers.spinWaitHint()
            observedUsedIndex = registers.loadDMAUInt16(
                at: queue.cpuPhysicalAddress + layout.usedOffset + 2
            )
        }
        guard observedUsedIndex &- usedIndex == 1
        else {
            return failAndReset()
        }
        registers.synchronizeDMA()

        let usedSlot = UInt64(usedIndex % layout.size)
        let usedElement = queue.cpuPhysicalAddress
            + layout.usedOffset + 4 + usedSlot * 8
        let descriptorID = PhysicalBytes.readLE32(at: usedElement)
        let writtenByteCount = PhysicalBytes.readLE32(at: usedElement + 4)
        let expectedWrittenByteCount: UInt32 = deviceWritesData ? 513 : 1
        guard descriptorID == 0,
              writtenByteCount == expectedWrittenByteCount
        else {
            return failAndReset()
        }
        usedIndex = observedUsedIndex
        Self.acknowledgeInterrupts(registers, mask: Interrupt.usedBuffer)

        switch PhysicalBytes.read8(at: storage.status.cpuPhysicalAddress) {
        case RequestStatus.success:
            return .success
        case RequestStatus.ioError, RequestStatus.unsupported:
            return .transportFailure
        default:
            return failAndReset()
        }
    }

    private mutating func failAndReset() -> BlockDeviceIOResult {
        if Self.resetAndWait(
            registers,
            maximumPollCount: maximumPollCount
        ) {
            state = .reset
        } else {
            state = .quarantined
        }
        return .transportFailure
    }

    private func prepareRequestHeader(type: UInt32, logicalBlock: UInt64) {
        let header = storage.requestHeader.cpuPhysicalAddress
        PhysicalBytes.writeLE32(type, at: header)
        PhysicalBytes.writeLE32(0, at: header + 4)
        PhysicalBytes.writeLE64(logicalBlock, at: header + 8)
    }

    private func prepareDescriptors(
        includesData: Bool,
        deviceWritesData: Bool
    ) {
        let descriptorBase = storage.requestQueue.cpuPhysicalAddress
            + storage.requestQueueLayout.descriptorOffset
        if includesData {
            writeDescriptor(
                at: descriptorBase,
                address: storage.requestHeader.deviceAddress,
                byteCount: UInt32(VirtIOBlockDMAStorage.requestHeaderByteCount),
                flags: DescriptorFlag.next,
                next: 1
            )
            writeDescriptor(
                at: descriptorBase + 16,
                address: storage.data.deviceAddress,
                byteCount: UInt32(VirtIOBlockDMAStorage.dataByteCount),
                flags: DescriptorFlag.next
                    | (deviceWritesData ? DescriptorFlag.deviceWrites : 0),
                next: 2
            )
        } else {
            writeDescriptor(
                at: descriptorBase,
                address: storage.requestHeader.deviceAddress,
                byteCount: UInt32(VirtIOBlockDMAStorage.requestHeaderByteCount),
                flags: DescriptorFlag.next,
                next: 2
            )
            // Descriptor one is unreachable for a flush request.
            zeroDescriptor(at: descriptorBase + 16)
        }
        writeDescriptor(
            at: descriptorBase + 32,
            address: storage.status.deviceAddress,
            byteCount: UInt32(VirtIOBlockDMAStorage.statusByteCount),
            flags: DescriptorFlag.deviceWrites,
            next: 0
        )
    }

    private func writeDescriptor(
        at address: UInt64,
        address deviceAddress: UInt64,
        byteCount: UInt32,
        flags: UInt16,
        next: UInt16
    ) {
        PhysicalBytes.writeLE64(deviceAddress, at: address)
        PhysicalBytes.writeLE32(byteCount, at: address + 8)
        PhysicalBytes.writeLE16(flags, at: address + 12)
        PhysicalBytes.writeLE16(next, at: address + 14)
    }

    private func zeroDescriptor(at address: UInt64) {
        PhysicalBytes.writeLE64(0, at: address)
        PhysicalBytes.writeLE32(0, at: address + 8)
        PhysicalBytes.writeLE16(0, at: address + 12)
        PhysicalBytes.writeLE16(0, at: address + 14)
    }

    private static func zero(_ storage: VirtIOBlockDMAStorage) -> Bool {
        PhysicalBytes.zero(
            address: storage.requestQueue.cpuPhysicalAddress,
            byteCount: storage.requestQueue.byteCount
        ) && PhysicalBytes.zero(
            address: storage.requestHeader.cpuPhysicalAddress,
            byteCount: storage.requestHeader.byteCount
        ) && PhysicalBytes.zero(
            address: storage.data.cpuPhysicalAddress,
            byteCount: storage.data.byteCount
        ) && PhysicalBytes.zero(
            address: storage.status.cpuPhysicalAddress,
            byteCount: storage.status.byteCount
        )
    }

    private static func storageUsesIdentityMappings(
        _ storage: VirtIOBlockDMAStorage
    ) -> Bool {
        storage.requestQueue.isIdentityMapped
            && storage.requestHeader.isIdentityMapped
            && storage.data.isIdentityMapped
            && storage.status.isIdentityMapped
    }

    private static func configureQueue(
        _ registers: Registers,
        storage: VirtIOBlockDMAStorage
    ) -> VirtIOBlockQueueConfigurationResult {
        let queue = storage.requestQueue
        let layout = storage.requestQueueLayout
        registers.write32(0, at: VirtIOBlockMMIORegisterLayout.queueSelect)
        guard registers.read32(at: VirtIOBlockMMIORegisterLayout.queueReady) == 0,
              registers.read32(at: VirtIOBlockMMIORegisterLayout.queueMaximum)
                >= UInt32(layout.size)
        else {
            return .unavailable
        }

        PhysicalBytes.writeLE16(
            AvailableFlag.noInterrupt,
            at: queue.cpuPhysicalAddress + layout.availableOffset
        )
        PhysicalBytes.writeLE16(
            0,
            at: queue.cpuPhysicalAddress + layout.usedOffset
        )
        registers.write32(
            UInt32(layout.size),
            at: VirtIOBlockMMIORegisterLayout.queueSize
        )
        writeAddress(
            queue.deviceAddress + layout.descriptorOffset,
            low: VirtIOBlockMMIORegisterLayout.queueDescriptorLow,
            high: VirtIOBlockMMIORegisterLayout.queueDescriptorHigh,
            registers: registers
        )
        writeAddress(
            queue.deviceAddress + layout.availableOffset,
            low: VirtIOBlockMMIORegisterLayout.queueDriverLow,
            high: VirtIOBlockMMIORegisterLayout.queueDriverHigh,
            registers: registers
        )
        writeAddress(
            queue.deviceAddress + layout.usedOffset,
            low: VirtIOBlockMMIORegisterLayout.queueDeviceLow,
            high: VirtIOBlockMMIORegisterLayout.queueDeviceHigh,
            registers: registers
        )
        registers.synchronizeDMA()
        registers.write32(1, at: VirtIOBlockMMIORegisterLayout.queueReady)
        return registers.read32(at: VirtIOBlockMMIORegisterLayout.queueReady) == 1
            ? .ready
            : .storagePublished
    }

    private static func readDeviceFeatures(_ registers: Registers) -> UInt64 {
        registers.write32(
            0,
            at: VirtIOBlockMMIORegisterLayout.deviceFeaturesSelect
        )
        let low = registers.read32(
            at: VirtIOBlockMMIORegisterLayout.deviceFeatures
        )
        registers.write32(
            1,
            at: VirtIOBlockMMIORegisterLayout.deviceFeaturesSelect
        )
        let high = registers.read32(
            at: VirtIOBlockMMIORegisterLayout.deviceFeatures
        )
        return UInt64(low) | UInt64(high) << 32
    }

    private static func writeDriverFeatures(
        _ features: UInt64,
        registers: Registers
    ) {
        registers.write32(
            0,
            at: VirtIOBlockMMIORegisterLayout.driverFeaturesSelect
        )
        registers.write32(
            UInt32(truncatingIfNeeded: features),
            at: VirtIOBlockMMIORegisterLayout.driverFeatures
        )
        registers.write32(
            1,
            at: VirtIOBlockMMIORegisterLayout.driverFeaturesSelect
        )
        registers.write32(
            UInt32(truncatingIfNeeded: features >> 32),
            at: VirtIOBlockMMIORegisterLayout.driverFeatures
        )
    }

    private static func readStableCapacity(_ registers: Registers) -> UInt64? {
        var attempt = 0
        while attempt < 8 {
            let before = registers.read32(
                at: VirtIOBlockMMIORegisterLayout.configurationGeneration
            )
            let low = registers.read32(
                at: VirtIOBlockMMIORegisterLayout.deviceConfiguration
            )
            let high = registers.read32(
                at: VirtIOBlockMMIORegisterLayout.deviceConfiguration + 4
            )
            let after = registers.read32(
                at: VirtIOBlockMMIORegisterLayout.configurationGeneration
            )
            if before == after {
                return UInt64(low) | UInt64(high) << 32
            }
            attempt += 1
        }
        return nil
    }

    private static func writeAddress(
        _ address: UInt64,
        low lowOffset: UInt,
        high highOffset: UInt,
        registers: Registers
    ) {
        registers.write32(
            UInt32(truncatingIfNeeded: address),
            at: lowOffset
        )
        registers.write32(
            UInt32(truncatingIfNeeded: address >> 32),
            at: highOffset
        )
    }

    private static func acknowledgeInterrupts(
        _ registers: Registers,
        mask: UInt32
    ) {
        let pending = registers.read32(
            at: VirtIOBlockMMIORegisterLayout.interruptStatus
        ) & mask & Interrupt.known
        if pending != 0 {
            registers.write32(
                pending,
                at: VirtIOBlockMMIORegisterLayout.interruptAcknowledge
            )
        }
    }

    private static func resetAndWait(
        _ registers: Registers,
        maximumPollCount: UInt64
    ) -> Bool {
        registers.write32(0, at: VirtIOBlockMMIORegisterLayout.status)
        var pollCount: UInt64 = 0
        while pollCount < maximumPollCount {
            if registers.read32(at: VirtIOBlockMMIORegisterLayout.status) == 0 {
                registers.synchronizeDMA()
                return true
            }
            pollCount += 1
            registers.spinWaitHint()
        }
        return false
    }

    private static func failInitialization(_ registers: Registers) {
        let status = registers.read32(at: VirtIOBlockMMIORegisterLayout.status)
        registers.write32(
            status | Status.failed,
            at: VirtIOBlockMMIORegisterLayout.status
        )
    }
}
