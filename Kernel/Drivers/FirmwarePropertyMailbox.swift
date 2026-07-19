/// Register access for a bidirectional firmware mailbox. Implementations own
/// only volatile I/O; FIFO policy and property-message validation live here.
protocol FirmwareMailboxRegisterAccess {
    mutating func read32(at offset: UInt) -> UInt32
    mutating func write32(_ value: UInt32, at offset: UInt)
}

/// Cache ownership transitions for a non-coherent property buffer.
protocol FirmwareMailboxCacheMaintenance {
    mutating func clean(address: UInt64, byteCount: UInt64) -> Bool
    mutating func invalidate(address: UInt64, byteCount: UInt64) -> Bool
}

enum FirmwareMailboxRegisterLayout {
    static let minimumApertureLength: UInt64 = 0x40
    static let incomingRead: UInt = 0x00
    static let incomingStatus: UInt = 0x18
    static let outgoingWrite: UInt = 0x20
    static let outgoingStatus: UInt = 0x38

    static let full: UInt32 = 0x8000_0000
    static let empty: UInt32 = 0x4000_0000
}

enum FirmwareMailboxPowerDevice {
    static let usb: UInt32 = 3
}

enum FirmwareMailboxPowerResponseError: UInt8, Equatable {
    case bufferSize
    case messageResponseCode
    case tagIdentifier
    case tagBufferSize
    case tagResponseLength
    case deviceIdentifier
    case powerState
    case endTag
}

enum FirmwareMailboxPowerStateResult: Equatable {
    case completed
    case invalidPollLimit
    case cacheCleanFailed
    case writeTimedOut
    case responseTimedOut
    case cacheInvalidationFailed
    case malformedResponse(FirmwareMailboxPowerResponseError)
}

/// Bounded Raspberry Pi property-channel transaction engine. The register and
/// cache implementations are injected, so this policy has no board address,
/// interrupt, scheduler, or allocation dependency.
struct FirmwarePropertyMailbox<
    Registers: FirmwareMailboxRegisterAccess,
    Cache: FirmwareMailboxCacheMaintenance
> {
    static var propertyChannel: UInt32 { 8 }
    static var powerStateTag: UInt32 { 0x0002_8001 }
    static var messageByteCount: UInt64 { 32 }

    private var registers: Registers
    private var cache: Cache
    private let bufferCPUAddress: UInt64
    private let messageWord: UInt32

    init?(
        registers: Registers,
        cache: Cache,
        bufferCPUAddress: UInt64,
        bufferPhysicalAddress: UInt64,
        bufferByteCount: UInt64
    ) {
        guard bufferCPUAddress > 0,
              bufferCPUAddress & 0xf == 0,
              bufferCPUAddress <= UInt64(UInt.max),
              bufferPhysicalAddress > 0,
              bufferPhysicalAddress & 0xf == 0,
              bufferPhysicalAddress
                <= UInt64(UInt32.max & ~UInt32(0xf)),
              bufferByteCount >= Self.messageByteCount,
              bufferByteCount <= UInt64.max - bufferCPUAddress,
              UnsafeMutableRawPointer(
                  bitPattern: UInt(bufferCPUAddress)
              ) != nil
        else {
            return nil
        }
        self.registers = registers
        self.cache = cache
        self.bufferCPUAddress = bufferCPUAddress
        messageWord = UInt32(bufferPhysicalAddress) | Self.propertyChannel
    }

    mutating func setPowerState(
        deviceID: UInt32,
        poweredOn: Bool,
        waitUntilStable: Bool,
        maximumPollCount: Int
    ) -> FirmwareMailboxPowerStateResult {
        guard maximumPollCount > 0 else { return .invalidPollLimit }
        writePowerStateRequest(
            deviceID: deviceID,
            poweredOn: poweredOn,
            waitUntilStable: waitUntilStable
        )
        guard cache.clean(
                  address: bufferCPUAddress,
                  byteCount: Self.messageByteCount
              )
        else {
            return .cacheCleanFailed
        }

        var writePoll = 0
        while writePoll < maximumPollCount {
            if registers.read32(
                at: FirmwareMailboxRegisterLayout.outgoingStatus
            ) & FirmwareMailboxRegisterLayout.full == 0 {
                registers.write32(
                    messageWord,
                    at: FirmwareMailboxRegisterLayout.outgoingWrite
                )
                break
            }
            writePoll += 1
        }
        guard writePoll < maximumPollCount else { return .writeTimedOut }

        var readPoll = 0
        var receivedExpectedResponse = false
        while readPoll < maximumPollCount {
            if registers.read32(
                at: FirmwareMailboxRegisterLayout.incomingStatus
            ) & FirmwareMailboxRegisterLayout.empty != 0 {
                readPoll += 1
                continue
            }
            let response = registers.read32(
                at: FirmwareMailboxRegisterLayout.incomingRead
            )
            readPoll += 1
            if response == messageWord {
                receivedExpectedResponse = true
                break
            }
        }
        guard receivedExpectedResponse else { return .responseTimedOut }
        guard cache.invalidate(
                  address: bufferCPUAddress,
                  byteCount: Self.messageByteCount
              )
        else {
            return .cacheInvalidationFailed
        }
        if let error = validatePowerStateResponse(
            deviceID: deviceID,
            poweredOn: poweredOn
        ) {
            return .malformedResponse(error)
        }
        return .completed
    }

    private func writePowerStateRequest(
        deviceID: UInt32,
        poweredOn: Bool,
        waitUntilStable: Bool
    ) {
        PhysicalBytes.writeLE32(
            UInt32(Self.messageByteCount),
            at: bufferCPUAddress
        )
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 4)
        PhysicalBytes.writeLE32(Self.powerStateTag, at: bufferCPUAddress + 8)
        PhysicalBytes.writeLE32(8, at: bufferCPUAddress + 12)
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 16)
        PhysicalBytes.writeLE32(deviceID, at: bufferCPUAddress + 20)
        var state: UInt32 = poweredOn ? 1 : 0
        if waitUntilStable { state |= 2 }
        PhysicalBytes.writeLE32(state, at: bufferCPUAddress + 24)
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 28)
    }

    private func validatePowerStateResponse(
        deviceID: UInt32,
        poweredOn: Bool
    ) -> FirmwareMailboxPowerResponseError? {
        guard PhysicalBytes.readLE32(at: bufferCPUAddress)
                == UInt32(Self.messageByteCount)
        else {
            return .bufferSize
        }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 4)
                == 0x8000_0000
        else {
            return .messageResponseCode
        }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 8)
                == Self.powerStateTag
        else {
            return .tagIdentifier
        }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 12) == 8 else {
            return .tagBufferSize
        }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 16)
                == 0x8000_0008
        else {
            return .tagResponseLength
        }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 20) == deviceID else {
            return .deviceIdentifier
        }
        let returnedState = PhysicalBytes.readLE32(at: bufferCPUAddress + 24)
        let requestedState: UInt32 = poweredOn ? 1 : 0
        guard returnedState == requestedState else { return .powerState }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 28) == 0 else {
            return .endTag
        }
        return nil
    }
}
