private final class VirtIONetworkTestHardware {
    var magic = UInt32(0x7472_6976)
    var version = UInt32(2)
    var deviceID = UInt32(1)
    var offeredFeatures = VirtIOTransportFeature.version1
        | VirtIONetworkFeature.mac
        | VirtIONetworkFeature.status
        | VirtIONetworkFeature.mtu
        | (UInt64(1) << 0)   // VIRTIO_NET_F_CSUM, intentionally unsupported.
        | (UInt64(1) << 15)  // VIRTIO_NET_F_MRG_RXBUF, intentionally unsupported.
        | (UInt64(1) << 28)  // VIRTIO_F_RING_INDIRECT_DESC, not used here.
    var driverFeatures: UInt64 = 0
    var deviceFeatureSelection: UInt32 = 0
    var driverFeatureSelection: UInt32 = 0
    var selectedQueue: UInt16 = 0
    var queueMaximum = [UInt32(4), UInt32(1)]
    var queueSize = [UInt16(0), UInt16(0)]
    var queueReady = [UInt32(0), UInt32(0)]
    var descriptorAddress = [UInt64(0), UInt64(0)]
    var availableAddress = [UInt64(0), UInt64(0)]
    var usedAddress = [UInt64(0), UInt64(0)]
    var status: UInt32 = 0
    var interruptStatus: UInt32 = 0
    var rejectFeatures = false
    var ignoreResetWrites = false
    var completeTransmits = true
    var unstableConfiguration = false
    var configurationGeneration: UInt32 = 0
    var transmitAvailableIndex: UInt16 = 0
    var transmitUsedIndex: UInt16 = 0
    var notificationQueues = [UInt32]()
    var notificationStatuses = [UInt32]()
    var synchronizationCount = 0
    var spinCount = 0
    var configuration = [UInt8](repeating: 0, count: 12)

    init() {
        setMAC(MACAddress(0x52, 0x54, 0x00, 0x12, 0x34, 0x56))
        setLink(up: true)
        setMTU(1_500)
    }

    func setMAC(_ address: MACAddress) {
        configuration[0] = address.octet0
        configuration[1] = address.octet1
        configuration[2] = address.octet2
        configuration[3] = address.octet3
        configuration[4] = address.octet4
        configuration[5] = address.octet5
    }

    func setLink(up: Bool) {
        configuration[6] = up ? 1 : 0
        configuration[7] = 0
    }

    func setMTU(_ mtu: UInt16) {
        configuration[10] = UInt8(truncatingIfNeeded: mtu)
        configuration[11] = UInt8(truncatingIfNeeded: mtu >> 8)
    }

    func completeTransmitIfAvailable() {
        let queueIndex = 1
        guard completeTransmits,
              queueReady[queueIndex] == 1,
              queueSize[queueIndex] > 0,
              descriptorAddress[queueIndex] != 0,
              availableAddress[queueIndex] != 0,
              usedAddress[queueIndex] != 0
        else {
            return
        }
        let availableIndex = PhysicalBytes.readLE16(
            at: availableAddress[queueIndex] + 2
        )
        guard availableIndex != transmitAvailableIndex else { return }
        let slot = UInt64(transmitAvailableIndex % queueSize[queueIndex])
        let descriptorID = PhysicalBytes.readLE16(
            at: availableAddress[queueIndex] + 4 + slot * 2
        )
        let descriptor = descriptorAddress[queueIndex]
            + UInt64(descriptorID) * 16
        let submittedByteCount = PhysicalBytes.readLE32(at: descriptor + 8)
        let usedSlot = UInt64(transmitUsedIndex % queueSize[queueIndex])
        let usedElement = usedAddress[queueIndex] + 4 + usedSlot * 8
        PhysicalBytes.writeLE32(UInt32(descriptorID), at: usedElement)
        PhysicalBytes.writeLE32(0, at: usedElement + 4)
        transmitAvailableIndex &+= 1
        transmitUsedIndex &+= 1
        PhysicalBytes.writeLE16(
            transmitUsedIndex,
            at: usedAddress[queueIndex] + 2
        )
        interruptStatus |= 1
        require(submittedByteCount >= 24, "short TX descriptor reached device")
    }
}

private struct VirtIONetworkTestRegisters: VirtIONetworkRegisterAccess {
    let hardware: VirtIONetworkTestHardware

    func read8(at offset: UInt) -> UInt8 {
        let base = VirtIONetworkMMIORegisterLayout.deviceConfiguration
        guard offset >= base, offset < base + UInt(hardware.configuration.count)
        else {
            return 0
        }
        return hardware.configuration[Int(offset - base)]
    }

    func read16(at offset: UInt) -> UInt16 {
        UInt16(read8(at: offset)) | UInt16(read8(at: offset + 1)) << 8
    }

    func read32(at offset: UInt) -> UInt32 {
        switch offset {
        case VirtIONetworkMMIORegisterLayout.magic:
            return hardware.magic
        case VirtIONetworkMMIORegisterLayout.version:
            return hardware.version
        case VirtIONetworkMMIORegisterLayout.deviceID:
            return hardware.deviceID
        case VirtIONetworkMMIORegisterLayout.vendorID:
            return 0x554d_4551
        case VirtIONetworkMMIORegisterLayout.deviceFeatures:
            if hardware.deviceFeatureSelection == 0 {
                return UInt32(truncatingIfNeeded: hardware.offeredFeatures)
            }
            return UInt32(truncatingIfNeeded: hardware.offeredFeatures >> 32)
        case VirtIONetworkMMIORegisterLayout.queueMaximum:
            return selectedQueueValue(hardware.queueMaximum)
        case VirtIONetworkMMIORegisterLayout.queueReady:
            return selectedQueueValue(hardware.queueReady)
        case VirtIONetworkMMIORegisterLayout.interruptStatus:
            return hardware.interruptStatus
        case VirtIONetworkMMIORegisterLayout.status:
            return hardware.status
        case VirtIONetworkMMIORegisterLayout.configurationGeneration:
            if hardware.unstableConfiguration {
                hardware.configurationGeneration &+= 1
            }
            return hardware.configurationGeneration
        default:
            return 0
        }
    }

    func write32(_ value: UInt32, at offset: UInt) {
        switch offset {
        case VirtIONetworkMMIORegisterLayout.deviceFeaturesSelect:
            hardware.deviceFeatureSelection = value
        case VirtIONetworkMMIORegisterLayout.driverFeaturesSelect:
            hardware.driverFeatureSelection = value
        case VirtIONetworkMMIORegisterLayout.driverFeatures:
            if hardware.driverFeatureSelection == 0 {
                hardware.driverFeatures &= 0xffff_ffff_0000_0000
                hardware.driverFeatures |= UInt64(value)
            } else {
                hardware.driverFeatures &= 0x0000_0000_ffff_ffff
                hardware.driverFeatures |= UInt64(value) << 32
            }
        case VirtIONetworkMMIORegisterLayout.queueSelect:
            hardware.selectedQueue = UInt16(truncatingIfNeeded: value)
        case VirtIONetworkMMIORegisterLayout.queueSize:
            setSelectedQueueValue(
                UInt16(truncatingIfNeeded: value),
                in: &hardware.queueSize
            )
        case VirtIONetworkMMIORegisterLayout.queueReady:
            setSelectedQueueValue(value, in: &hardware.queueReady)
        case VirtIONetworkMMIORegisterLayout.queueDescriptorLow:
            setQueueAddressLow(value, in: &hardware.descriptorAddress)
        case VirtIONetworkMMIORegisterLayout.queueDescriptorHigh:
            setQueueAddressHigh(value, in: &hardware.descriptorAddress)
        case VirtIONetworkMMIORegisterLayout.queueDriverLow:
            setQueueAddressLow(value, in: &hardware.availableAddress)
        case VirtIONetworkMMIORegisterLayout.queueDriverHigh:
            setQueueAddressHigh(value, in: &hardware.availableAddress)
        case VirtIONetworkMMIORegisterLayout.queueDeviceLow:
            setQueueAddressLow(value, in: &hardware.usedAddress)
        case VirtIONetworkMMIORegisterLayout.queueDeviceHigh:
            setQueueAddressHigh(value, in: &hardware.usedAddress)
        case VirtIONetworkMMIORegisterLayout.queueNotify:
            hardware.notificationQueues.append(value)
            hardware.notificationStatuses.append(hardware.status)
            if value == 1 { hardware.completeTransmitIfAvailable() }
        case VirtIONetworkMMIORegisterLayout.interruptAcknowledge:
            hardware.interruptStatus &= ~value
        case VirtIONetworkMMIORegisterLayout.status:
            if value == 0 && hardware.ignoreResetWrites { return }
            hardware.status = value
            if hardware.rejectFeatures && value & 8 != 0 {
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

    private func selectedQueueValue<T>(_ values: [T]) -> T where T: FixedWidthInteger {
        let index = Int(hardware.selectedQueue)
        return index < values.count ? values[index] : 0
    }

    private func setSelectedQueueValue<T>(
        _ value: T,
        in values: inout [T]
    ) where T: FixedWidthInteger {
        let index = Int(hardware.selectedQueue)
        if index < values.count { values[index] = value }
    }

    private func setQueueAddressLow(
        _ value: UInt32,
        in addresses: inout [UInt64]
    ) {
        let index = Int(hardware.selectedQueue)
        guard index < addresses.count else { return }
        addresses[index] &= 0xffff_ffff_0000_0000
        addresses[index] |= UInt64(value)
    }

    private func setQueueAddressHigh(
        _ value: UInt32,
        in addresses: inout [UInt64]
    ) {
        let index = Int(hardware.selectedQueue)
        guard index < addresses.count else { return }
        addresses[index] &= 0x0000_0000_ffff_ffff
        addresses[index] |= UInt64(value) << 32
    }
}

private typealias TestVirtIONetworkDevice =
    VirtIONetworkDevice<VirtIONetworkTestRegisters>

@main
struct VirtIONetworkDeviceTests {
    static func main() {
        validatesSplitQueueAndCallerOwnedStorage()
        negotiatesModernNetworkFeaturesAndTwoQueues()
        receivesAndRecyclesPackets()
        consumesPacketsWhenOutputIsTooSmall()
        transmitsThroughQueueOne()
        rejectsUnsupportedDevicesAndConfigurations()
        faultsOnMalformedCompletionsAndTimeouts()
        print("VirtIO network device: 7 groups passed")
    }

    private static func validatesSplitQueueAndCallerOwnedStorage() {
        require(VirtIONetworkSplitQueueLayout(size: 0) == nil, "zero queue accepted")
        require(VirtIONetworkSplitQueueLayout(size: 3) == nil, "non-power-of-two queue accepted")
        guard let layout = VirtIONetworkSplitQueueLayout(size: 4) else {
            fail("valid queue rejected")
        }
        require(layout.descriptorOffset == 0, "descriptor offset changed")
        require(layout.availableOffset == 64, "available ring offset changed")
        require(layout.usedOffset == 80, "used ring was not four-byte aligned")
        require(layout.requiredByteCount == 118, "split-ring span is wrong")

        let coherent = mapping(cpu: 0x10_0000, device: 0x20_0000, bytes: 4_096)
        let alias = mapping(cpu: 0x10_0800, device: 0x30_0000, bytes: 4_096)
        require(
            VirtIONetworkDMAStorage(
                receiveQueue: coherent,
                receiveQueueSize: 4,
                transmitQueue: alias,
                transmitQueueSize: 1,
                receiveBuffers: mapping(
                    cpu: 0x40_0000,
                    device: 0x50_0000,
                    bytes: 4 * 1_536
                ),
                transmitBuffer: mapping(
                    cpu: 0x60_0000,
                    device: 0x70_0000,
                    bytes: 1_536
                )
            ) == nil,
            "CPU-overlapping mappings were accepted"
        )
        let noncoherent = mapping(
            cpu: 0x80_0000,
            device: 0x90_0000,
            bytes: 4_096,
            coherency: .softwareManaged
        )
        require(
            VirtIONetworkDMAStorage(
                receiveQueue: noncoherent,
                receiveQueueSize: 4,
                transmitQueue: mapping(
                    cpu: 0xa0_0000,
                    device: 0xb0_0000,
                    bytes: 4_096
                ),
                transmitQueueSize: 1,
                receiveBuffers: mapping(
                    cpu: 0xc0_0000,
                    device: 0xd0_0000,
                    bytes: 4 * 1_536
                ),
                transmitBuffer: mapping(
                    cpu: 0xe0_0000,
                    device: 0xf0_0000,
                    bytes: 1_536
                )
            ) == nil,
            "non-coherent QEMU storage was accepted"
        )
    }

    private static func negotiatesModernNetworkFeaturesAndTwoQueues() {
        withFixture { device, hardware, storage in
            require(device.initialize() == .ready, "modern device did not initialize")
            require(
                device.macAddress == MACAddress(0x52, 0x54, 0, 0x12, 0x34, 0x56),
                "device MAC was not retained"
            )
            require(device.mtu == 1_500, "device MTU was not retained")
            require(device.linkState == .up, "negotiated link status was ignored")
            require(hardware.queueReady == [1, 1], "both queues were not made ready")
            require(hardware.queueSize == [4, 1], "wrong queue sizes were programmed")
            require(
                hardware.driverFeatures
                    == VirtIOTransportFeature.version1
                        | VirtIONetworkFeature.mac
                        | VirtIONetworkFeature.status
                        | VirtIONetworkFeature.mtu,
                "unrequested or missing features were acknowledged"
            )
            require(
                PhysicalBytes.readLE16(
                    at: storage.receiveQueue.cpuPhysicalAddress
                        + storage.receiveQueueLayout.availableOffset + 2
                ) == 4,
                "receive descriptors were not published"
            )
            var descriptor: UInt16 = 0
            while descriptor < 4 {
                let address = storage.receiveQueue.cpuPhysicalAddress
                    + UInt64(descriptor) * 16
                require(
                    PhysicalBytes.readLE64(at: address)
                        == storage.receiveBuffers.deviceAddress
                            + UInt64(descriptor) * 1_536,
                    "RX descriptor address is wrong"
                )
                require(
                    PhysicalBytes.readLE32(at: address + 8) == 1_536,
                    "RX descriptor capacity is wrong"
                )
                require(
                    PhysicalBytes.readLE16(at: address + 12) == 2,
                    "RX descriptor is not device-writable"
                )
                descriptor += 1
            }
            require(hardware.notificationQueues.first == 0, "RX queue was not notified")
            require(
                hardware.notificationStatuses.first.map { $0 & 4 != 0 } == true,
                "RX queue was notified before DRIVER_OK"
            )
        }
        withFixture(configure: { hardware in
            hardware.offeredFeatures = VirtIOTransportFeature.version1
                | VirtIONetworkFeature.mac
            hardware.setLink(up: false)
            hardware.setMTU(0)
        }) { device, hardware, _ in
            require(
                device.initialize() == .ready,
                "minimal modern feature set was rejected"
            )
            require(device.mtu == 1_500, "absent MTU feature changed default")
            require(
                device.linkState == .up,
                "absent status feature did not imply link up"
            )
            require(
                hardware.driverFeatures
                    == VirtIOTransportFeature.version1
                        | VirtIONetworkFeature.mac,
                "minimal feature selection changed"
            )
        }
    }

    private static func receivesAndRecyclesPackets() {
        withFixture { device, hardware, storage in
            require(device.initialize() == .ready, "fixture did not initialize")
            var expected = [UInt8](repeating: 0, count: 60)
            var index = 0
            while index < expected.count {
                expected[index] = UInt8(truncatingIfNeeded: index &* 3)
                index += 1
            }
            injectReceivePacket(
                descriptorID: 2,
                frame: expected,
                storage: storage,
                hardware: hardware
            )
            var output = [UInt8](repeating: 0xaa, count: 128)
            let result = output.withUnsafeMutableBytes {
                device.pollReceive(into: $0)
            }
            require(result == .received(byteCount: 60), "packet was not received")
            require(Array(output.prefix(60)) == expected, "received bytes changed")
            let available = storage.receiveQueue.cpuPhysicalAddress
                + storage.receiveQueueLayout.availableOffset
            require(
                PhysicalBytes.readLE16(at: available + 2) == 5,
                "RX descriptor was not recycled"
            )
            require(PhysicalBytes.readLE16(at: available + 4) == 2, "wrong descriptor was recycled")
            require(hardware.interruptStatus == 0, "polled RX interrupt was not acknowledged")
        }
    }

    private static func consumesPacketsWhenOutputIsTooSmall() {
        withFixture { device, hardware, storage in
            require(device.initialize() == .ready, "fixture did not initialize")
            let frame = [UInt8](repeating: 0x5a, count: 60)
            injectReceivePacket(
                descriptorID: 1,
                frame: frame,
                storage: storage,
                hardware: hardware
            )
            var output = [UInt8](repeating: 0, count: 20)
            let result = output.withUnsafeMutableBytes {
                device.pollReceive(into: $0)
            }
            require(
                result == .outputTooSmall(requiredByteCount: 60),
                "short output was not reported precisely"
            )
            let available = storage.receiveQueue.cpuPhysicalAddress
                + storage.receiveQueueLayout.availableOffset
            require(PhysicalBytes.readLE16(at: available + 2) == 5, "short packet wedged RX")
            require(
                device.pollReceive(
                    into: UnsafeMutableRawBufferPointer(start: nil, count: 0)
                ) == .noPacket,
                "consumed packet was repeated"
            )
        }
    }

    private static func transmitsThroughQueueOne() {
        withFixture { device, hardware, storage in
            require(device.initialize() == .ready, "fixture did not initialize")
            var frame = [UInt8](repeating: 0, count: 60)
            var index = 0
            while index < frame.count {
                frame[index] = UInt8(truncatingIfNeeded: 0xa0 + index)
                index += 1
            }
            let result = frame.withUnsafeBytes { device.transmit($0) }
            require(result == .sent, "TX packet was not completed")
            require(hardware.notificationQueues.last == 1, "TX used the wrong queue")
            let packet = storage.transmitBuffer.cpuPhysicalAddress
            index = 0
            while index < 12 {
                require(
                    PhysicalBytes.read8(at: packet + UInt64(index)) == 0,
                    "TX header requested an unnegotiated offload"
                )
                index += 1
            }
            index = 0
            while index < frame.count {
                require(
                    PhysicalBytes.read8(at: packet + 12 + UInt64(index))
                        == frame[index],
                    "TX payload changed"
                )
                index += 1
            }
            let descriptor = storage.transmitQueue.cpuPhysicalAddress
            require(
                PhysicalBytes.readLE32(at: descriptor + 8) == 72,
                "TX length omitted VirtIO header"
            )
            require(PhysicalBytes.readLE16(at: descriptor + 12) == 0, "TX descriptor is writable")

            hardware.setLink(up: false)
            let notifications = hardware.notificationQueues.count
            require(
                frame.withUnsafeBytes { device.transmit($0) } == .linkDown,
                "link-down TX was submitted"
            )
            require(
                hardware.notificationQueues.count == notifications,
                "link-down TX notified device"
            )
        }
    }

    private static func rejectsUnsupportedDevicesAndConfigurations() {
        withFixture(maximumPollCount: 0) { device, hardware, _ in
            require(
                device.initialize() == .invalidPollLimit,
                "zero poll limit was accepted"
            )
            require(hardware.status == 0, "invalid poll limit touched device")
        }
        withFixture(configure: { hardware in
            hardware.deviceID = 16
            hardware.status = 4
        }) { device, hardware, _ in
            require(device.initialize() == .wrongDevice, "GPU was accepted as net")
            require(hardware.status == 4, "wrong device was modified")
        }
        withFixture(configure: { hardware in
            hardware.version = 1
            hardware.status = 4
        }) { device, hardware, _ in
            require(
                device.initialize() == .legacyTransport,
                "legacy transport was accepted"
            )
            require(hardware.status == 4, "legacy transport was modified")
        }
        withFixture(maximumPollCount: 3, configure: { hardware in
            hardware.status = 4
            hardware.ignoreResetWrites = true
        }) { device, hardware, _ in
            require(
                device.initialize() == .deviceResetFailed,
                "stalled reset was accepted"
            )
            require(hardware.spinCount == 3, "reset poll bound was not exact")
        }
        withFixture(configure: { hardware in
            hardware.offeredFeatures = VirtIOTransportFeature.version1
        }) { device, hardware, _ in
            require(
                device.initialize() == .missingRequiredFeature,
                "device without MAC feature was accepted"
            )
            require(hardware.status & 128 != 0, "feature rejection did not fail device")
        }
        withFixture(configure: { hardware in
            hardware.rejectFeatures = true
        }) { device, _, _ in
            require(
                device.initialize() == .featureNegotiationFailed,
                "cleared FEATURES_OK was ignored"
            )
        }
        withFixture(configure: { hardware in
            hardware.queueMaximum[0] = 2
        }) { device, _, _ in
            require(
                device.initialize() == .queueUnavailable(index: 0),
                "undersized RX queue was accepted"
            )
        }
        withFixture(configure: { hardware in
            hardware.queueMaximum[1] = 0
        }) { device, _, _ in
            require(
                device.initialize() == .queueUnavailable(index: 1),
                "missing TX queue was accepted"
            )
        }
        withFixture(configure: { hardware in
            hardware.setMTU(1_501)
        }) { device, _, _ in
            require(
                device.initialize() == .invalidDeviceConfiguration,
                "unsupported jumbo MTU was accepted"
            )
        }
        withFixture(configure: { hardware in
            hardware.unstableConfiguration = true
        }) { device, _, _ in
            require(
                device.initialize() == .invalidDeviceConfiguration,
                "unstable configuration was accepted"
            )
        }
    }

    private static func faultsOnMalformedCompletionsAndTimeouts() {
        withFixture { device, hardware, storage in
            require(device.initialize() == .ready, "fixture did not initialize")
            let frame = [UInt8](repeating: 0x44, count: 60)
            injectReceivePacket(
                descriptorID: 0,
                frame: frame,
                storage: storage,
                hardware: hardware,
                headerFlags: 1
            )
            var output = [UInt8](repeating: 0, count: 60)
            require(
                output.withUnsafeMutableBytes { device.pollReceive(into: $0) }
                    == .malformedFrame,
                "unsupported RX offload header was accepted"
            )
            require(device.linkState == .faulted, "malformed RX did not fault device")
        }
        withFixture(maximumPollCount: 3, configure: { hardware in
            hardware.completeTransmits = false
        }) { device, hardware, _ in
            require(device.initialize() == .ready, "fixture did not initialize")
            let frame = [UInt8](repeating: 0x88, count: 60)
            require(
                frame.withUnsafeBytes { device.transmit($0) } == .timedOut,
                "stalled TX did not time out"
            )
            require(hardware.spinCount == 3, "TX poll bound was not exact")
            require(device.linkState == .faulted, "TX timeout did not fault device")
        }
    }

    private static func withFixture(
        maximumPollCount: UInt64 = 8,
        configure: (VirtIONetworkTestHardware) -> Void = { _ in },
        _ body: (
            inout TestVirtIONetworkDevice,
            VirtIONetworkTestHardware,
            VirtIONetworkDMAStorage
        ) -> Void
    ) {
        var receiveQueueBytes = [UInt8](repeating: 0, count: 4_096)
        var transmitQueueBytes = [UInt8](repeating: 0, count: 4_096)
        var receiveBufferBytes = [UInt8](repeating: 0, count: 4 * 1_536)
        var transmitBufferBytes = [UInt8](repeating: 0, count: 1_536)
        receiveQueueBytes.withUnsafeMutableBytes { receiveQueue in
            transmitQueueBytes.withUnsafeMutableBytes { transmitQueue in
                receiveBufferBytes.withUnsafeMutableBytes { receiveBuffers in
                    transmitBufferBytes.withUnsafeMutableBytes { transmitBuffer in
                        guard let receiveQueueAddress = receiveQueue.baseAddress,
                              let transmitQueueAddress = transmitQueue.baseAddress,
                              let receiveBufferAddress = receiveBuffers.baseAddress,
                              let transmitBufferAddress = transmitBuffer.baseAddress
                        else {
                            fail("fixture allocation failed")
                        }
                        let receiveQueueValue = UInt64(UInt(bitPattern: receiveQueueAddress))
                        let transmitQueueValue = UInt64(UInt(bitPattern: transmitQueueAddress))
                        let receiveBufferValue = UInt64(UInt(bitPattern: receiveBufferAddress))
                        let transmitBufferValue = UInt64(UInt(bitPattern: transmitBufferAddress))
                        guard let storage = VirtIONetworkDMAStorage(
                                  receiveQueue: mapping(
                                      cpu: receiveQueueValue,
                                      device: receiveQueueValue,
                                      bytes: UInt64(receiveQueue.count)
                                  ),
                                  receiveQueueSize: 4,
                                  transmitQueue: mapping(
                                      cpu: transmitQueueValue,
                                      device: transmitQueueValue,
                                      bytes: UInt64(transmitQueue.count)
                                  ),
                                  transmitQueueSize: 1,
                                  receiveBuffers: mapping(
                                      cpu: receiveBufferValue,
                                      device: receiveBufferValue,
                                      bytes: UInt64(receiveBuffers.count)
                                  ),
                                  transmitBuffer: mapping(
                                      cpu: transmitBufferValue,
                                      device: transmitBufferValue,
                                      bytes: UInt64(transmitBuffer.count)
                                  )
                              )
                        else {
                            fail("valid fixture storage was rejected")
                        }
                        let hardware = VirtIONetworkTestHardware()
                        configure(hardware)
                        var device = TestVirtIONetworkDevice(
                            registers: VirtIONetworkTestRegisters(
                                hardware: hardware
                            ),
                            storage: storage,
                            maximumPollCount: maximumPollCount
                        )
                        body(&device, hardware, storage)
                    }
                }
            }
        }
    }

    private static func injectReceivePacket(
        descriptorID: UInt16,
        frame: [UInt8],
        storage: VirtIONetworkDMAStorage,
        hardware: VirtIONetworkTestHardware,
        headerFlags: UInt8 = 0
    ) {
        let packet = storage.receiveBuffers.cpuPhysicalAddress
            + UInt64(descriptorID) * 1_536
        var index = 0
        while index < 12 {
            PhysicalBytes.write8(0, at: packet + UInt64(index))
            index += 1
        }
        PhysicalBytes.write8(headerFlags, at: packet)
        PhysicalBytes.writeLE16(1, at: packet + 10)
        index = 0
        while index < frame.count {
            PhysicalBytes.write8(frame[index], at: packet + 12 + UInt64(index))
            index += 1
        }
        let used = storage.receiveQueue.cpuPhysicalAddress
            + storage.receiveQueueLayout.usedOffset
        let usedIndex = PhysicalBytes.readLE16(at: used + 2)
        let slot = UInt64(usedIndex % storage.receiveQueueLayout.size)
        PhysicalBytes.writeLE32(
            UInt32(descriptorID),
            at: used + 4 + slot * 8
        )
        PhysicalBytes.writeLE32(
            UInt32(12 + frame.count),
            at: used + 8 + slot * 8
        )
        PhysicalBytes.writeLE16(usedIndex &+ 1, at: used + 2)
        hardware.interruptStatus |= 1
    }

    private static func mapping(
        cpu: UInt64,
        device: UInt64,
        bytes: UInt64,
        coherency: DMACoherency = .hardwareCoherent
    ) -> DMAMapping {
        guard let result = DMAMapping(
                  cpuPhysicalAddress: cpu,
                  deviceAddress: device,
                  byteCount: bytes,
                  deviceAddressWidth: .bits64,
                  coherency: coherency
              )
        else {
            fatalError("invalid DMA fixture")
        }
        return result
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: StaticString
) {
    if !condition() { fatalError("\(message)") }
}

private func fail(_ message: StaticString) -> Never {
    fatalError("\(message)")
}
