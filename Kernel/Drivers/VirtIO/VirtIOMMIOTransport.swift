struct VirtIOMMIOIdentity: Equatable {
    let version: UInt32
    let deviceID: UInt32
    let vendorID: UInt32
}

enum VirtIOMMIOInitializationResult: Equatable {
    case ready
    case invalidResource
    case wrongDevice
    case legacyTransport
    case missingRequiredFeature
    case featureNegotiationFailed
    case queueUnavailable
}

enum VirtIOMMIORequestResult: Equatable {
    case completed(responseByteCount: UInt32)
    case invalidRequest
    case timedOut
    case malformedCompletion
    case deviceNeedsReset
}

/// Modern VirtIO 1.x MMIO transport with one polling split virtqueue. The
/// transport owns no policy about GPU commands and can be reused by another
/// VirtIO device once that device supplies a queue contract.
struct VirtIOMMIOTransport {
    static let magicValue: UInt32 = 0x7472_6976
    static let modernVersion: UInt32 = 2
    static let gpuDeviceID: UInt32 = 16

    private enum Register {
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

    private enum Status {
        static let acknowledge: UInt32 = 1
        static let driver: UInt32 = 2
        static let driverOK: UInt32 = 4
        static let featuresOK: UInt32 = 8
        static let deviceNeedsReset: UInt32 = 64
        static let failed: UInt32 = 128
    }

    private enum QueueLayout {
        static let pageByteCount: UInt64 = 4096
        static let maximumSize: UInt16 = 8
        static let descriptorOffset: UInt64 = 0x000
        static let availableOffset: UInt64 = 0x080
        static let usedOffset: UInt64 = 0x100
        static let requestOffset: UInt64 = 0x200
        static let responseOffset: UInt64 = 0x400
        static let bufferCapacity: UInt32 = 512
    }

    private let baseAddress: UInt
    private var queueMapping: DMAMapping?
    private(set) var offeredFeatures: UInt64 = 0
    private(set) var negotiatedFeatures: UInt64 = 0
    private(set) var queueSize: UInt16 = 0
    private(set) var requestAddress: UInt64 = 0
    private(set) var responseAddress: UInt64 = 0
    private var descriptorAddress: UInt64 = 0
    private var availableAddress: UInt64 = 0
    private var usedAddress: UInt64 = 0
    private var requestDeviceAddress: UInt64 = 0
    private var responseDeviceAddress: UInt64 = 0
    private var availableIndex: UInt16 = 0
    private var usedIndex: UInt16 = 0

    init?(resource: DeviceResource) {
        guard resource.baseAddress <= UInt64(UInt.max),
              resource.length >= 0x100,
              resource.baseAddress & 0x3 == 0
        else {
            return nil
        }
        baseAddress = UInt(resource.baseAddress)
    }

    var identity: VirtIOMMIOIdentity {
        VirtIOMMIOIdentity(
            version: read(Register.version),
            deviceID: read(Register.deviceID),
            vendorID: read(Register.vendorID)
        )
    }

    var hasVirtIOMagic: Bool {
        read(Register.magic) == Self.magicValue
    }

    /// Reads the GPU device-specific configuration as one generation-stable
    /// snapshot. The bounded retry is required because its four fields are not
    /// one atomic MMIO operation.
    func readGPUDeviceConfiguration(
        maximumAttempts: Int = 8
    ) -> VirtIOGPUDeviceConfigurationReadResult {
        guard maximumAttempts > 0 else { return .invalidAttemptLimit }
        let discovered = identity
        guard hasVirtIOMagic,
              discovered.version == Self.modernVersion,
              discovered.deviceID == Self.gpuDeviceID
        else {
            return .wrongDevice
        }

        var attempt = 0
        while attempt < maximumAttempts {
            let before = read(Register.configurationGeneration) & 0xff
            let pendingEvents = read(Register.deviceConfiguration)
            let scanoutCount = read(Register.deviceConfiguration + 8)
            let capsetCount = read(Register.deviceConfiguration + 12)
            let after = read(Register.configurationGeneration) & 0xff
            if before == after {
                guard let configuration = VirtIOGPUDeviceConfiguration(
                          pendingEvents: pendingEvents,
                          scanoutCount: scanoutCount,
                          capsetCount: capsetCount
                      )
                else {
                    return .invalidConfiguration
                }
                return .ready(configuration)
            }
            attempt += 1
        }
        return .unstable
    }

    mutating func initializeModernGPU(
        queueMapping: DMAMapping,
        requestedDeviceFeatures: UInt64 = 0
    ) -> VirtIOMMIOInitializationResult {
        let cpuBase = queueMapping.cpuPhysicalAddress
        let deviceBase = queueMapping.deviceAddress
        guard queueMapping.coherency == .hardwareCoherent,
              queueMapping.byteCount >= QueueLayout.pageByteCount,
              cpuBase & (QueueLayout.pageByteCount - 1) == 0,
              deviceBase & (QueueLayout.pageByteCount - 1) == 0,
              cpuBase <= UInt64(UInt.max),
              PhysicalBytes.zero(
                  address: cpuBase,
                  byteCount: QueueLayout.pageByteCount
              )
        else {
            return .invalidResource
        }
        guard hasVirtIOMagic else { return .wrongDevice }
        let discovered = identity
        guard discovered.deviceID == Self.gpuDeviceID else {
            return .wrongDevice
        }
        guard discovered.version == Self.modernVersion else {
            return .legacyTransport
        }

        write(0, Register.status)
        guard read(Register.status) == 0 else {
            return .featureNegotiationFailed
        }
        var status = Status.acknowledge
        write(status, Register.status)
        status |= Status.driver
        write(status, Register.status)

        let offered = readDeviceFeatures()
        offeredFeatures = offered
        negotiatedFeatures = 0
        guard let selection = VirtIOFeatureSelection.select(
            offered: offered,
            required: VirtIOTransportFeature.version1,
            optional: requestedDeviceFeatures
        ) else {
            failDevice()
            return .missingRequiredFeature
        }
        let accepted = selection.accepted
        write(0, Register.driverFeaturesSelect)
        write(UInt32(truncatingIfNeeded: accepted), Register.driverFeatures)
        write(1, Register.driverFeaturesSelect)
        write(
            UInt32(truncatingIfNeeded: accepted >> 32),
            Register.driverFeatures
        )
        status |= Status.featuresOK
        write(status, Register.status)
        guard read(Register.status) & Status.featuresOK != 0 else {
            failDevice()
            return .featureNegotiationFailed
        }
        negotiatedFeatures = accepted

        write(0, Register.queueSelect)
        guard read(Register.queueReady) == 0 else {
            failDevice()
            return .queueUnavailable
        }
        let maximum = read(Register.queueMaximum)
        guard maximum >= 2 else {
            failDevice()
            return .queueUnavailable
        }
        let selected = UInt16(
            maximum >= UInt32(QueueLayout.maximumSize)
                ? QueueLayout.maximumSize
                : highestPowerOfTwo(notGreaterThan: UInt16(maximum))
        )
        guard selected >= 2 else {
            failDevice()
            return .queueUnavailable
        }

        descriptorAddress = cpuBase + QueueLayout.descriptorOffset
        availableAddress = cpuBase + QueueLayout.availableOffset
        usedAddress = cpuBase + QueueLayout.usedOffset
        requestAddress = cpuBase + QueueLayout.requestOffset
        responseAddress = cpuBase + QueueLayout.responseOffset
        requestDeviceAddress = deviceBase + QueueLayout.requestOffset
        responseDeviceAddress = deviceBase + QueueLayout.responseOffset
        self.queueMapping = queueMapping
        queueSize = selected
        availableIndex = 0
        usedIndex = 0
        PhysicalBytes.writeLE16(1, at: availableAddress)

        write(UInt32(selected), Register.queueSize)
        writeAddress(deviceBase + QueueLayout.descriptorOffset,
                     low: Register.queueDescriptorLow,
                     high: Register.queueDescriptorHigh)
        writeAddress(deviceBase + QueueLayout.availableOffset,
                     low: Register.queueDriverLow,
                     high: Register.queueDriverHigh)
        writeAddress(deviceBase + QueueLayout.usedOffset,
                     low: Register.queueDeviceLow,
                     high: Register.queueDeviceHigh)
        write(1, Register.queueReady)
        guard read(Register.queueReady) == 1 else {
            failDevice()
            return .queueUnavailable
        }

        status |= Status.driverOK
        write(status, Register.status)
        AArch64.synchronizeData()
        return .ready
    }

    mutating func prepareBuffers() -> Bool {
        guard queueSize >= 2 else { return false }
        return PhysicalBytes.zero(
            address: requestAddress,
            byteCount: UInt64(QueueLayout.bufferCapacity)
        ) && PhysicalBytes.zero(
            address: responseAddress,
            byteCount: UInt64(QueueLayout.bufferCapacity)
        )
    }

    mutating func submit(
        requestByteCount: UInt32,
        responseCapacity: UInt32 = QueueLayout.bufferCapacity,
        pollLimit: UInt64 = 5_000_000
    ) -> VirtIOMMIORequestResult {
        guard queueSize >= 2,
              requestByteCount > 0,
              requestByteCount <= QueueLayout.bufferCapacity,
              responseCapacity >= 24,
              responseCapacity <= QueueLayout.bufferCapacity,
              pollLimit > 0
        else {
            return .invalidRequest
        }
        return submitDescriptors(
            requestDeviceAddress: requestDeviceAddress,
            requestByteCount: requestByteCount,
            responseDeviceAddress: responseDeviceAddress,
            responseCapacity: responseCapacity,
            pollLimit: pollLimit
        )
    }

    /// Submits allocator-owned buffers without copying a potentially large GPU
    /// command stream through the transport's 512-byte bootstrap scratch.
    mutating func submit(
        buffers: VirtIOQueueBufferPair,
        pollLimit: UInt64 = 5_000_000
    ) -> VirtIOMMIORequestResult {
        guard queueSize >= 2,
              pollLimit > 0,
              let queueMapping,
              VirtIOQueueBufferPair(
                  request: buffers.request,
                  requestByteCount: buffers.requestByteCount,
                  response: buffers.response,
                  responseCapacity: buffers.responseCapacity,
                  protectedQueueMapping: queueMapping
              ) != nil
        else {
            return .invalidRequest
        }
        return submitDescriptors(
            requestDeviceAddress: buffers.request.deviceAddress,
            requestByteCount: buffers.requestByteCount,
            responseDeviceAddress: buffers.response.deviceAddress,
            responseCapacity: buffers.responseCapacity,
            pollLimit: pollLimit
        )
    }

    private mutating func submitDescriptors(
        requestDeviceAddress: UInt64,
        requestByteCount: UInt32,
        responseDeviceAddress: UInt64,
        responseCapacity: UInt32,
        pollLimit: UInt64
    ) -> VirtIOMMIORequestResult {
        if read(Register.status) & Status.deviceNeedsReset != 0 {
            failDevice()
            return .deviceNeedsReset
        }

        writeDescriptor(
            index: 0,
            address: requestDeviceAddress,
            length: requestByteCount,
            flags: 1,
            next: 1
        )
        writeDescriptor(
            index: 1,
            address: responseDeviceAddress,
            length: responseCapacity,
            flags: 2,
            next: 0
        )

        let slot = UInt64(availableIndex % queueSize)
        PhysicalBytes.writeLE16(
            0,
            at: availableAddress + 4 + slot * 2
        )
        AArch64.synchronizeData()
        availableIndex &+= 1
        MMIO.store16(availableIndex, at: UInt(availableAddress + 2))
        AArch64.synchronizeData()
        write(0, Register.queueNotify)

        let expectedUsedIndex = usedIndex &+ 1
        var polls: UInt64 = 0
        while polls < pollLimit {
            if MMIO.load16(at: UInt(usedAddress + 2)) == expectedUsedIndex {
                AArch64.synchronizeData()
                break
            }
            if read(Register.status) & Status.deviceNeedsReset != 0 {
                failDevice()
                return .deviceNeedsReset
            }
            AArch64.spinHint()
            polls += 1
        }
        guard polls < pollLimit else {
            failDevice()
            return .timedOut
        }

        let usedSlot = UInt64(usedIndex % queueSize)
        let element = usedAddress + 4 + usedSlot * 8
        let descriptorID = PhysicalBytes.readLE32(at: element)
        let responseLength = PhysicalBytes.readLE32(at: element + 4)
        usedIndex = expectedUsedIndex
        let interrupts = read(Register.interruptStatus)
        if interrupts != 0 {
            write(interrupts, Register.interruptAcknowledge)
        }
        guard descriptorID == 0,
              responseLength >= 24,
              responseLength <= responseCapacity
        else {
            failDevice()
            return .malformedCompletion
        }
        return .completed(responseByteCount: responseLength)
    }

    mutating func failDevice() {
        let status = read(Register.status)
        write(status | Status.failed, Register.status)
    }

    private func writeDescriptor(
        index: UInt16,
        address: UInt64,
        length: UInt32,
        flags: UInt16,
        next: UInt16
    ) {
        let descriptor = descriptorAddress + UInt64(index) * 16
        PhysicalBytes.writeLE64(address, at: descriptor)
        PhysicalBytes.writeLE32(length, at: descriptor + 8)
        PhysicalBytes.writeLE16(flags, at: descriptor + 12)
        PhysicalBytes.writeLE16(next, at: descriptor + 14)
    }

    private func writeAddress(_ address: UInt64, low: UInt, high: UInt) {
        write(UInt32(truncatingIfNeeded: address), low)
        write(UInt32(truncatingIfNeeded: address >> 32), high)
    }

    private func readDeviceFeatures() -> UInt64 {
        write(0, Register.deviceFeaturesSelect)
        let low = UInt64(read(Register.deviceFeatures))
        write(1, Register.deviceFeaturesSelect)
        let high = UInt64(read(Register.deviceFeatures))
        return low | (high << 32)
    }

    private func read(_ offset: UInt) -> UInt32 {
        MMIO.load32(at: baseAddress + offset)
    }

    private func write(_ value: UInt32, _ offset: UInt) {
        MMIO.store32(value, at: baseAddress + offset)
    }

    private func highestPowerOfTwo(notGreaterThan value: UInt16) -> UInt16 {
        var result: UInt16 = 1
        while result <= value / 2 { result *= 2 }
        return result
    }
}
