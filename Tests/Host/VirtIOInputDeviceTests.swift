private final class VirtIOInputTestHardware {
    var magic: UInt32 = 0x7472_6976
    var version: UInt32 = 2
    var deviceID: UInt32 = 18
    var offeredFeatures: UInt64 = VirtIOTransportFeature.version1
        | (UInt64(1) << 28)
    var driverFeatures: UInt64 = 0
    var deviceFeatureSelection: UInt32 = 0
    var driverFeatureSelection: UInt32 = 0
    var selectedQueue: UInt16 = 0
    var queueMaximum = [UInt32(64), UInt32(64)]
    var queueSize = [UInt16(0), UInt16(0)]
    var queueReady = [UInt32(0), UInt32(0)]
    var descriptorAddress = [UInt64(0), UInt64(0)]
    var availableAddress = [UInt64(0), UInt64(0)]
    var usedAddress = [UInt64(0), UInt64(0)]
    var status: UInt32 = 0
    var interruptStatus: UInt32 = 0
    var rejectFeatures = false
    var ignoreResetWrites = false
    var unstableConfiguration = false
    var configurationGeneration: UInt32 = 0
    var configurationSelector: UInt8 = 0
    var configurationSubselector: UInt8 = 0
    var configurationReadCount = 0
    var supportsKeyboard = true
    var supportsRelativePointer = true
    var supportsPrimaryButton = true
    var supportsVerticalScroll = true
    var supportsHorizontalScroll = true
    var deviceAvailableIndex: UInt16 = 0
    var deviceUsedIndex: UInt16 = 0
    var notifications = [UInt32]()
    var notificationStatuses = [UInt32]()
    var synchronizationCount = 0
    var spinCount = 0

    func completeEvent(
        type: UInt16,
        code: UInt16,
        value: UInt32,
        reportedByteCount: UInt32 = 8,
        reportedDescriptorID: UInt32? = nil
    ) -> Bool {
        guard queueReady[0] == 1,
              queueSize[0] == VirtIOInputDMAStorage.eventQueueSize,
              descriptorAddress[0] != 0,
              availableAddress[0] != 0,
              usedAddress[0] != 0
        else { return false }
        let published = PhysicalBytes.readLE16(at: availableAddress[0] + 2)
        guard published != deviceAvailableIndex else { return false }
        let availableSlot = UInt64(deviceAvailableIndex % queueSize[0])
        let descriptorID = PhysicalBytes.readLE16(
            at: availableAddress[0] + 4 + availableSlot * 2
        )
        guard descriptorID < queueSize[0] else { return false }
        let descriptor = descriptorAddress[0] + UInt64(descriptorID) * 16
        let eventAddress = PhysicalBytes.readLE64(at: descriptor)
        guard PhysicalBytes.readLE32(at: descriptor + 8) == 8,
              PhysicalBytes.readLE16(at: descriptor + 12) == 2,
              PhysicalBytes.readLE16(at: descriptor + 14) == 0
        else { return false }
        PhysicalBytes.writeLE16(type, at: eventAddress)
        PhysicalBytes.writeLE16(code, at: eventAddress + 2)
        PhysicalBytes.writeLE32(value, at: eventAddress + 4)

        let usedSlot = UInt64(deviceUsedIndex % queueSize[0])
        let usedElement = usedAddress[0] + 4 + usedSlot * 8
        PhysicalBytes.writeLE32(
            reportedDescriptorID ?? UInt32(descriptorID),
            at: usedElement
        )
        PhysicalBytes.writeLE32(reportedByteCount, at: usedElement + 4)
        deviceAvailableIndex &+= 1
        deviceUsedIndex &+= 1
        PhysicalBytes.writeLE16(deviceUsedIndex, at: usedAddress[0] + 2)
        interruptStatus |= 1
        return true
    }

    func configurationByte(at byteIndex: UInt) -> UInt8 {
        guard configurationSelector
                == VirtIOInputConfigurationSelector.eventBits
        else { return 0 }
        let eventType = UInt16(configurationSubselector)
        var result: UInt8 = 0
        if eventType == VirtIOInputEventType.key {
            if supportsKeyboard {
                setBit(code: 28, byteIndex: byteIndex, result: &result)
                setBit(code: 30, byteIndex: byteIndex, result: &result)
            }
            if supportsPrimaryButton {
                setBit(
                    code: VirtIOInputEventCode.primaryButton,
                    byteIndex: byteIndex,
                    result: &result
                )
            }
        } else if eventType == VirtIOInputEventType.relative,
                  supportsRelativePointer {
            setBit(
                code: VirtIOInputEventCode.relativeX,
                byteIndex: byteIndex,
                result: &result
            )
            setBit(
                code: VirtIOInputEventCode.relativeY,
                byteIndex: byteIndex,
                result: &result
            )
            if supportsVerticalScroll {
                setBit(
                    code: VirtIOInputEventCode.verticalWheel,
                    byteIndex: byteIndex,
                    result: &result
                )
            }
            if supportsHorizontalScroll {
                setBit(
                    code: VirtIOInputEventCode.horizontalWheel,
                    byteIndex: byteIndex,
                    result: &result
                )
            }
        }
        return result
    }

    func configurationSize() -> UInt8 {
        guard configurationSelector
                == VirtIOInputConfigurationSelector.eventBits
        else { return 0 }
        switch UInt16(configurationSubselector) {
        case VirtIOInputEventType.key: return 35
        case VirtIOInputEventType.relative: return 2
        default: return 0
        }
    }

    private func setBit(
        code: UInt16,
        byteIndex: UInt,
        result: inout UInt8
    ) {
        guard UInt(code / 8) == byteIndex else { return }
        result |= UInt8(1) << UInt8(code % 8)
    }
}

private struct VirtIOInputTestRegisters: VirtIOInputRegisterAccess {
    let hardware: VirtIOInputTestHardware

    func read8(at offset: UInt) -> UInt8 {
        let configuration = VirtIOInputMMIORegisterLayout.deviceConfiguration
        guard offset >= configuration else { return 0 }
        hardware.configurationReadCount += 1
        if offset == configuration { return hardware.configurationSelector }
        if offset == configuration + 1 {
            return hardware.configurationSubselector
        }
        if offset == configuration + 2 {
            return hardware.configurationSize()
        }
        if offset >= configuration + 8,
           offset < configuration + 136 {
            return hardware.configurationByte(
                at: offset - configuration - 8
            )
        }
        return 0
    }

    func read32(at offset: UInt) -> UInt32 {
        switch offset {
        case VirtIOInputMMIORegisterLayout.magic:
            return hardware.magic
        case VirtIOInputMMIORegisterLayout.version:
            return hardware.version
        case VirtIOInputMMIORegisterLayout.deviceID:
            return hardware.deviceID
        case VirtIOInputMMIORegisterLayout.vendorID:
            return 0x554d_4551
        case VirtIOInputMMIORegisterLayout.deviceFeatures:
            if hardware.deviceFeatureSelection == 0 {
                return UInt32(truncatingIfNeeded: hardware.offeredFeatures)
            }
            return UInt32(truncatingIfNeeded: hardware.offeredFeatures >> 32)
        case VirtIOInputMMIORegisterLayout.queueMaximum:
            return selectedValue(hardware.queueMaximum)
        case VirtIOInputMMIORegisterLayout.queueReady:
            return selectedValue(hardware.queueReady)
        case VirtIOInputMMIORegisterLayout.interruptStatus:
            return hardware.interruptStatus
        case VirtIOInputMMIORegisterLayout.status:
            return hardware.status
        case VirtIOInputMMIORegisterLayout.configurationGeneration:
            if hardware.unstableConfiguration {
                hardware.configurationGeneration &+= 1
            }
            return hardware.configurationGeneration
        default:
            return 0
        }
    }

    func write8(_ value: UInt8, at offset: UInt) {
        let configuration = VirtIOInputMMIORegisterLayout.deviceConfiguration
        if offset == configuration {
            hardware.configurationSelector = value
        } else if offset == configuration + 1 {
            hardware.configurationSubselector = value
        }
    }

    func write32(_ value: UInt32, at offset: UInt) {
        switch offset {
        case VirtIOInputMMIORegisterLayout.deviceFeaturesSelect:
            hardware.deviceFeatureSelection = value
        case VirtIOInputMMIORegisterLayout.driverFeaturesSelect:
            hardware.driverFeatureSelection = value
        case VirtIOInputMMIORegisterLayout.driverFeatures:
            if hardware.driverFeatureSelection == 0 {
                hardware.driverFeatures &= 0xffff_ffff_0000_0000
                hardware.driverFeatures |= UInt64(value)
            } else {
                hardware.driverFeatures &= 0x0000_0000_ffff_ffff
                hardware.driverFeatures |= UInt64(value) << 32
            }
        case VirtIOInputMMIORegisterLayout.queueSelect:
            hardware.selectedQueue = UInt16(truncatingIfNeeded: value)
        case VirtIOInputMMIORegisterLayout.queueSize:
            setSelectedValue(
                UInt16(truncatingIfNeeded: value),
                in: &hardware.queueSize
            )
        case VirtIOInputMMIORegisterLayout.queueReady:
            setSelectedValue(value, in: &hardware.queueReady)
        case VirtIOInputMMIORegisterLayout.queueDescriptorLow:
            setAddressLow(value, in: &hardware.descriptorAddress)
        case VirtIOInputMMIORegisterLayout.queueDescriptorHigh:
            setAddressHigh(value, in: &hardware.descriptorAddress)
        case VirtIOInputMMIORegisterLayout.queueDriverLow:
            setAddressLow(value, in: &hardware.availableAddress)
        case VirtIOInputMMIORegisterLayout.queueDriverHigh:
            setAddressHigh(value, in: &hardware.availableAddress)
        case VirtIOInputMMIORegisterLayout.queueDeviceLow:
            setAddressLow(value, in: &hardware.usedAddress)
        case VirtIOInputMMIORegisterLayout.queueDeviceHigh:
            setAddressHigh(value, in: &hardware.usedAddress)
        case VirtIOInputMMIORegisterLayout.queueNotify:
            hardware.notifications.append(value)
            hardware.notificationStatuses.append(hardware.status)
        case VirtIOInputMMIORegisterLayout.interruptAcknowledge:
            hardware.interruptStatus &= ~value
        case VirtIOInputMMIORegisterLayout.status:
            if value == 0, hardware.ignoreResetWrites {
                return
            }
            hardware.status = value
            if hardware.rejectFeatures,
               value & 8 != 0 {
                hardware.status &= ~UInt32(8)
            }
        default:
            break
        }
    }

    func loadDMAUInt16(at cpuAddress: UInt64) -> UInt16 {
        PhysicalBytes.readLE16(at: cpuAddress)
    }

    func storeDMAUInt16(_ value: UInt16, at cpuAddress: UInt64) {
        PhysicalBytes.writeLE16(value, at: cpuAddress)
    }

    func synchronizeDMA() {
        hardware.synchronizationCount += 1
    }

    func spinWaitHint() {
        hardware.spinCount += 1
    }

    private func selectedValue<T>(_ values: [T]) -> T {
        let index = Int(hardware.selectedQueue)
        return values[index < values.count ? index : 0]
    }

    private func setSelectedValue<T>(_ value: T, in values: inout [T]) {
        let index = Int(hardware.selectedQueue)
        guard index < values.count else { return }
        values[index] = value
    }

    private func setAddressLow(_ value: UInt32, in values: inout [UInt64]) {
        let index = Int(hardware.selectedQueue)
        guard index < values.count else { return }
        values[index] &= 0xffff_ffff_0000_0000
        values[index] |= UInt64(value)
    }

    private func setAddressHigh(_ value: UInt32, in values: inout [UInt64]) {
        let index = Int(hardware.selectedQueue)
        guard index < values.count else { return }
        values[index] &= 0x0000_0000_ffff_ffff
        values[index] |= UInt64(value) << 32
    }
}

private final class VirtIOInputTestDMA {
    static let totalByteCount = 4_096
    let pointer: UnsafeMutableRawPointer
    let storage: VirtIOInputDMAStorage

    init() {
        pointer = UnsafeMutableRawPointer.allocate(
            byteCount: Self.totalByteCount,
            alignment: 4_096
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: 4_096)
        let address = UInt64(UInt(bitPattern: pointer))
        guard let queue = DMAMapping(
                  cpuPhysicalAddress: address,
                  deviceAddress: address,
                  byteCount: 2_048,
                  deviceAddressWidth: .bits64,
                  coherency: .hardwareCoherent
              ),
              let buffers = DMAMapping(
                  cpuPhysicalAddress: address + 2_048,
                  deviceAddress: address + 2_048,
                  byteCount: VirtIOInputDMAStorage.requiredEventBufferByteCount,
                  deviceAddressWidth: .bits64,
                  coherency: .hardwareCoherent
              ),
              let storage = VirtIOInputDMAStorage(
                  eventQueue: queue,
                  eventBuffers: buffers
              )
        else {
            pointer.deallocate()
            fatalError("unable to make test DMA storage")
        }
        self.storage = storage
    }

    deinit {
        pointer.deallocate()
    }
}

private struct VirtIOInputRecordingSink: InputEventSink {
    var events = [InputEvent]()

    mutating func submit(_ event: InputEvent) -> InputEventSubmissionResult {
        events.append(event)
        return .enqueued(sequence: UInt64(events.count))
    }
}

@main
struct VirtIOInputDeviceTests {
    static func main() {
        initializesModernEventQueue()
        translatesKeyboardAndPointerFrames()
        boundsPollingAndRecyclesDescriptors()
        failsClosedOnMalformedCompletion()
        handlesConfigurationChanges()
        rejectsInvalidDevicesAndNegotiation()
        print("VirtIO input device: 6 groups passed")
    }

    private static func initializesModernEventQueue() {
        let hardware = VirtIOInputTestHardware()
        let dma = VirtIOInputTestDMA()
        var device = makeDevice(hardware: hardware, dma: dma)
        let capabilities = VirtIOInputCapabilities(
            keyboard: true,
            relativePointer: true,
            primaryPointerButton: true,
            verticalScroll: true,
            horizontalScroll: true
        )
        expect(
            device.initialize() == .ready(capabilities),
            "modern input device did not initialize"
        )
        expect(
            device.offeredFeatures == hardware.offeredFeatures
                && device.negotiatedFeatures == VirtIOTransportFeature.version1
                && hardware.driverFeatures == VirtIOTransportFeature.version1,
            "feature negotiation accepted an unsupported feature"
        )
        expect(
            hardware.queueSize[0] == 64 && hardware.queueReady[0] == 1,
            "eventq 0 was not configured"
        )
        expect(
            hardware.queueSize[1] == 0 && hardware.queueReady[1] == 0,
            "statusq 1 was configured without an owner"
        )
        let queue = dma.storage.eventQueue
        let layout = dma.storage.eventQueueLayout
        expect(
            PhysicalBytes.readLE16(
                at: queue.cpuPhysicalAddress + layout.availableOffset
            ) == 1,
            "polling queue did not suppress interrupts"
        )
        expect(
            PhysicalBytes.readLE16(
                at: queue.cpuPhysicalAddress + layout.availableOffset + 2
            ) == 64,
            "all 64 event buffers were not published"
        )
        var index: UInt16 = 0
        while index < 64 {
            let descriptor = queue.cpuPhysicalAddress + UInt64(index) * 16
            expect(
                PhysicalBytes.readLE64(at: descriptor)
                    == dma.storage.eventBuffers.deviceAddress
                        + UInt64(index) * 8,
                "event descriptor address changed"
            )
            expect(
                PhysicalBytes.readLE32(at: descriptor + 8) == 8
                    && PhysicalBytes.readLE16(at: descriptor + 12) == 2
                    && PhysicalBytes.readLE16(at: descriptor + 14) == 0,
                "event descriptor ownership changed"
            )
            expect(
                PhysicalBytes.readLE16(
                    at: queue.cpuPhysicalAddress + layout.availableOffset
                        + 4 + UInt64(index) * 2
                ) == index,
                "initial event descriptor order changed"
            )
            index &+= 1
        }
        expect(
            hardware.notifications == [0]
                && hardware.notificationStatuses.count == 1
                && hardware.notificationStatuses[0] & 4 != 0,
            "event buffers were not notified after DRIVER_OK"
        )
        expect(
            device.hasPublishedQueue && hardware.configurationReadCount > 0,
            "queue ownership or capability discovery was not recorded"
        )
        withExtendedLifetime(dma) {}
    }

    private static func translatesKeyboardAndPointerFrames() {
        let hardware = VirtIOInputTestHardware()
        let dma = VirtIOInputTestDMA()
        var device = initializedDevice(hardware: hardware, dma: dma)
        complete(hardware, 1, 30, 1)
        complete(hardware, 0, 0, 0)
        complete(hardware, 1, 30, 0)
        complete(hardware, 0, 0, 0)
        complete(hardware, 2, 0, UInt32(bitPattern: -19))
        complete(hardware, 2, 1, 37)
        complete(hardware, 2, 8, UInt32(bitPattern: -2))
        complete(hardware, 2, 6, 3)
        complete(hardware, 1, 0x110, 1)
        complete(hardware, 0, 0, 0)

        var sink = VirtIOInputRecordingSink()
        guard case .processed(let summary) = device.poll(
                  timestampTicks: 900,
                  into: &sink
              )
        else { fail("completed input events were not processed") }
        expect(summary.consumedWireEventCount == 10, "wire count changed")
        expect(
            summary.translation.recognizedWireEventCount == 10
                && summary.translation.synchronizationCount == 3
                && summary.translation.ignoredWireEventCount == 0,
            "translation accounting changed"
        )
        expect(sink.events.count == 8, "canonical emission count changed")
        expect(
            sink.events[0].kind == .keyboardUsage
                && sink.events[0].keyboardUsage == .keyboard(0x04)
                && sink.events[0].isPressed,
            "evdev A press did not map to HID"
        )
        expect(
            sink.events[1].kind == .synchronization
                && sink.events[2].kind == .keyboardUsage
                && !sink.events[2].isPressed
                && sink.events[3].kind == .synchronization,
            "keyboard SYN_REPORT framing changed"
        )
        expect(
            sink.events[4].kind == .pointerButton
                && sink.events[4].code == 1
                && sink.events[4].isPressed,
            "primary pointer button did not translate"
        )
        expect(
            sink.events[5].kind == .pointerMotion
                && sink.events[5].value0 == -19
                && sink.events[5].value1 == 37,
            "signed relative motion was not coalesced"
        )
        expect(
            sink.events[6].kind == .pointerScroll
                && sink.events[6].value0 == -2
                && sink.events[6].value1 == 3
                && sink.events[7].kind == .synchronization,
            "signed scrolling or pointer frame boundary changed"
        )
        withExtendedLifetime(dma) {}
    }

    private static func boundsPollingAndRecyclesDescriptors() {
        let hardware = VirtIOInputTestHardware()
        let dma = VirtIOInputTestDMA()
        var device = initializedDevice(hardware: hardware, dma: dma)
        complete(hardware, 1, 30, 1)
        complete(hardware, 1, 30, 0)
        complete(hardware, 0, 0, 0)
        var sink = VirtIOInputRecordingSink()
        guard case .processed(let first) = device.poll(
                  timestampTicks: 1,
                  maximumEvents: 2,
                  into: &sink
              )
        else { fail("bounded poll did not process its prefix") }
        expect(first.consumedWireEventCount == 2, "poll exceeded its bound")
        let availableIndexAddress = dma.storage.eventQueue.cpuPhysicalAddress
            + dma.storage.eventQueueLayout.availableOffset + 2
        expect(
            PhysicalBytes.readLE16(at: availableIndexAddress) == 66,
            "processed descriptors were not recycled"
        )
        guard case .processed(let second) = device.poll(
                  timestampTicks: 2,
                  maximumEvents: 2,
                  into: &sink
              )
        else { fail("bounded poll lost its remainder") }
        expect(
            second.consumedWireEventCount == 1
                && PhysicalBytes.readLE16(at: availableIndexAddress) == 67,
            "remaining descriptor was not recycled"
        )
        expect(
            device.poll(timestampTicks: 3, maximumEvents: 0, into: &sink)
                == .invalidLimit,
            "zero poll limit was accepted"
        )
        withExtendedLifetime(dma) {}
    }

    private static func failsClosedOnMalformedCompletion() {
        let hardware = VirtIOInputTestHardware()
        let dma = VirtIOInputTestDMA()
        var device = initializedDevice(hardware: hardware, dma: dma)
        complete(hardware, 1, 30, 1, reportedByteCount: 7)
        let availableIndexAddress = dma.storage.eventQueue.cpuPhysicalAddress
            + dma.storage.eventQueueLayout.availableOffset + 2
        let before = PhysicalBytes.readLE16(at: availableIndexAddress)
        var sink = VirtIOInputRecordingSink()
        expect(
            device.poll(timestampTicks: 1, into: &sink) == .deviceFault,
            "short event completion was accepted"
        )
        expect(
            PhysicalBytes.readLE16(at: availableIndexAddress) == before,
            "malformed descriptor was returned to the device"
        )
        expect(
            hardware.status & 128 != 0
                && device.hasPublishedQueue
                && sink.events.isEmpty,
            "malformed completion did not preserve ownership and fault state"
        )

        let duplicateHardware = VirtIOInputTestHardware()
        let duplicateDMA = VirtIOInputTestDMA()
        var duplicateDevice = initializedDevice(
            hardware: duplicateHardware,
            dma: duplicateDMA
        )
        complete(duplicateHardware, 1, 30, 1)
        expect(
            duplicateHardware.completeEvent(
                type: 0,
                code: 0,
                value: 0,
                reportedDescriptorID: 0
            ),
            "test device could not make duplicate completion"
        )
        let duplicateAvailableIndex = duplicateDMA.storage.eventQueue
            .cpuPhysicalAddress
            + duplicateDMA.storage.eventQueueLayout.availableOffset + 2
        var duplicateSink = VirtIOInputRecordingSink()
        expect(
            duplicateDevice.poll(timestampTicks: 2, into: &duplicateSink)
                == .deviceFault,
            "duplicate descriptor completion was accepted"
        )
        expect(
            PhysicalBytes.readLE16(at: duplicateAvailableIndex) == 64
                && duplicateSink.events.isEmpty,
            "duplicate completion partially emitted or recycled ownership"
        )
        withExtendedLifetime(dma) {}
        withExtendedLifetime(duplicateDMA) {}
    }

    private static func handlesConfigurationChanges() {
        let hardware = VirtIOInputTestHardware()
        let dma = VirtIOInputTestDMA()
        var device = initializedDevice(hardware: hardware, dma: dma)
        hardware.supportsKeyboard = false
        hardware.interruptStatus |= 2
        var sink = VirtIOInputRecordingSink()
        expect(
            device.poll(timestampTicks: 1, into: &sink)
                == .idle(configurationRefreshed: true),
            "configuration change was not refreshed"
        )
        expect(
            device.capabilities == VirtIOInputCapabilities(
                keyboard: false,
                relativePointer: true,
                primaryPointerButton: true,
                verticalScroll: true,
                horizontalScroll: true
            ) && hardware.interruptStatus == 0,
            "refreshed capabilities or interrupt acknowledgement changed"
        )
        hardware.supportsRelativePointer = false
        hardware.supportsPrimaryButton = false
        hardware.interruptStatus |= 2
        expect(
            device.poll(timestampTicks: 2, into: &sink) == .deviceFault,
            "unusable changed capabilities were accepted"
        )
        withExtendedLifetime(dma) {}
    }

    private static func rejectsInvalidDevicesAndNegotiation() {
        expectInitialization(
            mutate: { $0.deviceID = 1 },
            result: .wrongDevice
        )
        expectInitialization(
            mutate: { $0.version = 1 },
            result: .legacyTransport
        )
        expectInitialization(
            mutate: { $0.offeredFeatures = 0 },
            result: .missingRequiredFeature
        )
        expectInitialization(
            mutate: { $0.rejectFeatures = true },
            result: .featureNegotiationFailed
        )
        expectInitialization(
            mutate: { $0.queueMaximum[0] = 63 },
            result: .queueUnavailable
        )
        expectInitialization(
            mutate: { $0.unstableConfiguration = true },
            result: .invalidDeviceConfiguration
        )
        expectInitialization(
            mutate: {
                $0.supportsKeyboard = false
                $0.supportsRelativePointer = false
                $0.supportsPrimaryButton = false
            },
            result: .unsupportedDeviceConfiguration
        )
        expectResetTimeout()
        expectZeroPollLimit()
    }

    private static func expectInitialization(
        mutate: (VirtIOInputTestHardware) -> Void,
        result: VirtIOInputInitializationResult
    ) {
        let hardware = VirtIOInputTestHardware()
        mutate(hardware)
        let dma = VirtIOInputTestDMA()
        var device = makeDevice(hardware: hardware, dma: dma)
        expect(device.initialize() == result, "initialization result changed")
        withExtendedLifetime(dma) {}
    }

    private static func expectResetTimeout() {
        let hardware = VirtIOInputTestHardware()
        hardware.status = 1
        hardware.ignoreResetWrites = true
        let dma = VirtIOInputTestDMA()
        var device = VirtIOInputDevice(
            registers: VirtIOInputTestRegisters(hardware: hardware),
            storage: dma.storage,
            deviceID: InputDeviceID(rawValue: 11),
            maximumPollCount: 3
        )
        expect(
            device.initialize() == .deviceResetFailed
                && hardware.spinCount == 3,
            "reset timeout was not bounded"
        )
        withExtendedLifetime(dma) {}
    }

    private static func expectZeroPollLimit() {
        let hardware = VirtIOInputTestHardware()
        let dma = VirtIOInputTestDMA()
        var device = VirtIOInputDevice(
            registers: VirtIOInputTestRegisters(hardware: hardware),
            storage: dma.storage,
            deviceID: InputDeviceID(rawValue: 11),
            maximumPollCount: 0
        )
        expect(
            device.initialize() == .invalidPollLimit,
            "zero initialization poll limit was accepted"
        )
        withExtendedLifetime(dma) {}
    }

    private static func makeDevice(
        hardware: VirtIOInputTestHardware,
        dma: VirtIOInputTestDMA
    ) -> VirtIOInputDevice<VirtIOInputTestRegisters> {
        VirtIOInputDevice(
            registers: VirtIOInputTestRegisters(hardware: hardware),
            storage: dma.storage,
            deviceID: InputDeviceID(rawValue: 11)
        )
    }

    private static func initializedDevice(
        hardware: VirtIOInputTestHardware,
        dma: VirtIOInputTestDMA
    ) -> VirtIOInputDevice<VirtIOInputTestRegisters> {
        var device = makeDevice(hardware: hardware, dma: dma)
        guard case .ready = device.initialize() else {
            fail("test input device did not initialize")
        }
        return device
    }

    private static func complete(
        _ hardware: VirtIOInputTestHardware,
        _ type: UInt16,
        _ code: UInt16,
        _ value: UInt32,
        reportedByteCount: UInt32 = 8
    ) {
        expect(
            hardware.completeEvent(
                type: type,
                code: code,
                value: value,
                reportedByteCount: reportedByteCount
            ),
            "test device could not complete event"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        print("FAIL:", message)
        fatalError()
    }
}
