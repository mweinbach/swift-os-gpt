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
    case powerStateReservedBits
    case endTag
}

enum FirmwareMailboxPowerStateResult: Equatable {
    case completed
    case deviceUnavailable
    case stateMismatch
    case invalidPollLimit
    case cacheCleanFailed
    case writeTimedOut
    case responseTimedOut
    case cacheInvalidationFailed
    case malformedResponse(FirmwareMailboxPowerResponseError)
}

enum FirmwareMailboxRebootResponseError: UInt8, Equatable {
    case bufferSize
    case messageResponseCode
    case tagIdentifier
    case tagBufferSize
    case tagResponseLength
    case endTag
}

enum FirmwareMailboxRebootResult: Equatable {
    case completed
    case invalidFlags
    case invalidPollLimit
    case cacheCleanFailed
    case writeTimedOut
    case responseTimedOut
    case cacheInvalidationFailed
    case malformedResponse(FirmwareMailboxRebootResponseError)
}

private enum FirmwareMailboxTransactionResult {
    case completed
    case invalidPollLimit
    case cacheCleanFailed
    case writeTimedOut
    case responseTimedOut
    case cacheInvalidationFailed
}

private enum FirmwareMailboxPowerResponseStateBits {
    static let poweredOn: UInt32 = 1 << 0
    static let deviceUnavailable: UInt32 = 1 << 1
    static let knownMask = poweredOn | deviceUnavailable
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
    static var setRebootFlagsTag: UInt32 { 0x0003_8064 }
    static var notifyRebootTag: UInt32 { 0x0003_0048 }

    private static var rebootFlagsMessageByteCount: UInt64 { 28 }
    private static var notifyRebootMessageByteCount: UInt64 { 24 }

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
        writePowerStateRequest(
            deviceID: deviceID,
            poweredOn: poweredOn,
            waitUntilStable: waitUntilStable
        )
        switch performTransaction(
            byteCount: Self.messageByteCount,
            maximumPollCount: maximumPollCount
        ) {
        case .completed: break
        case .invalidPollLimit: return .invalidPollLimit
        case .cacheCleanFailed: return .cacheCleanFailed
        case .writeTimedOut: return .writeTimedOut
        case .responseTimedOut: return .responseTimedOut
        case .cacheInvalidationFailed: return .cacheInvalidationFailed
        }
        if let error = validatePowerStateResponse(deviceID: deviceID) {
            return .malformedResponse(error)
        }
        let returnedState = PhysicalBytes.readLE32(
            at: bufferCPUAddress + 24
        )
        guard returnedState
                & ~FirmwareMailboxPowerResponseStateBits.knownMask == 0
        else {
            return .malformedResponse(.powerStateReservedBits)
        }
        if returnedState
            & FirmwareMailboxPowerResponseStateBits.deviceUnavailable != 0 {
            return .deviceUnavailable
        }
        let returnedPoweredOn = returnedState
            & FirmwareMailboxPowerResponseStateBits.poweredOn != 0
        guard returnedPoweredOn == poweredOn else { return .stateMismatch }
        return .completed
    }

    /// Sets or clears Raspberry Pi firmware's one-shot reboot flag. Setting
    /// bit zero arms tryboot. Failure to arm rejects the trial; after arming,
    /// callers must reset immediately even if NOTIFY_REBOOT itself fails so a
    /// one-shot flag cannot leak into an unrelated later reset.
    mutating func setRebootFlags(
        _ flags: UInt32,
        maximumPollCount: Int
    ) -> FirmwareMailboxRebootResult {
        guard flags & ~UInt32(1) == 0 else { return .invalidFlags }
        writeRebootFlagsRequest(flags)
        switch performTransaction(
            byteCount: Self.rebootFlagsMessageByteCount,
            maximumPollCount: maximumPollCount
        ) {
        case .completed: break
        case .invalidPollLimit: return .invalidPollLimit
        case .cacheCleanFailed: return .cacheCleanFailed
        case .writeTimedOut: return .writeTimedOut
        case .responseTimedOut: return .responseTimedOut
        case .cacheInvalidationFailed: return .cacheInvalidationFailed
        }
        if let error = validateRebootFlagsResponse() {
            return .malformedResponse(error)
        }
        return .completed
    }

    /// Notifies firmware immediately before a watchdog reset. This remains a
    /// separate transaction so policy can distinguish notification failure
    /// after the one-shot flag has already become firmware-owned.
    mutating func notifyReboot(
        maximumPollCount: Int
    ) -> FirmwareMailboxRebootResult {
        writeNotifyRebootRequest()
        switch performTransaction(
            byteCount: Self.notifyRebootMessageByteCount,
            maximumPollCount: maximumPollCount
        ) {
        case .completed: break
        case .invalidPollLimit: return .invalidPollLimit
        case .cacheCleanFailed: return .cacheCleanFailed
        case .writeTimedOut: return .writeTimedOut
        case .responseTimedOut: return .responseTimedOut
        case .cacheInvalidationFailed: return .cacheInvalidationFailed
        }
        if let error = validateNotifyRebootResponse() {
            return .malformedResponse(error)
        }
        return .completed
    }

    private mutating func performTransaction(
        byteCount: UInt64,
        maximumPollCount: Int
    ) -> FirmwareMailboxTransactionResult {
        guard maximumPollCount > 0 else { return .invalidPollLimit }
        guard cache.clean(address: bufferCPUAddress, byteCount: byteCount) else {
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
                guard cache.invalidate(
                          address: bufferCPUAddress,
                          byteCount: byteCount
                      )
                else { return .cacheInvalidationFailed }
                return .completed
            }
        }
        return .responseTimedOut
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

    private func writeRebootFlagsRequest(_ flags: UInt32) {
        PhysicalBytes.writeLE32(
            UInt32(Self.rebootFlagsMessageByteCount),
            at: bufferCPUAddress
        )
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 4)
        PhysicalBytes.writeLE32(
            Self.setRebootFlagsTag,
            at: bufferCPUAddress + 8
        )
        PhysicalBytes.writeLE32(4, at: bufferCPUAddress + 12)
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 16)
        PhysicalBytes.writeLE32(flags, at: bufferCPUAddress + 20)
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 24)
    }

    private func writeNotifyRebootRequest() {
        PhysicalBytes.writeLE32(
            UInt32(Self.notifyRebootMessageByteCount),
            at: bufferCPUAddress
        )
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 4)
        PhysicalBytes.writeLE32(
            Self.notifyRebootTag,
            at: bufferCPUAddress + 8
        )
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 12)
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 16)
        PhysicalBytes.writeLE32(0, at: bufferCPUAddress + 20)
    }

    private func validatePowerStateResponse(
        deviceID: UInt32
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
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 28) == 0 else {
            return .endTag
        }
        return nil
    }

    private func validateRebootFlagsResponse()
        -> FirmwareMailboxRebootResponseError? {
        guard PhysicalBytes.readLE32(at: bufferCPUAddress)
                == UInt32(Self.rebootFlagsMessageByteCount)
        else { return .bufferSize }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 4)
                == 0x8000_0000
        else { return .messageResponseCode }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 8)
                == Self.setRebootFlagsTag
        else { return .tagIdentifier }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 12) == 4 else {
            return .tagBufferSize
        }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 16)
                == 0x8000_0004
        else { return .tagResponseLength }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 24) == 0 else {
            return .endTag
        }
        return nil
    }

    private func validateNotifyRebootResponse()
        -> FirmwareMailboxRebootResponseError? {
        guard PhysicalBytes.readLE32(at: bufferCPUAddress)
                == UInt32(Self.notifyRebootMessageByteCount)
        else { return .bufferSize }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 4)
                == 0x8000_0000
        else { return .messageResponseCode }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 8)
                == Self.notifyRebootTag
        else { return .tagIdentifier }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 12) == 0 else {
            return .tagBufferSize
        }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 16)
                == 0x8000_0000
        else { return .tagResponseLength }
        guard PhysicalBytes.readLE32(at: bufferCPUAddress + 20) == 0 else {
            return .endTag
        }
        return nil
    }
}
