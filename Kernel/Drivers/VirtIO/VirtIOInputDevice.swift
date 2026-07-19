/// Register and DMA visibility boundary for a modern VirtIO-input MMIO
/// device. The guest implementation performs volatile accesses; host tests
/// use deterministic in-memory registers without changing queue policy.
protocol VirtIOInputRegisterAccess {
    func read8(at offset: UInt) -> UInt8
    func read32(at offset: UInt) -> UInt32
    func write8(_ value: UInt8, at offset: UInt)
    func write32(_ value: UInt32, at offset: UInt)

    func loadDMAUInt16(at cpuAddress: UInt64) -> UInt16
    func storeDMAUInt16(_ value: UInt16, at cpuAddress: UInt64)
    func synchronizeDMA()
    func spinWaitHint()
}

enum VirtIOInputMMIORegisterLayout {
    static let minimumApertureLength: UInt64 = 0x188

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

struct VirtIOInputMMIOIdentity: Equatable {
    let version: UInt32
    let deviceID: UInt32
    let vendorID: UInt32
}

enum VirtIOInputInitializationResult: Equatable {
    case ready(VirtIOInputCapabilities)
    case invalidState
    case invalidPollLimit
    case invalidDMAStorage
    case wrongDevice
    case legacyTransport
    case deviceResetFailed
    case missingRequiredFeature
    case featureNegotiationFailed
    case invalidDeviceConfiguration
    case unsupportedDeviceConfiguration
    case queueUnavailable
}

struct VirtIOInputPollSummary: Equatable {
    let consumedWireEventCount: UInt16
    let translation: VirtIOInputTranslationSummary
    let configurationRefreshed: Bool
}

enum VirtIOInputPollResult: Equatable {
    case idle(configurationRefreshed: Bool)
    case processed(VirtIOInputPollSummary)
    case invalidLimit
    case deviceFault
}

private enum VirtIOInputDeviceState: UInt8 {
    case cold
    case ready
    case faulted
}

private enum VirtIOInputConfigurationBitResult {
    case value(Bool)
    case invalid
}

/// Caller-owned coherent storage for one input eventq and its 64 independent
/// eight-byte event records. CPU and device address ranges must be disjoint so
/// the device can never overwrite its queue metadata through an event buffer.
struct VirtIOInputDMAStorage: Equatable {
    static let eventQueueSize: UInt16 = 64
    static let eventBufferByteCount: UInt64 = 8
    static let requiredEventBufferByteCount: UInt64 =
        UInt64(eventQueueSize) * eventBufferByteCount

    let eventQueue: DMAMapping
    let eventBuffers: DMAMapping
    let eventQueueLayout: VirtIOSplitQueueLayout

    init?(
        eventQueue: DMAMapping,
        eventBuffers: DMAMapping
    ) {
        guard let layout = VirtIOSplitQueueLayout(
                  size: Self.eventQueueSize
              ),
              Self.isUsable(
                  eventQueue,
                  minimumByteCount: layout.requiredByteCount,
                  alignment: 16
              ),
              Self.isUsable(
                  eventBuffers,
                  minimumByteCount: Self.requiredEventBufferByteCount,
                  alignment: 8
              ),
              Self.disjoint(eventQueue, eventBuffers)
        else {
            return nil
        }
        self.eventQueue = eventQueue
        self.eventBuffers = eventBuffers
        eventQueueLayout = layout
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

/// Modern VirtIO 1.x input device using eventq 0. The status queue remains
/// deliberately unconfigured until keyboard LED feedback has an owner. All
/// event processing is bounded and polling; no interrupt-controller or UI
/// policy lives in this transport.
struct VirtIOInputDevice<Registers: VirtIOInputRegisterAccess> {
    static var magicValue: UInt32 { 0x7472_6976 }
    static var modernVersion: UInt32 { 2 }
    static var inputDeviceID: UInt32 { 18 }

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
    }

    private enum DescriptorFlag {
        static var deviceWrites: UInt16 { 2 }
    }

    private enum AvailableFlag {
        static var noInterrupt: UInt16 { 1 }
    }

    private let registers: Registers
    private let storage: VirtIOInputDMAStorage
    private let maximumPollCount: UInt64
    private var translator: VirtIOInputEventTranslator
    private var state: VirtIOInputDeviceState = .cold
    private var usedIndex: UInt16 = 0
    private var validatedUsedIndex: UInt16 = 0
    private var availableIndex: UInt16 = 0
    /// One bit per descriptor currently published to the device. A completed
    /// ID is removed before decoding and restored only after the recycled
    /// available index is visible, so duplicate completions fail closed.
    private var deviceOwnedDescriptorMask: UInt64 = 0

    private(set) var offeredFeatures: UInt64 = 0
    private(set) var negotiatedFeatures: UInt64 = 0
    private(set) var capabilities: VirtIOInputCapabilities?
    private(set) var hasPublishedQueue = false

    init(
        registers: Registers,
        storage: VirtIOInputDMAStorage,
        deviceID: InputDeviceID,
        maximumPollCount: UInt64 = 5_000_000
    ) {
        self.registers = registers
        self.storage = storage
        self.maximumPollCount = maximumPollCount
        translator = VirtIOInputEventTranslator(deviceID: deviceID)
    }

    var identity: VirtIOInputMMIOIdentity {
        VirtIOInputMMIOIdentity(
            version: registers.read32(at: VirtIOInputMMIORegisterLayout.version),
            deviceID: registers.read32(
                at: VirtIOInputMMIORegisterLayout.deviceID
            ),
            vendorID: registers.read32(
                at: VirtIOInputMMIORegisterLayout.vendorID
            )
        )
    }

    mutating func initialize() -> VirtIOInputInitializationResult {
        guard state == .cold else { return .invalidState }
        guard maximumPollCount > 0 else {
            state = .faulted
            return .invalidPollLimit
        }
        guard zeroDMAStorage() else {
            state = .faulted
            return .invalidDMAStorage
        }
        guard registers.read32(at: VirtIOInputMMIORegisterLayout.magic)
                == Self.magicValue,
              identity.deviceID == Self.inputDeviceID
        else {
            state = .faulted
            return .wrongDevice
        }
        guard identity.version == Self.modernVersion else {
            state = .faulted
            return .legacyTransport
        }

        registers.write32(0, at: VirtIOInputMMIORegisterLayout.status)
        var resetPollCount: UInt64 = 0
        while resetPollCount < maximumPollCount,
              registers.read32(at: VirtIOInputMMIORegisterLayout.status) != 0 {
            resetPollCount += 1
            registers.spinWaitHint()
        }
        guard resetPollCount < maximumPollCount else {
            return failInitialization(.deviceResetFailed)
        }

        var deviceStatus = Status.acknowledge
        registers.write32(deviceStatus, at: VirtIOInputMMIORegisterLayout.status)
        deviceStatus |= Status.driver
        registers.write32(deviceStatus, at: VirtIOInputMMIORegisterLayout.status)

        offeredFeatures = readDeviceFeatures()
        guard let selection = VirtIOFeatureSelection.select(
                  offered: offeredFeatures,
                  required: VirtIOTransportFeature.version1,
                  optional: 0
              )
        else {
            return failInitialization(.missingRequiredFeature)
        }
        negotiatedFeatures = selection.accepted
        writeDriverFeatures(selection.accepted)
        deviceStatus |= Status.featuresOK
        registers.write32(deviceStatus, at: VirtIOInputMMIORegisterLayout.status)
        guard registers.read32(at: VirtIOInputMMIORegisterLayout.status)
                & Status.featuresOK != 0
        else {
            return failInitialization(.featureNegotiationFailed)
        }

        guard let discoveredCapabilities = readCapabilities() else {
            return failInitialization(.invalidDeviceConfiguration)
        }
        guard discoveredCapabilities.isUsable else {
            return failInitialization(.unsupportedDeviceConfiguration)
        }
        capabilities = discoveredCapabilities
        acknowledgeInterrupts()

        guard prepareEventQueue(), configureEventQueue() else {
            return failInitialization(.queueUnavailable)
        }

        deviceStatus |= Status.driverOK
        registers.synchronizeDMA()
        registers.write32(deviceStatus, at: VirtIOInputMMIORegisterLayout.status)
        let completedStatus = registers.read32(
            at: VirtIOInputMMIORegisterLayout.status
        )
        guard completedStatus & (Status.failed | Status.deviceNeedsReset) == 0,
              completedStatus & Status.driverOK != 0
        else {
            return failInitialization(.featureNegotiationFailed)
        }

        registers.write32(0, at: VirtIOInputMMIORegisterLayout.queueNotify)
        state = .ready
        return .ready(discoveredCapabilities)
    }

    mutating func poll<S: InputEventSink>(
        timestampTicks: UInt64,
        maximumEvents: UInt16 = VirtIOInputDMAStorage.eventQueueSize,
        into sink: inout S
    ) -> VirtIOInputPollResult {
        guard state == .ready else { return .deviceFault }
        guard maximumEvents > 0,
              maximumEvents <= VirtIOInputDMAStorage.eventQueueSize
        else {
            return .invalidLimit
        }
        guard !deviceNeedsReset else {
            faultDevice()
            return .deviceFault
        }

        var configurationRefreshed = false
        let initialInterrupts = registers.read32(
            at: VirtIOInputMMIORegisterLayout.interruptStatus
        )
        if initialInterrupts & Interrupt.configurationChanged != 0 {
            guard let refreshed = readCapabilities(), refreshed.isUsable else {
                faultDevice()
                return .deviceFault
            }
            capabilities = refreshed
            configurationRefreshed = true
            acknowledgeInterrupts(mask: Interrupt.configurationChanged)
        }

        let queue = storage.eventQueue
        let layout = storage.eventQueueLayout
        let observedUsedIndex = registers.loadDMAUInt16(
            at: queue.cpuPhysicalAddress + layout.usedOffset + 2
        )
        let pending = observedUsedIndex &- usedIndex
        let previouslyValidated = validatedUsedIndex &- usedIndex
        guard pending <= layout.size,
              previouslyValidated <= pending
        else {
            faultDevice()
            return .deviceFault
        }
        guard pending > 0 else {
            acknowledgeInterrupts(mask: Interrupt.usedBuffer)
            return .idle(configurationRefreshed: configurationRefreshed)
        }
        registers.synchronizeDMA()

        // Validate every newly observed used element, even when the caller's
        // processing budget is smaller. Otherwise two duplicate IDs already
        // present in the used ring could straddle polls and look legitimate
        // after the first descriptor was recycled.
        let unvalidated = observedUsedIndex &- validatedUsedIndex
        guard unvalidated <= layout.size - previouslyValidated else {
            faultDevice()
            return .deviceFault
        }
        var validatedOwnership = deviceOwnedDescriptorMask
        var validated: UInt16 = 0
        while validated < unvalidated {
            let usedSlot = UInt64(
                (validatedUsedIndex &+ validated) % layout.size
            )
            let usedElement = queue.cpuPhysicalAddress
                + layout.usedOffset + 4 + usedSlot * 8
            let descriptorID = PhysicalBytes.readLE32(at: usedElement)
            let usedByteCount = PhysicalBytes.readLE32(at: usedElement + 4)
            guard descriptorID < UInt32(layout.size),
                  usedByteCount == UInt32(VirtIOInputWireEvent.byteCount)
            else {
                faultDevice()
                return .deviceFault
            }
            let ownershipBit = UInt64(1) << UInt64(descriptorID)
            guard validatedOwnership & ownershipBit != 0 else {
                faultDevice()
                return .deviceFault
            }
            validatedOwnership &= ~ownershipBit
            validated &+= 1
        }
        deviceOwnedDescriptorMask = validatedOwnership
        validatedUsedIndex = observedUsedIndex

        let count = pending < maximumEvents ? pending : maximumEvents
        var processed: UInt16 = 0
        var recycledDescriptorMask: UInt64 = 0
        var translation = VirtIOInputTranslationSummary()
        while processed < count {
            let usedSlot = UInt64(usedIndex % layout.size)
            let usedElement = queue.cpuPhysicalAddress
                + layout.usedOffset + 4 + usedSlot * 8
            let descriptorID = PhysicalBytes.readLE32(at: usedElement)
            // The complete bounded prefix was validated before any event was
            // emitted or descriptor ownership was changed.

            let eventAddress = storage.eventBuffers.cpuPhysicalAddress
                + UInt64(descriptorID)
                    * VirtIOInputDMAStorage.eventBufferByteCount
            let wireEvent = VirtIOInputWireEvent.decode(at: eventAddress)
            let eventSummary = translator.process(
                wireEvent,
                timestampTicks: timestampTicks,
                into: &sink
            )
            translation.merge(eventSummary)
            usedIndex &+= 1

            let availableSlot = UInt64(availableIndex % layout.size)
            PhysicalBytes.writeLE16(
                UInt16(descriptorID),
                at: queue.cpuPhysicalAddress
                    + layout.availableOffset + 4 + availableSlot * 2
            )
            recycledDescriptorMask |= UInt64(1) << UInt64(descriptorID)
            availableIndex &+= 1
            processed &+= 1
        }

        registers.synchronizeDMA()
        registers.storeDMAUInt16(
            availableIndex,
            at: queue.cpuPhysicalAddress + layout.availableOffset + 2
        )
        registers.synchronizeDMA()
        deviceOwnedDescriptorMask |= recycledDescriptorMask
        registers.write32(0, at: VirtIOInputMMIORegisterLayout.queueNotify)
        acknowledgeInterrupts(mask: Interrupt.usedBuffer)
        return .processed(
            VirtIOInputPollSummary(
                consumedWireEventCount: processed,
                translation: translation,
                configurationRefreshed: configurationRefreshed
            )
        )
    }

    private var deviceNeedsReset: Bool {
        registers.read32(at: VirtIOInputMMIORegisterLayout.status)
            & Status.deviceNeedsReset != 0
    }

    private func readDeviceFeatures() -> UInt64 {
        registers.write32(
            0,
            at: VirtIOInputMMIORegisterLayout.deviceFeaturesSelect
        )
        let low = registers.read32(
            at: VirtIOInputMMIORegisterLayout.deviceFeatures
        )
        registers.write32(
            1,
            at: VirtIOInputMMIORegisterLayout.deviceFeaturesSelect
        )
        let high = registers.read32(
            at: VirtIOInputMMIORegisterLayout.deviceFeatures
        )
        return UInt64(low) | UInt64(high) << 32
    }

    private func writeDriverFeatures(_ features: UInt64) {
        registers.write32(
            0,
            at: VirtIOInputMMIORegisterLayout.driverFeaturesSelect
        )
        registers.write32(
            UInt32(truncatingIfNeeded: features),
            at: VirtIOInputMMIORegisterLayout.driverFeatures
        )
        registers.write32(
            1,
            at: VirtIOInputMMIORegisterLayout.driverFeaturesSelect
        )
        registers.write32(
            UInt32(truncatingIfNeeded: features >> 32),
            at: VirtIOInputMMIORegisterLayout.driverFeatures
        )
    }

    private func readCapabilities(
        maximumAttempts: Int = 8
    ) -> VirtIOInputCapabilities? {
        guard maximumAttempts > 0 else { return nil }
        var attempt = 0
        while attempt < maximumAttempts {
            let generationBefore = configurationGeneration
            guard let snapshot = readCapabilitySnapshot() else { return nil }
            let generationAfter = configurationGeneration
            if generationBefore == generationAfter {
                return snapshot
            }
            attempt += 1
        }
        return nil
    }

    private var configurationGeneration: UInt8 {
        UInt8(
            truncatingIfNeeded: registers.read32(
                at: VirtIOInputMMIORegisterLayout.configurationGeneration
            )
        )
    }

    private func readCapabilitySnapshot() -> VirtIOInputCapabilities? {
        guard case .value(let keyA) = configurationBitmapContains(
                  eventType: VirtIOInputEventType.key,
                  code: 30
              ),
              case .value(let enter) = configurationBitmapContains(
                  eventType: VirtIOInputEventType.key,
                  code: 28
              ),
              case .value(let relativeX) = configurationBitmapContains(
                  eventType: VirtIOInputEventType.relative,
                  code: VirtIOInputEventCode.relativeX
              ),
              case .value(let relativeY) = configurationBitmapContains(
                  eventType: VirtIOInputEventType.relative,
                  code: VirtIOInputEventCode.relativeY
              ),
              case .value(let primaryButton) = configurationBitmapContains(
                  eventType: VirtIOInputEventType.key,
                  code: VirtIOInputEventCode.primaryButton
              ),
              case .value(let verticalScroll) = configurationBitmapContains(
                  eventType: VirtIOInputEventType.relative,
                  code: VirtIOInputEventCode.verticalWheel
              ),
              case .value(let horizontalScroll) = configurationBitmapContains(
                  eventType: VirtIOInputEventType.relative,
                  code: VirtIOInputEventCode.horizontalWheel
              )
        else {
            return nil
        }
        return VirtIOInputCapabilities(
            keyboard: keyA && enter,
            relativePointer: relativeX && relativeY,
            primaryPointerButton: primaryButton,
            verticalScroll: verticalScroll,
            horizontalScroll: horizontalScroll
        )
    }

    private func configurationBitmapContains(
        eventType: UInt16,
        code: UInt16,
        maximumAttempts: Int = 8
    ) -> VirtIOInputConfigurationBitResult {
        guard eventType <= UInt16(UInt8.max), maximumAttempts > 0 else {
            return .invalid
        }
        let configuration = VirtIOInputMMIORegisterLayout.deviceConfiguration
        registers.write8(
            VirtIOInputConfigurationSelector.eventBits,
            at: configuration
        )
        registers.write8(UInt8(eventType), at: configuration + 1)

        let byteIndex = UInt(code / 8)
        let bit = UInt8(1) << UInt8(code % 8)
        var attempt = 0
        while attempt < maximumAttempts {
            let generationBefore = configurationGeneration
            let size = registers.read8(at: configuration + 2)
            guard size <= 128 else { return .invalid }
            let supported = byteIndex < UInt(size)
                && registers.read8(
                    at: configuration + 8 + byteIndex
                ) & bit != 0
            let generationAfter = configurationGeneration
            if generationBefore == generationAfter {
                return .value(supported)
            }
            attempt += 1
        }
        return .invalid
    }

    private mutating func prepareEventQueue() -> Bool {
        let queue = storage.eventQueue
        let buffers = storage.eventBuffers
        let layout = storage.eventQueueLayout
        PhysicalBytes.writeLE16(
            AvailableFlag.noInterrupt,
            at: queue.cpuPhysicalAddress + layout.availableOffset
        )

        var index: UInt16 = 0
        while index < layout.size {
            writeDescriptor(
                index: index,
                deviceAddress: buffers.deviceAddress
                    + UInt64(index)
                        * VirtIOInputDMAStorage.eventBufferByteCount,
                byteCount: UInt32(VirtIOInputDMAStorage.eventBufferByteCount),
                flags: DescriptorFlag.deviceWrites
            )
            PhysicalBytes.writeLE16(
                index,
                at: queue.cpuPhysicalAddress
                    + layout.availableOffset + 4 + UInt64(index) * 2
            )
            index &+= 1
        }
        availableIndex = layout.size
        usedIndex = 0
        validatedUsedIndex = 0
        registers.synchronizeDMA()
        registers.storeDMAUInt16(
            availableIndex,
            at: queue.cpuPhysicalAddress + layout.availableOffset + 2
        )
        registers.synchronizeDMA()
        deviceOwnedDescriptorMask = UInt64.max
        return true
    }

    private mutating func configureEventQueue() -> Bool {
        let queue = storage.eventQueue
        let layout = storage.eventQueueLayout
        registers.write32(0, at: VirtIOInputMMIORegisterLayout.queueSelect)
        guard registers.read32(at: VirtIOInputMMIORegisterLayout.queueReady) == 0,
              registers.read32(at: VirtIOInputMMIORegisterLayout.queueMaximum)
                >= UInt32(layout.size)
        else {
            return false
        }
        registers.write32(
            UInt32(layout.size),
            at: VirtIOInputMMIORegisterLayout.queueSize
        )
        writeAddress(
            queue.deviceAddress + layout.descriptorOffset,
            low: VirtIOInputMMIORegisterLayout.queueDescriptorLow,
            high: VirtIOInputMMIORegisterLayout.queueDescriptorHigh
        )
        writeAddress(
            queue.deviceAddress + layout.availableOffset,
            low: VirtIOInputMMIORegisterLayout.queueDriverLow,
            high: VirtIOInputMMIORegisterLayout.queueDriverHigh
        )
        writeAddress(
            queue.deviceAddress + layout.usedOffset,
            low: VirtIOInputMMIORegisterLayout.queueDeviceLow,
            high: VirtIOInputMMIORegisterLayout.queueDeviceHigh
        )
        registers.synchronizeDMA()
        registers.write32(1, at: VirtIOInputMMIORegisterLayout.queueReady)
        hasPublishedQueue = registers.read32(
            at: VirtIOInputMMIORegisterLayout.queueReady
        ) == 1
        return hasPublishedQueue
    }

    private func writeDescriptor(
        index: UInt16,
        deviceAddress: UInt64,
        byteCount: UInt32,
        flags: UInt16
    ) {
        let descriptor = storage.eventQueue.cpuPhysicalAddress
            + storage.eventQueueLayout.descriptorOffset + UInt64(index) * 16
        PhysicalBytes.writeLE64(deviceAddress, at: descriptor)
        PhysicalBytes.writeLE32(byteCount, at: descriptor + 8)
        PhysicalBytes.writeLE16(flags, at: descriptor + 12)
        PhysicalBytes.writeLE16(0, at: descriptor + 14)
    }

    private func writeAddress(_ value: UInt64, low: UInt, high: UInt) {
        registers.write32(UInt32(truncatingIfNeeded: value), at: low)
        registers.write32(UInt32(truncatingIfNeeded: value >> 32), at: high)
    }

    private func acknowledgeInterrupts(mask: UInt32 = UInt32.max) {
        let pending = registers.read32(
            at: VirtIOInputMMIORegisterLayout.interruptStatus
        ) & mask
        if pending != 0 {
            registers.write32(
                pending,
                at: VirtIOInputMMIORegisterLayout.interruptAcknowledge
            )
        }
    }

    private func zeroDMAStorage() -> Bool {
        PhysicalBytes.zero(
            address: storage.eventQueue.cpuPhysicalAddress,
            byteCount: storage.eventQueueLayout.requiredByteCount
        ) && PhysicalBytes.zero(
            address: storage.eventBuffers.cpuPhysicalAddress,
            byteCount: VirtIOInputDMAStorage.requiredEventBufferByteCount
        )
    }

    private mutating func failInitialization(
        _ result: VirtIOInputInitializationResult
    ) -> VirtIOInputInitializationResult {
        faultDevice()
        return result
    }

    private mutating func faultDevice() {
        let status = registers.read32(at: VirtIOInputMMIORegisterLayout.status)
        registers.write32(
            status | Status.failed,
            at: VirtIOInputMMIORegisterLayout.status
        )
        state = .faulted
    }
}
