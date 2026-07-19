private final class VirtIOBlockTestHardware {
    var magic: UInt32 = 0x7472_6976
    var version: UInt32 = 2
    var deviceID: UInt32 = 2
    var offeredFeatures: UInt64 = VirtIOTransportFeature.version1
        | (UInt64(1) << 5)
        | (UInt64(1) << 9)
        | (UInt64(1) << 28)
    var driverFeatures: UInt64 = 0
    var deviceFeatureSelection: UInt32 = 0
    var driverFeatureSelection: UInt32 = 0
    var selectedQueue: UInt32 = 0
    var queueMaximum: UInt32 = 8
    var queueSize: UInt32 = 0
    var queueReady: UInt32 = 0
    var descriptorAddress: UInt64 = 0
    var availableAddress: UInt64 = 0
    var usedAddress: UInt64 = 0
    var status: UInt32 = 0
    var interruptStatus: UInt32 = 0
    var configurationGeneration: UInt32 = 4
    var capacity: UInt64 = 32
    var unstableConfiguration = false
    var rejectFeatures = false
    var ignoreResetWrites = false
    var completeRequests = true
    var corruptDescriptorID = false
    var corruptWrittenByteCount = false
    var forcedRequestStatus: UInt8?
    var availableDeviceIndex: UInt16 = 0
    var usedDeviceIndex: UInt16 = 0
    var flushCount = 0
    var synchronizationCount = 0
    var spinCount = 0
    var notifications = 0
    var disk = [UInt8](repeating: 0, count: 32 * 512)

    func processOneRequest() {
        guard completeRequests,
              queueReady == 1,
              queueSize == UInt32(VirtIOBlockDMAStorage.requestQueueSize),
              descriptorAddress != 0,
              availableAddress != 0,
              usedAddress != 0
        else { return }
        let published = PhysicalBytes.readLE16(at: availableAddress + 2)
        guard published != availableDeviceIndex else { return }
        let availableSlot = UInt64(
            availableDeviceIndex % UInt16(queueSize)
        )
        let head = PhysicalBytes.readLE16(
            at: availableAddress + 4 + availableSlot * 2
        )
        guard head == 0 else { return }

        let headerDescriptor = descriptorAddress
        let headerAddress = PhysicalBytes.readLE64(at: headerDescriptor)
        guard PhysicalBytes.readLE32(at: headerDescriptor + 8) == 16,
              PhysicalBytes.readLE16(at: headerDescriptor + 12) & 1 != 0
        else { return }
        let type = PhysicalBytes.readLE32(at: headerAddress)
        let reserved = PhysicalBytes.readLE32(at: headerAddress + 4)
        let sector = PhysicalBytes.readLE64(at: headerAddress + 8)
        guard reserved == 0 else { return }

        var writtenByteCount: UInt32 = 1
        let statusDescriptorIndex: UInt16
        if type == 0 || type == 1 {
            guard PhysicalBytes.readLE16(at: headerDescriptor + 14) == 1
            else { return }
            let dataDescriptor = descriptorAddress + 16
            let dataAddress = PhysicalBytes.readLE64(at: dataDescriptor)
            guard PhysicalBytes.readLE32(at: dataDescriptor + 8) == 512,
                  PhysicalBytes.readLE16(at: dataDescriptor + 12) & 1 != 0,
                  PhysicalBytes.readLE16(at: dataDescriptor + 14) == 2,
                  sector < capacity,
                  sector <= UInt64(Int.max / 512)
            else { return }
            let diskOffset = Int(sector) * 512
            if type == 0 {
                guard PhysicalBytes.readLE16(at: dataDescriptor + 12) & 2 != 0
                else { return }
                var index = 0
                while index < 512 {
                    PhysicalBytes.write8(
                        disk[diskOffset + index],
                        at: dataAddress + UInt64(index)
                    )
                    index += 1
                }
                writtenByteCount = 513
            } else {
                guard PhysicalBytes.readLE16(at: dataDescriptor + 12) & 2 == 0
                else { return }
                var index = 0
                while index < 512 {
                    disk[diskOffset + index] = PhysicalBytes.read8(
                        at: dataAddress + UInt64(index)
                    )
                    index += 1
                }
            }
            statusDescriptorIndex = 2
        } else if type == 4 {
            guard sector == 0,
                  PhysicalBytes.readLE16(at: headerDescriptor + 14) == 2
            else { return }
            flushCount += 1
            statusDescriptorIndex = 2
        } else {
            return
        }

        let statusDescriptor = descriptorAddress
            + UInt64(statusDescriptorIndex) * 16
        let statusAddress = PhysicalBytes.readLE64(at: statusDescriptor)
        guard PhysicalBytes.readLE32(at: statusDescriptor + 8) == 1,
              PhysicalBytes.readLE16(at: statusDescriptor + 12) == 2,
              PhysicalBytes.readLE16(at: statusDescriptor + 14) == 0
        else { return }
        PhysicalBytes.write8(forcedRequestStatus ?? 0, at: statusAddress)

        let usedSlot = UInt64(usedDeviceIndex % UInt16(queueSize))
        let usedElement = usedAddress + 4 + usedSlot * 8
        PhysicalBytes.writeLE32(
            corruptDescriptorID ? 7 : 0,
            at: usedElement
        )
        PhysicalBytes.writeLE32(
            corruptWrittenByteCount ? 99 : writtenByteCount,
            at: usedElement + 4
        )
        availableDeviceIndex &+= 1
        usedDeviceIndex &+= 1
        PhysicalBytes.writeLE16(usedDeviceIndex, at: usedAddress + 2)
        interruptStatus |= 1
    }
}

private struct VirtIOBlockTestRegisters: VirtIOBlockRegisterAccess {
    let hardware: VirtIOBlockTestHardware

    func read32(at offset: UInt) -> UInt32 {
        switch offset {
        case VirtIOBlockMMIORegisterLayout.magic:
            return hardware.magic
        case VirtIOBlockMMIORegisterLayout.version:
            return hardware.version
        case VirtIOBlockMMIORegisterLayout.deviceID:
            return hardware.deviceID
        case VirtIOBlockMMIORegisterLayout.vendorID:
            return 0x554d_4551
        case VirtIOBlockMMIORegisterLayout.deviceFeatures:
            if hardware.deviceFeatureSelection == 0 {
                return UInt32(truncatingIfNeeded: hardware.offeredFeatures)
            }
            return UInt32(truncatingIfNeeded: hardware.offeredFeatures >> 32)
        case VirtIOBlockMMIORegisterLayout.queueMaximum:
            return hardware.queueMaximum
        case VirtIOBlockMMIORegisterLayout.queueReady:
            return hardware.queueReady
        case VirtIOBlockMMIORegisterLayout.interruptStatus:
            return hardware.interruptStatus
        case VirtIOBlockMMIORegisterLayout.status:
            return hardware.status
        case VirtIOBlockMMIORegisterLayout.configurationGeneration:
            if hardware.unstableConfiguration {
                hardware.configurationGeneration &+= 1
            }
            return hardware.configurationGeneration
        case VirtIOBlockMMIORegisterLayout.deviceConfiguration:
            return UInt32(truncatingIfNeeded: hardware.capacity)
        case VirtIOBlockMMIORegisterLayout.deviceConfiguration + 4:
            return UInt32(truncatingIfNeeded: hardware.capacity >> 32)
        default:
            return 0
        }
    }

    func write32(_ value: UInt32, at offset: UInt) {
        switch offset {
        case VirtIOBlockMMIORegisterLayout.deviceFeaturesSelect:
            hardware.deviceFeatureSelection = value
        case VirtIOBlockMMIORegisterLayout.driverFeaturesSelect:
            hardware.driverFeatureSelection = value
        case VirtIOBlockMMIORegisterLayout.driverFeatures:
            if hardware.driverFeatureSelection == 0 {
                hardware.driverFeatures &= 0xffff_ffff_0000_0000
                hardware.driverFeatures |= UInt64(value)
            } else {
                hardware.driverFeatures &= 0x0000_0000_ffff_ffff
                hardware.driverFeatures |= UInt64(value) << 32
            }
        case VirtIOBlockMMIORegisterLayout.queueSelect:
            hardware.selectedQueue = value
        case VirtIOBlockMMIORegisterLayout.queueSize:
            hardware.queueSize = value
        case VirtIOBlockMMIORegisterLayout.queueReady:
            hardware.queueReady = value
        case VirtIOBlockMMIORegisterLayout.queueDescriptorLow:
            hardware.descriptorAddress &= 0xffff_ffff_0000_0000
            hardware.descriptorAddress |= UInt64(value)
        case VirtIOBlockMMIORegisterLayout.queueDescriptorHigh:
            hardware.descriptorAddress &= 0x0000_0000_ffff_ffff
            hardware.descriptorAddress |= UInt64(value) << 32
        case VirtIOBlockMMIORegisterLayout.queueDriverLow:
            hardware.availableAddress &= 0xffff_ffff_0000_0000
            hardware.availableAddress |= UInt64(value)
        case VirtIOBlockMMIORegisterLayout.queueDriverHigh:
            hardware.availableAddress &= 0x0000_0000_ffff_ffff
            hardware.availableAddress |= UInt64(value) << 32
        case VirtIOBlockMMIORegisterLayout.queueDeviceLow:
            hardware.usedAddress &= 0xffff_ffff_0000_0000
            hardware.usedAddress |= UInt64(value)
        case VirtIOBlockMMIORegisterLayout.queueDeviceHigh:
            hardware.usedAddress &= 0x0000_0000_ffff_ffff
            hardware.usedAddress |= UInt64(value) << 32
        case VirtIOBlockMMIORegisterLayout.queueNotify:
            hardware.notifications += 1
            hardware.processOneRequest()
        case VirtIOBlockMMIORegisterLayout.interruptAcknowledge:
            hardware.interruptStatus &= ~value
        case VirtIOBlockMMIORegisterLayout.status:
            if value == 0, hardware.ignoreResetWrites { return }
            if hardware.rejectFeatures, value & 8 != 0 {
                hardware.status = value & ~8
            } else {
                hardware.status = value
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
}

@main
struct VirtIOBlockDeviceTests {
    static func main() {
        initializesModernDeviceAndNegotiatesOnlySupportedFeatures()
        transfersCompleteBlocksAndFlushes()
        enforcesReadOnlyAndBufferBounds()
        rejectsInvalidInitializationContracts()
        failsClosedOnTimedOutAndMalformedCompletions()
        rejectsConfigurationMutationAfterPublication()
        mapsDeviceReportedErrors()
        print("VirtIO block device host tests: 7 groups passed")
    }

    private static func initializesModernDeviceAndNegotiatesOnlySupportedFeatures() {
        withDMAStorage { storage in
            let hardware = VirtIOBlockTestHardware()
            let result = VirtIOBlockDevice<VirtIOBlockTestRegisters>.initialize(
                registers: VirtIOBlockTestRegisters(hardware: hardware),
                storage: storage
            )
            guard case .ready(let device) = result else {
                fail("modern block device initialization failed")
            }
            expect(device.geometry.logicalBlockByteCount == 512, "logical block size")
            expect(device.geometry.logicalBlockCount == 32, "capacity")
            expect(device.isReadOnly, "read-only feature was not accepted")
            expect(device.supportsFlush, "flush feature was not accepted")
            expect(
                device.negotiatedFeatures
                    == VirtIOTransportFeature.version1
                        | (UInt64(1) << 5) | (UInt64(1) << 9),
                "unknown feature was acknowledged"
            )
            expect(hardware.queueReady == 1, "request queue not ready")
            expect(hardware.queueSize == 8, "request queue size")
            expect(hardware.descriptorAddress != 0, "descriptor address")
            expect(hardware.availableAddress != 0, "available address")
            expect(hardware.usedAddress != 0, "used address")
            expect(hardware.status & 15 == 15, "device status progression")
        }
    }

    private static func transfersCompleteBlocksAndFlushes() {
        withDMAStorage { storage in
            let hardware = VirtIOBlockTestHardware()
            hardware.offeredFeatures = VirtIOTransportFeature.version1
                | (UInt64(1) << 9)
            guard case .ready(var device) =
                    VirtIOBlockDevice<VirtIOBlockTestRegisters>.initialize(
                        registers: VirtIOBlockTestRegisters(hardware: hardware),
                        storage: storage
                    )
            else { fail("writable device initialization") }

            var input = [UInt8](repeating: 0, count: 512)
            var index = 0
            while index < input.count {
                input[index] = UInt8(truncatingIfNeeded: index * 17 + 3)
                index += 1
            }
            let write = input.withUnsafeBytes {
                device.writeBlock(at: 7, from: $0)
            }
            expect(write == .success, "block write")
            expect(hardware.disk[7 * 512 + 9] == input[9], "write payload")

            var output = [UInt8](repeating: 0, count: 512)
            let read = output.withUnsafeMutableBytes {
                device.readBlock(at: 7, into: $0)
            }
            expect(read == .success, "block read")
            expect(output == input, "read payload")
            expect(device.synchronize() == .success, "flush")
            expect(hardware.flushCount == 1, "flush request count")
            expect(hardware.notifications == 3, "request notification count")
            expect(hardware.interruptStatus == 0, "used interrupt acknowledgment")
        }
    }

    private static func enforcesReadOnlyAndBufferBounds() {
        withDMAStorage { storage in
            let hardware = VirtIOBlockTestHardware()
            hardware.offeredFeatures = VirtIOTransportFeature.version1
                | (UInt64(1) << 5)
            guard case .ready(var device) =
                    VirtIOBlockDevice<VirtIOBlockTestRegisters>.initialize(
                        registers: VirtIOBlockTestRegisters(hardware: hardware),
                        storage: storage
                    )
            else { fail("read-only initialization") }
            var full = [UInt8](repeating: 1, count: 512)
            expect(
                full.withUnsafeBytes { device.writeBlock(at: 0, from: $0) }
                    == .readOnly,
                "read-only write accepted"
            )
            var short = [UInt8](repeating: 0, count: 511)
            expect(
                short.withUnsafeMutableBytes { device.readBlock(at: 0, into: $0) }
                    == .invalidBuffer,
                "short read buffer accepted"
            )
            expect(
                full.withUnsafeMutableBytes { device.readBlock(at: 32, into: $0) }
                    == .invalidBlock,
                "past-capacity read accepted"
            )
            expect(device.synchronize() == .success, "no-flush barrier")
            expect(hardware.notifications == 0, "invalid operation reached queue")
        }
    }

    private static func rejectsInvalidInitializationContracts() {
        withDMAStorage { storage in
            expectFailure(
                storage: storage,
                configure: { $0.version = 1 },
                expected: .legacyTransport
            )
            expectFailure(
                storage: storage,
                configure: { $0.deviceID = 18 },
                expected: .wrongDevice
            )
            expectFailure(
                storage: storage,
                configure: { $0.offeredFeatures = 0 },
                expected: .missingRequiredFeature
            )
            expectFailure(
                storage: storage,
                configure: { $0.rejectFeatures = true },
                expected: .featureNegotiationFailed
            )
            expectFailure(
                storage: storage,
                configure: { $0.capacity = 0 },
                expected: .invalidCapacity
            )
            expectFailure(
                storage: storage,
                configure: { $0.unstableConfiguration = true },
                expected: .unstableConfiguration
            )
            expectFailure(
                storage: storage,
                configure: { $0.queueMaximum = 4 },
                expected: .queueUnavailable
            )
            expectFailure(
                storage: storage,
                configure: { $0.ignoreResetWrites = true; $0.status = 15 },
                expected: .deviceResetFailed,
                maximumPollCount: 3
            )
            let zeroPoll = VirtIOBlockDevice<VirtIOBlockTestRegisters>.initialize(
                registers: VirtIOBlockTestRegisters(
                    hardware: VirtIOBlockTestHardware()
                ),
                storage: storage,
                maximumPollCount: 0
            )
            guard case .failure(.invalidPollLimit) = zeroPoll else {
                fail("zero initialization poll limit accepted")
            }
        }
    }

    private static func failsClosedOnTimedOutAndMalformedCompletions() {
        withDMAStorage { storage in
            let timeoutHardware = VirtIOBlockTestHardware()
            timeoutHardware.offeredFeatures = VirtIOTransportFeature.version1
            timeoutHardware.completeRequests = false
            guard case .ready(var timedOut) =
                    VirtIOBlockDevice<VirtIOBlockTestRegisters>.initialize(
                        registers: VirtIOBlockTestRegisters(hardware: timeoutHardware),
                        storage: storage,
                        maximumPollCount: 3
                    )
            else { fail("timeout device initialization") }
            var bytes = [UInt8](repeating: 0, count: 512)
            expect(
                bytes.withUnsafeMutableBytes { timedOut.readBlock(at: 0, into: $0) }
                    == .transportFailure,
                "request timeout accepted"
            )
            expect(
                bytes.withUnsafeMutableBytes { timedOut.readBlock(at: 0, into: $0) }
                    == .transportFailure,
                "faulted device reused"
            )
        }
        withDMAStorage { storage in
            let malformedHardware = VirtIOBlockTestHardware()
            malformedHardware.offeredFeatures = VirtIOTransportFeature.version1
            malformedHardware.corruptDescriptorID = true
            guard case .ready(var malformed) =
                    VirtIOBlockDevice<VirtIOBlockTestRegisters>.initialize(
                        registers: VirtIOBlockTestRegisters(hardware: malformedHardware),
                        storage: storage
                    )
            else { fail("malformed device initialization") }
            var bytes = [UInt8](repeating: 0, count: 512)
            expect(
                bytes.withUnsafeMutableBytes { malformed.readBlock(at: 0, into: $0) }
                    == .transportFailure,
                "corrupt used ID accepted"
            )
        }
    }

    private static func rejectsConfigurationMutationAfterPublication() {
        withDMAStorage { storage in
            let hardware = VirtIOBlockTestHardware()
            hardware.offeredFeatures = VirtIOTransportFeature.version1
            guard case .ready(var device) =
                    VirtIOBlockDevice<VirtIOBlockTestRegisters>.initialize(
                        registers: VirtIOBlockTestRegisters(hardware: hardware),
                        storage: storage
                    )
            else { fail("configuration-change device initialization") }
            hardware.interruptStatus = 2
            var bytes = [UInt8](repeating: 0, count: 512)
            expect(
                bytes.withUnsafeMutableBytes { device.readBlock(at: 0, into: $0) }
                    == .transportFailure,
                "capacity mutation accepted"
            )
            expect(hardware.interruptStatus == 0, "config interrupt not acknowledged")
            expect(hardware.notifications == 0, "faulted geometry reached queue")
        }
    }

    private static func mapsDeviceReportedErrors() {
        withDMAStorage { storage in
            let hardware = VirtIOBlockTestHardware()
            hardware.offeredFeatures = VirtIOTransportFeature.version1
            hardware.forcedRequestStatus = 1
            guard case .ready(var device) =
                    VirtIOBlockDevice<VirtIOBlockTestRegisters>.initialize(
                        registers: VirtIOBlockTestRegisters(hardware: hardware),
                        storage: storage
                    )
            else { fail("device-error initialization") }
            var bytes = [UInt8](repeating: 0, count: 512)
            expect(
                bytes.withUnsafeMutableBytes { device.readBlock(at: 0, into: $0) }
                    == .transportFailure,
                "device I/O error reported success"
            )
        }
    }

    private static func expectFailure(
        storage: VirtIOBlockDMAStorage,
        configure: (VirtIOBlockTestHardware) -> Void,
        expected: VirtIOBlockInitializationFailure,
        maximumPollCount: UInt64 = 20
    ) {
        let hardware = VirtIOBlockTestHardware()
        configure(hardware)
        let result = VirtIOBlockDevice<VirtIOBlockTestRegisters>.initialize(
            registers: VirtIOBlockTestRegisters(hardware: hardware),
            storage: storage,
            maximumPollCount: maximumPollCount
        )
        guard case .failure(let actual) = result, actual == expected else {
            fail("unexpected initialization result")
        }
    }

    private static func withDMAStorage(
        _ body: (VirtIOBlockDMAStorage) -> Void
    ) {
        let page = UnsafeMutableRawPointer.allocate(
            byteCount: 4_096,
            alignment: 4_096
        )
        page.initializeMemory(as: UInt8.self, repeating: 0, count: 4_096)
        defer { page.deallocate() }
        let base = UInt64(UInt(bitPattern: page))
        guard let queue = mapping(base: base, offset: 0, byteCount: 256),
              let header = mapping(base: base, offset: 256, byteCount: 16),
              let data = mapping(base: base, offset: 512, byteCount: 512),
              let status = mapping(base: base, offset: 1_024, byteCount: 1),
              let storage = VirtIOBlockDMAStorage(
                  requestQueue: queue,
                  requestHeader: header,
                  data: data,
                  status: status
              )
        else { fail("valid DMA storage rejected") }
        body(storage)
    }

    private static func mapping(
        base: UInt64,
        offset: UInt64,
        byteCount: UInt64
    ) -> DMAMapping? {
        DMAMapping(
            cpuPhysicalAddress: base + offset,
            deviceAddress: base + offset,
            byteCount: byteCount,
            deviceAddressWidth: .bits64,
            coherency: .hardwareCoherent
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
