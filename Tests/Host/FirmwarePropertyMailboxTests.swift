private enum MailboxResponseMutation {
    case none
    case bufferSize
    case messageResponseCode
    case tagIdentifier
    case tagBufferSize
    case tagResponseLength
    case deviceIdentifier
    case powerStateReservedBits
    case endTag
}

private final class MailboxEventTrace {
    var events: [UInt8] = []
}

private final class MailboxRegisterBank {
    var outgoingStatuses: [UInt32] = [0]
    var incomingStatuses: [UInt32] = [0]
    var incomingMessages: [UInt32] = []
    var responseMutation = MailboxResponseMutation.none
    var responsePowerState: UInt32 = 1
    var bufferCPUAddress: UInt64 = 0
    var outgoingStatusIndex = 0
    var incomingStatusIndex = 0
    var incomingMessageIndex = 0
    var writes: [(UInt, UInt32)] = []
    var requestWords: [UInt32] = []
    var trace: MailboxEventTrace?

    func status(_ values: [UInt32], index: inout Int) -> UInt32 {
        guard !values.isEmpty else { return 0 }
        let selected = index < values.count ? index : values.count - 1
        index += 1
        return values[selected]
    }

    func respond() {
        requestWords.removeAll(keepingCapacity: true)
        let byteCount = PhysicalBytes.readLE32(at: bufferCPUAddress)
        let wordCount = Int(byteCount / 4)
        var index = 0
        while index < wordCount {
            requestWords.append(
                PhysicalBytes.readLE32(
                    at: bufferCPUAddress + UInt64(index * 4)
                )
            )
            index += 1
        }
        let tag = PhysicalBytes.readLE32(at: bufferCPUAddress + 8)
        PhysicalBytes.writeLE32(0x8000_0000, at: bufferCPUAddress + 4)
        if tag == 0x0002_8001 {
            PhysicalBytes.writeLE32(0x8000_0008, at: bufferCPUAddress + 16)
            PhysicalBytes.writeLE32(
                responsePowerState,
                at: bufferCPUAddress + 24
            )
        } else if tag == 0x0003_8064 {
            PhysicalBytes.writeLE32(0x8000_0004, at: bufferCPUAddress + 16)
        } else if tag == 0x0003_0048 {
            PhysicalBytes.writeLE32(0x8000_0000, at: bufferCPUAddress + 16)
        }
        switch responseMutation {
        case .none:
            break
        case .bufferSize:
            PhysicalBytes.writeLE32(28, at: bufferCPUAddress)
        case .messageResponseCode:
            PhysicalBytes.writeLE32(0x8000_0001, at: bufferCPUAddress + 4)
        case .tagIdentifier:
            PhysicalBytes.writeLE32(0x0002_0001, at: bufferCPUAddress + 8)
        case .tagBufferSize:
            PhysicalBytes.writeLE32(4, at: bufferCPUAddress + 12)
        case .tagResponseLength:
            PhysicalBytes.writeLE32(0x8000_0004, at: bufferCPUAddress + 16)
        case .deviceIdentifier:
            PhysicalBytes.writeLE32(4, at: bufferCPUAddress + 20)
        case .powerStateReservedBits:
            PhysicalBytes.writeLE32(4, at: bufferCPUAddress + 24)
        case .endTag:
            PhysicalBytes.writeLE32(1, at: bufferCPUAddress + 28)
        }
    }
}

private struct TestMailboxRegisters: FirmwareMailboxRegisterAccess {
    let bank: MailboxRegisterBank

    mutating func read32(at offset: UInt) -> UInt32 {
        switch offset {
        case FirmwareMailboxRegisterLayout.outgoingStatus:
            return bank.status(
                bank.outgoingStatuses,
                index: &bank.outgoingStatusIndex
            )
        case FirmwareMailboxRegisterLayout.incomingStatus:
            return bank.status(
                bank.incomingStatuses,
                index: &bank.incomingStatusIndex
            )
        case FirmwareMailboxRegisterLayout.incomingRead:
            guard bank.incomingMessageIndex < bank.incomingMessages.count else {
                return 0
            }
            let result = bank.incomingMessages[bank.incomingMessageIndex]
            bank.incomingMessageIndex += 1
            bank.trace?.events.append(2)
            return result
        default:
            return 0
        }
    }

    mutating func write32(_ value: UInt32, at offset: UInt) {
        bank.writes.append((offset, value))
        if offset == FirmwareMailboxRegisterLayout.outgoingWrite {
            bank.trace?.events.append(1)
            bank.respond()
        }
    }
}

private final class TestMailboxCache: FirmwareMailboxCacheMaintenance {
    var cleanResult = true
    var invalidateResult = true
    var cleanCalls: [(UInt64, UInt64)] = []
    var invalidateCalls: [(UInt64, UInt64)] = []
    let trace: MailboxEventTrace?

    init(trace: MailboxEventTrace? = nil) {
        self.trace = trace
    }

    func clean(address: UInt64, byteCount: UInt64) -> Bool {
        trace?.events.append(0)
        cleanCalls.append((address, byteCount))
        return cleanResult
    }

    func invalidate(address: UInt64, byteCount: UInt64) -> Bool {
        trace?.events.append(3)
        invalidateCalls.append((address, byteCount))
        return invalidateResult
    }
}

private struct TestTryBootFirmware: RaspberryPiTryBootFirmwareInterface {
    var armResult: FirmwareMailboxRebootResult
    var notificationResult: FirmwareMailboxRebootResult
    var armCallCount = 0
    var notificationCallCount = 0

    mutating func setRebootFlags(
        _ flags: UInt32,
        maximumPollCount: Int
    ) -> FirmwareMailboxRebootResult {
        guard flags == 1, maximumPollCount > 0 else { return .invalidFlags }
        armCallCount += 1
        return armResult
    }

    mutating func notifyReboot(
        maximumPollCount: Int
    ) -> FirmwareMailboxRebootResult {
        guard maximumPollCount > 0 else { return .invalidPollLimit }
        notificationCallCount += 1
        return notificationResult
    }
}

@main
struct FirmwarePropertyMailboxTests {
    private static let bufferPhysicalAddress: UInt64 = 0x0010_0000
    private static let messageWord = UInt32(bufferPhysicalAddress) | 8

    static func main() {
        validatesPowerOnRequestAndResponse()
        validatesTryBootRebootRequestsAndResponses()
        enforcesTryBootPreparationOrdering()
        pollsFullAndEmptyFIFOsWithinBounds()
        skipsUnrelatedMailboxMessages()
        classifiesPowerStateResponseSemantics()
        classifiesPi5USBPowerHandoff()
        protectsSharedScratchAfterAmbiguousPowerTransactions()
        rejectsMalformedResponses()
        reportsBoundedTimeouts()
        validatesBuffersPollLimitsAndCacheOwnership()
        print("firmware property mailbox: 11 groups passed")
    }

    private static func protectsSharedScratchAfterAmbiguousPowerTransactions() {
        expect(
            RaspberryPiFirmwareMailboxScratchPolicy.disposition(
                after: .responseTimedOut
            ) == .poisoned,
            "firmware-owned timeout buffer was declared reusable"
        )
        expect(
            RaspberryPiFirmwareMailboxScratchPolicy.disposition(
                after: .cacheInvalidationFailed
            ) == .poisoned,
            "incoherent response buffer was declared reusable"
        )
        expect(
            RaspberryPiFirmwareMailboxScratchPolicy.disposition(
                after: .writeTimedOut
            ) == .reusable,
            "pre-write timeout permanently consumed mailbox scratch"
        )
        expect(
            RaspberryPiFirmwareMailboxScratchPolicy.disposition(
                after: .malformedResponse(.endTag)
            ) == .reusable,
            "completed malformed response retained firmware ownership"
        )
    }

    private static func enforcesTryBootPreparationOrdering() {
        var rejected = TestTryBootFirmware(
            armResult: .writeTimedOut,
            notificationResult: .completed
        )
        expect(
            RaspberryPiTryBootFirmwareCoordinator.prepareForReset(
                firmware: &rejected,
                maximumPollCount: 10
            ) == .armRejected(.writeTimedOut),
            "pre-send SET_REBOOT_FLAGS failure did not reject trial reset"
        )
        expect(
            rejected.armCallCount == 1
                && rejected.notificationCallCount == 0,
            "NOTIFY_REBOOT ran after tryboot arming failed"
        )

        var indeterminate = TestTryBootFirmware(
            armResult: .responseTimedOut,
            notificationResult: .completed
        )
        expect(
            RaspberryPiTryBootFirmwareCoordinator.prepareForReset(
                firmware: &indeterminate,
                maximumPollCount: 10
            ) == .readyToReset(
                arm: .responseTimedOut,
                notification: nil
            ),
            "post-send tryboot timeout was treated as safely unarmed"
        )
        expect(
            indeterminate.armCallCount == 1
                && indeterminate.notificationCallCount == 0,
            "indeterminate request reused the shared mailbox buffer"
        )

        var notifyFailed = TestTryBootFirmware(
            armResult: .completed,
            notificationResult: .cacheInvalidationFailed
        )
        expect(
            RaspberryPiTryBootFirmwareCoordinator.prepareForReset(
                firmware: &notifyFailed,
                maximumPollCount: 10
            ) == .readyToReset(
                arm: .completed,
                notification: .cacheInvalidationFailed
            ),
            "armed tryboot did not remain reset-bound after notify failure"
        )
        expect(
            notifyFailed.armCallCount == 1
                && notifyFailed.notificationCallCount == 1,
            "tryboot preparation calls were not strictly ordered"
        )
    }

    private static func validatesTryBootRebootRequestsAndResponses() {
        withAlignedBuffer { address in
            expect(
                RaspberryPi5DMAScratchLayout.firmwareMailboxAddress(
                    pageBaseAddress: 0x20_0000
                ) == 0x20_0fc0,
                "Pi DMA scratch mailbox tail is not 64-byte aligned"
            )
            expect(
                RaspberryPi5DMAScratchLayout.gadgetByteCount
                    + RaspberryPi5DMAScratchLayout.firmwareMailboxByteCount
                    == RaspberryPi5DMAScratchLayout.pageByteCount,
                "Pi DMA scratch ownership leaves a gap or overlap"
            )
            let flagsBank = MailboxRegisterBank()
            flagsBank.bufferCPUAddress = address
            flagsBank.incomingMessages = [messageWord]
            let flagsCache = TestMailboxCache()
            var flagsMailbox = requireMailbox(
                address: address,
                bank: flagsBank,
                cache: flagsCache
            )
            expect(
                flagsMailbox.setRebootFlags(
                    1,
                    maximumPollCount: 1
                ) == .completed,
                "SET_REBOOT_FLAGS tryboot transaction failed"
            )
            expect(
                flagsBank.requestWords == [
                    28, 0, 0x0003_8064, 4, 0, 1, 0,
                ],
                "SET_REBOOT_FLAGS request encoding mismatch"
            )
            expect(
                flagsCache.cleanCalls.count == 1
                    && flagsCache.cleanCalls[0].0 == address
                    && flagsCache.cleanCalls[0].1 == 28
                    && flagsCache.invalidateCalls.count == 1
                    && flagsCache.invalidateCalls[0].0 == address
                    && flagsCache.invalidateCalls[0].1 == 28,
                "reboot-flags cache ownership used the wrong extent"
            )

            let notifyBank = MailboxRegisterBank()
            notifyBank.bufferCPUAddress = address
            notifyBank.incomingMessages = [messageWord]
            let notifyCache = TestMailboxCache()
            var notifyMailbox = requireMailbox(
                address: address,
                bank: notifyBank,
                cache: notifyCache
            )
            expect(
                notifyMailbox.notifyReboot(maximumPollCount: 1)
                    == .completed,
                "NOTIFY_REBOOT transaction failed"
            )
            expect(
                notifyBank.requestWords == [
                    24, 0, 0x0003_0048, 0, 0, 0,
                ],
                "NOTIFY_REBOOT request encoding mismatch"
            )
            expect(
                notifyCache.cleanCalls.count == 1
                    && notifyCache.cleanCalls[0].0 == address
                    && notifyCache.cleanCalls[0].1 == 24
                    && notifyCache.invalidateCalls.count == 1
                    && notifyCache.invalidateCalls[0].0 == address
                    && notifyCache.invalidateCalls[0].1 == 24,
                "reboot-notify cache ownership used the wrong extent"
            )

            let rejectedBank = MailboxRegisterBank()
            rejectedBank.bufferCPUAddress = address
            let rejectedCache = TestMailboxCache()
            var rejectedMailbox = requireMailbox(
                address: address,
                bank: rejectedBank,
                cache: rejectedCache
            )
            expect(
                rejectedMailbox.setRebootFlags(
                    2,
                    maximumPollCount: 1
                ) == .invalidFlags,
                "unknown firmware reboot flags were accepted"
            )
            expect(
                rejectedBank.writes.isEmpty
                    && rejectedCache.cleanCalls.isEmpty,
                "invalid reboot flags reached firmware"
            )
        }
    }

    private static func validatesPowerOnRequestAndResponse() {
        withAlignedBuffer { address in
            let bank = MailboxRegisterBank()
            bank.bufferCPUAddress = address
            bank.incomingMessages = [messageWord]
            let trace = MailboxEventTrace()
            bank.trace = trace
            let cache = TestMailboxCache(trace: trace)
            var mailbox = requireMailbox(address: address, bank: bank, cache: cache)
            expect(
                mailbox.setPowerState(
                    deviceID: FirmwareMailboxPowerDevice.usb,
                    poweredOn: true,
                    waitUntilStable: true,
                    maximumPollCount: 4
                ) == .completed,
                "valid USB power transaction failed"
            )
            expect(
                bank.requestWords == [
                    32, 0, 0x0002_8001, 8, 0, 3, 3, 0,
                ],
                "SET_POWER_STATE request encoding mismatch"
            )
            expect(
                bank.writes.count == 1
                    && bank.writes[0].0
                        == FirmwareMailboxRegisterLayout.outgoingWrite
                    && bank.writes[0].1 == messageWord,
                "property channel mailbox word mismatch"
            )
            expect(
                cache.cleanCalls.count == 1
                    && cache.cleanCalls[0].0 == address
                    && cache.cleanCalls[0].1 == 32
                    && cache.invalidateCalls.count == 1
                    && cache.invalidateCalls[0].0 == address
                    && cache.invalidateCalls[0].1 == 32,
                "property-buffer cache ownership mismatch"
            )
            expect(
                trace.events == [0, 1, 2, 3],
                "scratch was not cleaned before handoff and invalidated only "
                    + "after the matched MMIO response"
            )
        }
    }

    private static func pollsFullAndEmptyFIFOsWithinBounds() {
        withAlignedBuffer { address in
            let bank = MailboxRegisterBank()
            bank.bufferCPUAddress = address
            bank.outgoingStatuses = [
                FirmwareMailboxRegisterLayout.full,
                FirmwareMailboxRegisterLayout.full,
                0,
            ]
            bank.incomingStatuses = [
                FirmwareMailboxRegisterLayout.empty,
                FirmwareMailboxRegisterLayout.empty,
                0,
            ]
            bank.incomingMessages = [messageWord]
            let cache = TestMailboxCache()
            var mailbox = requireMailbox(address: address, bank: bank, cache: cache)
            expect(
                mailbox.setPowerState(
                    deviceID: 3,
                    poweredOn: true,
                    waitUntilStable: true,
                    maximumPollCount: 3
                ) == .completed,
                "bounded full/empty polling did not complete"
            )
            expect(
                bank.outgoingStatusIndex == 3
                    && bank.incomingStatusIndex == 3,
                "mailbox status polling count mismatch"
            )
        }
    }

    private static func skipsUnrelatedMailboxMessages() {
        withAlignedBuffer { address in
            let bank = MailboxRegisterBank()
            bank.bufferCPUAddress = address
            bank.incomingStatuses = [0, 0, 0]
            bank.incomingMessages = [
                UInt32(bufferPhysicalAddress) | 7,
                0x0020_0008,
                messageWord,
            ]
            let cache = TestMailboxCache()
            var mailbox = requireMailbox(address: address, bank: bank, cache: cache)
            expect(
                mailbox.setPowerState(
                    deviceID: 3,
                    poweredOn: true,
                    waitUntilStable: true,
                    maximumPollCount: 3
                ) == .completed,
                "unrelated channel/address response blocked the transaction"
            )
            expect(
                bank.incomingMessageIndex == 3,
                "unrelated messages were not drained exactly once"
            )
        }
    }

    private static func classifiesPowerStateResponseSemantics() {
        expectPowerStateResult(
            returnedState: 2,
            poweredOn: true,
            expected: .deviceUnavailable,
            message: "unavailable powered-off device was not classified"
        )
        expectPowerStateResult(
            returnedState: 3,
            poweredOn: true,
            expected: .deviceUnavailable,
            message: "unavailable powered-on device was not classified"
        )
        expectPowerStateResult(
            returnedState: 2,
            poweredOn: false,
            expected: .deviceUnavailable,
            message: "unavailable power-off device was not classified"
        )
        expectPowerStateResult(
            returnedState: 0,
            poweredOn: true,
            expected: .stateMismatch,
            message: "powered-off response did not report a state mismatch"
        )
        expectPowerStateResult(
            returnedState: 1,
            poweredOn: false,
            expected: .stateMismatch,
            message: "powered-on response did not report a state mismatch"
        )
        expectPowerStateResult(
            returnedState: 0,
            poweredOn: false,
            expected: .completed,
            message: "valid power-off response failed"
        )
    }

    private static func classifiesPi5USBPowerHandoff() {
        expect(
            RaspberryPi5USBPowerPolicy.disposition(for: .completed)
                == .managed,
            "completed firmware power handoff was not managed"
        )
        expect(
            RaspberryPi5USBPowerPolicy.disposition(for: .deviceUnavailable)
                == .unmanaged,
            "missing legacy HCD power domain did not transfer to DWC2"
        )
        expect(
            RaspberryPi5USBPowerPolicy.disposition(for: .stateMismatch)
                == .unmanaged,
            "powered-off legacy HCD response did not transfer to Pi 5 DWC2"
        )
        let rejected: [FirmwareMailboxPowerStateResult] = [
            .invalidPollLimit,
            .cacheCleanFailed,
            .writeTimedOut,
            .responseTimedOut,
            .cacheInvalidationFailed,
            .malformedResponse(.powerStateReservedBits),
        ]
        for result in rejected {
            expect(
                RaspberryPi5USBPowerPolicy.disposition(for: result)
                    == .reject,
                "unsafe firmware power result was accepted"
            )
        }
    }

    private static func rejectsMalformedResponses() {
        let fixtures: [(MailboxResponseMutation, FirmwareMailboxPowerResponseError)] = [
            (.bufferSize, .bufferSize),
            (.messageResponseCode, .messageResponseCode),
            (.tagIdentifier, .tagIdentifier),
            (.tagBufferSize, .tagBufferSize),
            (.tagResponseLength, .tagResponseLength),
            (.deviceIdentifier, .deviceIdentifier),
            (.powerStateReservedBits, .powerStateReservedBits),
            (.endTag, .endTag),
        ]
        for (mutation, expectedError) in fixtures {
            withAlignedBuffer { address in
                let bank = MailboxRegisterBank()
                bank.bufferCPUAddress = address
                bank.responseMutation = mutation
                bank.incomingMessages = [messageWord]
                let cache = TestMailboxCache()
                var mailbox = requireMailbox(
                    address: address,
                    bank: bank,
                    cache: cache
                )
                expect(
                    mailbox.setPowerState(
                        deviceID: 3,
                        poweredOn: true,
                        waitUntilStable: true,
                        maximumPollCount: 1
                    ) == .malformedResponse(expectedError),
                    "malformed response field was accepted"
                )
            }
        }
    }

    private static func reportsBoundedTimeouts() {
        withAlignedBuffer { address in
            let fullBank = MailboxRegisterBank()
            fullBank.bufferCPUAddress = address
            fullBank.outgoingStatuses = [FirmwareMailboxRegisterLayout.full]
            let fullCache = TestMailboxCache()
            var fullMailbox = requireMailbox(
                address: address,
                bank: fullBank,
                cache: fullCache
            )
            expect(
                fullMailbox.setPowerState(
                    deviceID: 3,
                    poweredOn: true,
                    waitUntilStable: true,
                    maximumPollCount: 4
                ) == .writeTimedOut,
                "full outgoing FIFO did not time out"
            )
            expect(fullBank.writes.isEmpty, "write occurred while FIFO was full")
            expect(
                fullCache.invalidateCalls.isEmpty,
                "timed-out request invalidated unreturned scratch"
            )

            let emptyBank = MailboxRegisterBank()
            emptyBank.bufferCPUAddress = address
            emptyBank.incomingStatuses = [FirmwareMailboxRegisterLayout.empty]
            let emptyCache = TestMailboxCache()
            var emptyMailbox = requireMailbox(
                address: address,
                bank: emptyBank,
                cache: emptyCache
            )
            expect(
                emptyMailbox.setPowerState(
                    deviceID: 3,
                    poweredOn: true,
                    waitUntilStable: true,
                    maximumPollCount: 4
                ) == .responseTimedOut,
                "empty incoming FIFO did not time out"
            )
            expect(
                emptyBank.incomingStatusIndex == 4,
                "response timeout exceeded its poll bound"
            )
            expect(
                emptyCache.invalidateCalls.isEmpty,
                "empty response FIFO invalidated unreturned scratch"
            )
        }
    }

    private static func validatesBuffersPollLimitsAndCacheOwnership() {
        withAlignedBuffer { address in
            let bank = MailboxRegisterBank()
            bank.bufferCPUAddress = address
            bank.incomingMessages = [messageWord]
            let cache = TestMailboxCache()
            expect(
                FirmwarePropertyMailbox(
                    registers: TestMailboxRegisters(bank: bank),
                    cache: cache,
                    bufferCPUAddress: address + 1,
                    bufferPhysicalAddress: bufferPhysicalAddress,
                    bufferByteCount: 32
                ) == nil,
                "unaligned CPU buffer was accepted"
            )
            expect(
                FirmwarePropertyMailbox(
                    registers: TestMailboxRegisters(bank: bank),
                    cache: cache,
                    bufferCPUAddress: address,
                    bufferPhysicalAddress: 0x1_0000_0000,
                    bufferByteCount: 32
                ) == nil,
                "unencodable physical buffer address was accepted"
            )
            expect(
                FirmwarePropertyMailbox(
                    registers: TestMailboxRegisters(bank: bank),
                    cache: cache,
                    bufferCPUAddress: address,
                    bufferPhysicalAddress: bufferPhysicalAddress,
                    bufferByteCount: 31
                ) == nil,
                "short property buffer was accepted"
            )

            var invalidPoll = requireMailbox(
                address: address,
                bank: bank,
                cache: cache
            )
            expect(
                invalidPoll.setPowerState(
                    deviceID: 3,
                    poweredOn: true,
                    waitUntilStable: true,
                    maximumPollCount: 0
                ) == .invalidPollLimit,
                "invalid poll limit was accepted"
            )

            let cleanFailure = TestMailboxCache()
            cleanFailure.cleanResult = false
            var cleanMailbox = requireMailbox(
                address: address,
                bank: bank,
                cache: cleanFailure
            )
            expect(
                cleanMailbox.setPowerState(
                    deviceID: 3,
                    poweredOn: true,
                    waitUntilStable: true,
                    maximumPollCount: 1
                ) == .cacheCleanFailed,
                "cache-clean failure was ignored"
            )

            let invalidationBank = MailboxRegisterBank()
            invalidationBank.bufferCPUAddress = address
            invalidationBank.incomingMessages = [messageWord]
            let invalidationFailure = TestMailboxCache()
            invalidationFailure.invalidateResult = false
            var invalidationMailbox = requireMailbox(
                address: address,
                bank: invalidationBank,
                cache: invalidationFailure
            )
            expect(
                invalidationMailbox.setPowerState(
                    deviceID: 3,
                    poweredOn: true,
                    waitUntilStable: true,
                    maximumPollCount: 1
                ) == .cacheInvalidationFailed,
                "cache-invalidation failure was ignored"
            )
        }
    }

    private static func requireMailbox(
        address: UInt64,
        bank: MailboxRegisterBank,
        cache: TestMailboxCache
    ) -> FirmwarePropertyMailbox<TestMailboxRegisters, TestMailboxCache> {
        guard let mailbox = FirmwarePropertyMailbox(
                  registers: TestMailboxRegisters(bank: bank),
                  cache: cache,
                  bufferCPUAddress: address,
                  bufferPhysicalAddress: bufferPhysicalAddress,
                  bufferByteCount: 64
              )
        else {
            fatalError("valid mailbox fixture was rejected")
        }
        return mailbox
    }

    private static func expectPowerStateResult(
        returnedState: UInt32,
        poweredOn: Bool,
        expected: FirmwareMailboxPowerStateResult,
        message: String
    ) {
        withAlignedBuffer { address in
            let bank = MailboxRegisterBank()
            bank.bufferCPUAddress = address
            bank.incomingMessages = [messageWord]
            bank.responsePowerState = returnedState
            let cache = TestMailboxCache()
            var mailbox = requireMailbox(
                address: address,
                bank: bank,
                cache: cache
            )
            bank.responseMutation = .none
            expect(
                mailbox.setPowerState(
                    deviceID: 3,
                    poweredOn: poweredOn,
                    waitUntilStable: true,
                    maximumPollCount: 1
                ) == expected,
                message
            )
        }
    }

    private static func withAlignedBuffer(_ body: (UInt64) -> Void) {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.withUnsafeMutableBytes { storage in
            guard let base = storage.baseAddress else {
                fatalError("mailbox test buffer is missing")
            }
            let address = (UInt(bitPattern: base) + 15) & ~UInt(15)
            body(UInt64(address))
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
