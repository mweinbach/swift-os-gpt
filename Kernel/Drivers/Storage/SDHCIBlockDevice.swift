/// Register and time boundary for a standard SD Host Controller. Implementors
/// expose host-relative offsets; the transport deliberately has no knowledge
/// of a board's physical address map, GPIOs, clocks, or firmware handoff.
protocol SDHCIRegisterAccess {
    mutating func read8(at offset: UInt) -> UInt8
    mutating func read16(at offset: UInt) -> UInt16
    mutating func read32(at offset: UInt) -> UInt32
    mutating func write8(_ value: UInt8, at offset: UInt)
    mutating func write16(_ value: UInt16, at offset: UInt)
    mutating func write32(_ value: UInt32, at offset: UInt)
    mutating func synchronizePostedWrites()
    mutating func counterValue() -> UInt64
    mutating func spinWaitHint()
}

enum SDCardBoardPreparationResult: UInt8, Equatable {
    case ready
    case cardAbsent
    case timedOut
    case failed
}

/// Board policy owns pin selection, removable-card detection, and supplies.
/// A board must return only after the slot is at legacy 3.3-V signalling.
protocol SDCardBoardControl {
    mutating func prepareSDCard(
        maximumPollCount: UInt64,
        maximumElapsedTicks: UInt64
    ) -> SDCardBoardPreparationResult
}

struct SDHCIDeviceConfiguration: Equatable {
    let inputClockHertz: UInt64
    let counterFrequency: UInt64
    let maximumPollCount: UInt64
    let commandTimeoutTicks: UInt64
    let initializationTimeoutTicks: UInt64

    init?(
        inputClockHertz: UInt64,
        counterFrequency: UInt64,
        maximumPollCount: UInt64,
        commandTimeoutMilliseconds: UInt32,
        initializationTimeoutMilliseconds: UInt32
    ) {
        guard inputClockHertz >= 400_000,
              counterFrequency > 0,
              maximumPollCount > 0,
              commandTimeoutMilliseconds > 0,
              initializationTimeoutMilliseconds
                  >= commandTimeoutMilliseconds,
              let commandTicks = Self.ticks(
                  milliseconds: commandTimeoutMilliseconds,
                  frequency: counterFrequency
              ), let initializationTicks = Self.ticks(
                  milliseconds: initializationTimeoutMilliseconds,
                  frequency: counterFrequency
              ), commandTicks > 0,
              commandTicks <= UInt64.max / 2,
              initializationTicks >= commandTicks,
              initializationTicks <= UInt64.max / 2
        else { return nil }
        self.inputClockHertz = inputClockHertz
        self.counterFrequency = counterFrequency
        self.maximumPollCount = maximumPollCount
        self.commandTimeoutTicks = commandTicks
        self.initializationTimeoutTicks = initializationTicks
    }

    static func ticks(
        milliseconds: UInt32,
        frequency: UInt64
    ) -> UInt64? {
        let wholeSeconds = UInt64(milliseconds / 1_000)
        let remainingMilliseconds = UInt64(milliseconds % 1_000)
        guard wholeSeconds <= UInt64.max / frequency else { return nil }
        let wholeTicks = wholeSeconds * frequency
        let frequencySeconds = frequency / 1_000
        let frequencyRemainder = frequency % 1_000
        guard remainingMilliseconds == 0
                || frequencySeconds <= UInt64.max / remainingMilliseconds
        else { return nil }
        let partialWhole = frequencySeconds * remainingMilliseconds
        let partialRemainder = frequencyRemainder * remainingMilliseconds
        let roundedRemainder = (partialRemainder + 999) / 1_000
        guard partialWhole <= UInt64.max - roundedRemainder,
              wholeTicks <= UInt64.max - partialWhole - roundedRemainder
        else { return nil }
        return wholeTicks + partialWhole + roundedRemainder
    }
}

struct SDHCIClockSelection: Equatable {
    /// Divider fields in the SDHCI Clock Control register, excluding enables.
    let encodedDivisor: UInt16
    let actualClockHertz: UInt64

    static func select(
        inputClockHertz: UInt64,
        maximumClockHertz: UInt64
    ) -> Self? {
        guard inputClockHertz > 0, maximumClockHertz > 0 else { return nil }
        if inputClockHertz <= maximumClockHertz {
            return Self(encodedDivisor: 0, actualClockHertz: inputClockHertz)
        }

        // SDHCI 3.00 encodes a ten-bit divider. Non-zero values divide the
        // base clock by twice the encoded number.
        let doubledTarget = maximumClockHertz > UInt64.max / 2
            ? UInt64.max : maximumClockHertz * 2
        var divisor = inputClockHertz / doubledTarget
        if inputClockHertz % doubledTarget != 0 { divisor += 1 }
        if divisor == 0 { divisor = 1 }
        guard divisor <= 1_023 else { return nil }
        let encoded = UInt16(divisor)
        let lower = (encoded & 0x00ff) << 8
        let upper = (encoded & 0x0300) >> 2
        return Self(
            encodedDivisor: lower | upper,
            actualClockHertz: inputClockHertz / (divisor * 2)
        )
    }
}

/// Canonical 128-bit CSD image. `word0` contains bits 127...96 and `word3`
/// contains bits 31...0, matching the card specification rather than SDHCI's
/// shifted response-register representation.
struct SDCardCSD: Equatable {
    let word0: UInt32
    let word1: UInt32
    let word2: UInt32
    let word3: UInt32

    var logicalBlockCount: UInt64? {
        guard let structure = bits(high: 127, low: 126) else { return nil }
        switch structure {
        case 0:
            guard let readBlockLength = bits(high: 83, low: 80),
                  readBlockLength >= 9,
                  readBlockLength <= 11,
                  let size = bits(high: 73, low: 62),
                  let multiplier = bits(high: 49, low: 47)
            else { return nil }
            let nativeBlockBytes = UInt64(1) << UInt64(readBlockLength)
            let multiplierValue = UInt64(1) << UInt64(multiplier + 2)
            let nativeBlockCount = UInt64(size + 1) * multiplierValue
            let byteCount = nativeBlockCount * nativeBlockBytes
            guard byteCount >= 512, byteCount & 511 == 0 else { return nil }
            return byteCount / 512
        case 1:
            guard let size = bits(high: 69, low: 48) else { return nil }
            return UInt64(size + 1) * 1_024
        default:
            // SDUC uses command/addressing rules outside this bounded first
            // slice and is rejected rather than partially supported.
            return nil
        }
    }

    private func bits(high: UInt32, low: UInt32) -> UInt32? {
        guard high < 128, high >= low, high - low < 32 else { return nil }
        var result: UInt32 = 0
        var sourceBit = low
        var destinationBit: UInt32 = 0
        while sourceBit <= high {
            let cardWord = Int(3 - sourceBit / 32)
            let bitInWord = sourceBit & 31
            let word: UInt32
            switch cardWord {
            case 0: word = word0
            case 1: word = word1
            case 2: word = word2
            default: word = word3
            }
            result |= ((word >> bitInWord) & 1) << destinationBit
            sourceBit += 1
            destinationBit += 1
        }
        return result
    }
}

enum SDHCIInitializationResult: Equatable {
    case ready
    case invalidState
    case cardAbsent
    case boardPreparationTimedOut
    case boardPreparationFailed
    case unsupportedHost
    case hostResetTimedOut
    case clockTimedOut
    case cardInitializationTimedOut
    case cardRejectedCommand(UInt8)
    case unsupportedCard
}

private enum SDHCIBlockDeviceState: UInt8 {
    case cold
    case ready
    case faulted
}

private enum SDHCIRegisterLayout {
    static let blockSizeAndCount: UInt = 0x04
    static let argument: UInt = 0x08
    static let transferModeAndCommand: UInt = 0x0c
    static let response0: UInt = 0x10
    static let response1: UInt = 0x14
    static let response2: UInt = 0x18
    static let response3: UInt = 0x1c
    static let bufferData: UInt = 0x20
    static let presentState: UInt = 0x24
    static let hostControl: UInt = 0x28
    static let powerControl: UInt = 0x29
    static let clockControl: UInt = 0x2c
    static let timeoutControl: UInt = 0x2e
    static let softwareReset: UInt = 0x2f
    static let interruptStatus: UInt = 0x30
    static let interruptStatusEnable: UInt = 0x34
    static let interruptSignalEnable: UInt = 0x38
    static let capabilities: UInt = 0x40
    static let hostControl2: UInt = 0x3e
    static let hostControllerVersion: UInt = 0xfe
}

private enum SDHCIBit {
    static let commandInhibit: UInt32 = 1 << 0
    static let dataInhibit: UInt32 = 1 << 1
    static let commandComplete: UInt32 = 1 << 0
    static let transferComplete: UInt32 = 1 << 1
    static let bufferWriteReady: UInt32 = 1 << 4
    static let bufferReadReady: UInt32 = 1 << 5
    static let interruptError: UInt32 = 1 << 15
    static let allInterruptErrors: UInt32 = 0xffff_8000
    static let busWidth4: UInt8 = 1 << 1
    static let highSpeed: UInt8 = 1 << 2
    static let internalClockEnable: UInt16 = 1 << 0
    static let internalClockStable: UInt16 = 1 << 1
    static let cardClockEnable: UInt16 = 1 << 2
    static let resetAll: UInt8 = 1 << 0
    static let resetCommand: UInt8 = 1 << 1
    static let resetData: UInt8 = 1 << 2
    static let voltage3V3: UInt32 = 1 << 24
    static let readyForData: UInt32 = 1 << 8
    static let cardStateMask: UInt32 = 0xf << 9
    static let transferState: UInt32 = 4 << 9
    static let writeProtectViolation: UInt32 = 1 << 26
    static let cardStatusErrors: UInt32 = 0xfff9_a080
}

private struct SDHCICommandResponse {
    let word0: UInt32
    let word1: UInt32
    let word2: UInt32
    let word3: UInt32
}

private enum SDHCIResponseKind {
    case none
    case short
    case shortWithoutCRC
    case long
    case shortBusy
}

/// Allocation-free, single-block SD memory transport. This first physical
/// slice intentionally uses default-speed, 3.3-V, CPU PIO only: no DMA, CQE,
/// tuning, UHS modes, or 1.8-V signalling can be enabled by this type.
struct SDHCIBlockDevice<Registers: SDHCIRegisterAccess, Board: SDCardBoardControl>:
    BlockDevice
{
    private var registers: Registers
    private var board: Board
    private let configuration: SDHCIDeviceConfiguration
    private var state: SDHCIBlockDeviceState = .cold
    private var isHighCapacity = false
    private var relativeCardAddress: UInt32 = 0
    private(set) var geometry: BlockDeviceGeometry

    init?(
        registers: Registers,
        board: Board,
        configuration: SDHCIDeviceConfiguration
    ) {
        guard let provisionalGeometry = BlockDeviceGeometry(
                  logicalBlockByteCount: 512,
                  logicalBlockCount: 1
              )
        else { return nil }
        self.registers = registers
        self.board = board
        self.configuration = configuration
        self.geometry = provisionalGeometry
    }

    mutating func initialize() -> SDHCIInitializationResult {
        guard state == .cold else { return .invalidState }

        switch board.prepareSDCard(
            maximumPollCount: configuration.maximumPollCount,
            maximumElapsedTicks: configuration.commandTimeoutTicks
        ) {
        case .ready:
            break
        case .cardAbsent:
            return .cardAbsent
        case .timedOut:
            return .boardPreparationTimedOut
        case .failed:
            return .boardPreparationFailed
        }

        let version = registers.read16(
            at: SDHCIRegisterLayout.hostControllerVersion
        )
        let specificationVersion = UInt8(truncatingIfNeeded: version)
        let capabilities = registers.read32(at: SDHCIRegisterLayout.capabilities)
        guard specificationVersion >= 2,
              capabilities & SDHCIBit.voltage3V3 != 0,
              (capabilities >> 16) & 3 <= 3
        else {
            state = .faulted
            return .unsupportedHost
        }

        registers.write32(0, at: SDHCIRegisterLayout.interruptSignalEnable)
        guard reset(mask: SDHCIBit.resetAll) else {
            state = .faulted
            return .hostResetTimedOut
        }
        registers.write32(0, at: SDHCIRegisterLayout.interruptSignalEnable)
        registers.write32(
            UInt32.max,
            at: SDHCIRegisterLayout.interruptStatusEnable
        )
        registers.write32(UInt32.max, at: SDHCIRegisterLayout.interruptStatus)

        var hostControl = registers.read8(at: SDHCIRegisterLayout.hostControl)
        hostControl &= ~(SDHCIBit.busWidth4 | SDHCIBit.highSpeed | (3 << 3))
        registers.write8(hostControl, at: SDHCIRegisterLayout.hostControl)
        var hostControl2 = registers.read16(
            at: SDHCIRegisterLayout.hostControl2
        )
        hostControl2 &= ~UInt16(0x800f) // presets, 1.8 V, and every UHS mode.
        registers.write16(hostControl2, at: SDHCIRegisterLayout.hostControl2)
        registers.write8(0x0e, at: SDHCIRegisterLayout.timeoutControl)
        registers.write8(0x0e, at: SDHCIRegisterLayout.powerControl)
        registers.synchronizePostedWrites()
        registers.write8(0x0f, at: SDHCIRegisterLayout.powerControl)
        registers.synchronizePostedWrites()

        guard setClock(maximumHertz: 400_000),
              wait(milliseconds: 1)
        else {
            state = .faulted
            return .clockTimedOut
        }

        guard command(index: 0, argument: 0, response: .none) != nil else {
            return failInitialization(command: 0)
        }
        guard let interface = command(
                  index: 8,
                  argument: 0x1aa,
                  response: .short
              ), interface.word0 & 0xfff == 0x1aa
        else {
            state = .faulted
            return .unsupportedCard
        }

        let negotiationStart = registers.counterValue()
        var negotiationPolls: UInt64 = 0
        var operatingConditions: UInt32?
        while negotiationPolls < configuration.maximumPollCount,
              registers.counterValue() &- negotiationStart
                  <= configuration.initializationTimeoutTicks {
            guard let applicationPrefix = command(
                      index: 55,
                      argument: 0,
                      response: .short
                  ), !responseHasCardError(applicationPrefix.word0)
            else { return failInitialization(command: 55) }
            guard let conditions = command(
                      index: 41,
                      argument: 0x40ff_8000,
                      response: .shortWithoutCRC
                  )
            else { return failInitialization(command: 41) }
            if conditions.word0 & (1 << 31) != 0 {
                operatingConditions = conditions.word0
                break
            }
            negotiationPolls += 1
            registers.spinWaitHint()
        }
        guard let operatingConditions else {
            state = .faulted
            return .cardInitializationTimedOut
        }
        isHighCapacity = operatingConditions & (1 << 30) != 0

        guard command(index: 2, argument: 0, response: .long) != nil else {
            return failInitialization(command: 2)
        }
        guard let addressResponse = command(
                  index: 3,
                  argument: 0,
                  response: .short
              )
        else { return failInitialization(command: 3) }
        relativeCardAddress = addressResponse.word0 & 0xffff_0000
        guard relativeCardAddress != 0 else {
            state = .faulted
            return .unsupportedCard
        }

        guard let csdResponse = command(
                  index: 9,
                  argument: relativeCardAddress,
                  response: .long
              ), let blockCount = SDCardCSD(
                  word0: csdResponse.word0,
                  word1: csdResponse.word1,
                  word2: csdResponse.word2,
                  word3: csdResponse.word3
              ).logicalBlockCount,
              blockCount <= UInt64(UInt32.max) + 1,
              let discoveredGeometry = BlockDeviceGeometry(
                  logicalBlockByteCount: 512,
                  logicalBlockCount: blockCount
              )
        else {
            state = .faulted
            return .unsupportedCard
        }

        guard let selection = command(
                  index: 7,
                  argument: relativeCardAddress,
                  response: .shortBusy
              ), !responseHasCardError(selection.word0)
        else { return failInitialization(command: 7) }
        if !isHighCapacity {
            guard let blockLength = command(
                      index: 16,
                      argument: 512,
                      response: .short
                  ), !responseHasCardError(blockLength.word0)
            else { return failInitialization(command: 16) }
        }

        guard let busPrefix = command(
                  index: 55,
                  argument: relativeCardAddress,
                  response: .short
              ), !responseHasCardError(busPrefix.word0),
              let busWidth = command(
                  index: 6,
                  argument: 2,
                  response: .short
              ), !responseHasCardError(busWidth.word0)
        else { return failInitialization(command: 6) }
        hostControl = registers.read8(at: SDHCIRegisterLayout.hostControl)
        hostControl = (hostControl & ~SDHCIBit.highSpeed) | SDHCIBit.busWidth4
        registers.write8(hostControl, at: SDHCIRegisterLayout.hostControl)
        registers.synchronizePostedWrites()

        guard setClock(maximumHertz: 25_000_000),
              let status = command(
                  index: 13,
                  argument: relativeCardAddress,
                  response: .short
              ), cardIsReadyForTransfer(status.word0)
        else { return failInitialization(command: 13) }

        geometry = discoveredGeometry
        state = .ready
        return .ready
    }

    mutating func readBlock(
        at logicalBlock: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard state == .ready else { return .transportFailure }
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
        guard output.count >= 512, output.baseAddress != nil else {
            return .invalidBuffer
        }
        guard let argument = commandArgument(for: logicalBlock) else {
            return .invalidBlock
        }
        beginSingleBlockTransfer(reading: true)
        guard let response = command(
                  index: 17,
                  argument: argument,
                  response: .short,
                  dataPresent: true,
                  transferMode: 1 << 4
              ), !responseHasCardError(response.word0),
              waitForInterrupt(SDHCIBit.bufferReadReady)
        else { return faultTransfer() }

        var wordIndex = 0
        while wordIndex < 128 {
            let value = registers.read32(at: SDHCIRegisterLayout.bufferData)
            let byteIndex = wordIndex * 4
            output[byteIndex] = UInt8(truncatingIfNeeded: value)
            output[byteIndex + 1] = UInt8(truncatingIfNeeded: value >> 8)
            output[byteIndex + 2] = UInt8(truncatingIfNeeded: value >> 16)
            output[byteIndex + 3] = UInt8(truncatingIfNeeded: value >> 24)
            wordIndex += 1
        }
        guard waitForInterrupt(SDHCIBit.transferComplete) else {
            return faultTransfer()
        }
        return .success
    }

    mutating func writeBlock(
        at logicalBlock: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard state == .ready else { return .transportFailure }
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
        guard input.count >= 512, input.baseAddress != nil else {
            return .invalidBuffer
        }
        guard let argument = commandArgument(for: logicalBlock) else {
            return .invalidBlock
        }
        beginSingleBlockTransfer(reading: false)
        guard let response = command(
                  index: 24,
                  argument: argument,
                  response: .short,
                  dataPresent: true,
                  transferMode: 0
              )
        else { return faultTransfer() }
        if response.word0 & SDHCIBit.writeProtectViolation != 0 {
            _ = recoverCommandAndDataLines()
            return .readOnly
        }
        guard !responseHasCardError(response.word0),
              waitForInterrupt(SDHCIBit.bufferWriteReady)
        else { return faultTransfer() }

        var wordIndex = 0
        while wordIndex < 128 {
            let byteIndex = wordIndex * 4
            let value = UInt32(input[byteIndex])
                | UInt32(input[byteIndex + 1]) << 8
                | UInt32(input[byteIndex + 2]) << 16
                | UInt32(input[byteIndex + 3]) << 24
            registers.write32(value, at: SDHCIRegisterLayout.bufferData)
            wordIndex += 1
        }
        registers.synchronizePostedWrites()
        guard waitForInterrupt(SDHCIBit.transferComplete) else {
            return faultTransfer()
        }
        return .success
    }

    mutating func synchronize() -> BlockDeviceIOResult {
        guard state == .ready else { return .transportFailure }
        let startedAt = registers.counterValue()
        var polls: UInt64 = 0
        while polls < configuration.maximumPollCount,
              registers.counterValue() &- startedAt
                  <= configuration.initializationTimeoutTicks {
            guard let status = command(
                      index: 13,
                      argument: relativeCardAddress,
                      response: .short
                  ), !responseHasCardError(status.word0)
            else { return faultTransfer() }
            if cardIsReadyForTransfer(status.word0) { return .success }
            polls += 1
            registers.spinWaitHint()
        }
        return faultTransfer()
    }

    private mutating func beginSingleBlockTransfer(reading: Bool) {
        let sizeAndCount = UInt32(512) | UInt32(1) << 16
        registers.write32(sizeAndCount, at: SDHCIRegisterLayout.blockSizeAndCount)
        _ = reading // Direction is encoded atomically with the command below.
    }

    private mutating func command(
        index: UInt8,
        argument: UInt32,
        response: SDHCIResponseKind,
        dataPresent: Bool = false,
        transferMode: UInt16 = 0
    ) -> SDHCICommandResponse? {
        var inhibit = SDHCIBit.commandInhibit
        if dataPresent || response == .shortBusy { inhibit |= SDHCIBit.dataInhibit }
        guard waitForPresentStateClear(inhibit) else { return nil }

        registers.write32(UInt32.max, at: SDHCIRegisterLayout.interruptStatus)
        registers.write32(argument, at: SDHCIRegisterLayout.argument)
        var command: UInt16 = UInt16(index) << 8
        switch response {
        case .none:
            break
        case .long:
            command |= 1 | (1 << 3)
        case .shortWithoutCRC:
            command |= 2
        case .short:
            command |= 2 | (1 << 3) | (1 << 4)
        case .shortBusy:
            command |= 3 | (1 << 3) | (1 << 4)
        }
        if dataPresent { command |= 1 << 5 }
        registers.write32(
            UInt32(transferMode) | UInt32(command) << 16,
            at: SDHCIRegisterLayout.transferModeAndCommand
        )
        registers.synchronizePostedWrites()
        guard waitForInterrupt(SDHCIBit.commandComplete) else { return nil }

        let value: SDHCICommandResponse
        if response == .long {
            // SDHCI drops the CRC byte and shifts each 32-bit response window;
            // stitch adjacent bytes back into the card's canonical CSD words.
            value = SDHCICommandResponse(
                word0: registers.read32(at: SDHCIRegisterLayout.response3) << 8
                    | UInt32(registers.read8(at: SDHCIRegisterLayout.response3 - 1)),
                word1: registers.read32(at: SDHCIRegisterLayout.response2) << 8
                    | UInt32(registers.read8(at: SDHCIRegisterLayout.response2 - 1)),
                word2: registers.read32(at: SDHCIRegisterLayout.response1) << 8
                    | UInt32(registers.read8(at: SDHCIRegisterLayout.response1 - 1)),
                word3: registers.read32(at: SDHCIRegisterLayout.response0) << 8
            )
        } else {
            value = SDHCICommandResponse(
                word0: registers.read32(at: SDHCIRegisterLayout.response0),
                word1: 0,
                word2: 0,
                word3: 0
            )
        }

        if response == .shortBusy,
           !waitForPresentStateClear(SDHCIBit.dataInhibit) {
            return nil
        }
        return value
    }

    private mutating func setClock(maximumHertz: UInt64) -> Bool {
        guard let selection = SDHCIClockSelection.select(
                  inputClockHertz: configuration.inputClockHertz,
                  maximumClockHertz: maximumHertz
              )
        else { return false }
        registers.write16(0, at: SDHCIRegisterLayout.clockControl)
        registers.write16(
            selection.encodedDivisor | SDHCIBit.internalClockEnable,
            at: SDHCIRegisterLayout.clockControl
        )
        registers.synchronizePostedWrites()
        guard waitForClockStable() else { return false }
        registers.write16(
            selection.encodedDivisor | SDHCIBit.internalClockEnable
                | SDHCIBit.cardClockEnable,
            at: SDHCIRegisterLayout.clockControl
        )
        registers.synchronizePostedWrites()
        return registers.read16(at: SDHCIRegisterLayout.clockControl)
            & SDHCIBit.cardClockEnable != 0
    }

    private mutating func reset(mask: UInt8) -> Bool {
        registers.write8(mask, at: SDHCIRegisterLayout.softwareReset)
        registers.synchronizePostedWrites()
        let startedAt = registers.counterValue()
        var polls: UInt64 = 0
        while polls < configuration.maximumPollCount,
              registers.counterValue() &- startedAt
                  <= configuration.commandTimeoutTicks {
            if registers.read8(at: SDHCIRegisterLayout.softwareReset)
                & mask == 0 { return true }
            polls += 1
            registers.spinWaitHint()
        }
        return false
    }

    private mutating func waitForClockStable() -> Bool {
        let startedAt = registers.counterValue()
        var polls: UInt64 = 0
        while polls < configuration.maximumPollCount,
              registers.counterValue() &- startedAt
                  <= configuration.commandTimeoutTicks {
            if registers.read16(at: SDHCIRegisterLayout.clockControl)
                & SDHCIBit.internalClockStable != 0 { return true }
            polls += 1
            registers.spinWaitHint()
        }
        return false
    }

    private mutating func waitForPresentStateClear(_ mask: UInt32) -> Bool {
        let startedAt = registers.counterValue()
        var polls: UInt64 = 0
        while polls < configuration.maximumPollCount,
              registers.counterValue() &- startedAt
                  <= configuration.commandTimeoutTicks {
            if registers.read32(at: SDHCIRegisterLayout.presentState)
                & mask == 0 { return true }
            polls += 1
            registers.spinWaitHint()
        }
        return false
    }

    private mutating func waitForInterrupt(_ mask: UInt32) -> Bool {
        let startedAt = registers.counterValue()
        var polls: UInt64 = 0
        while polls < configuration.maximumPollCount,
              registers.counterValue() &- startedAt
                  <= configuration.commandTimeoutTicks {
            let status = registers.read32(at: SDHCIRegisterLayout.interruptStatus)
            if status & (SDHCIBit.interruptError | SDHCIBit.allInterruptErrors)
                != 0 { return false }
            if status & mask == mask {
                registers.write32(mask, at: SDHCIRegisterLayout.interruptStatus)
                return true
            }
            polls += 1
            registers.spinWaitHint()
        }
        return false
    }

    private mutating func wait(milliseconds: UInt32) -> Bool {
        guard let requiredTicks = SDHCIDeviceConfiguration.ticks(
                  milliseconds: milliseconds,
                  frequency: configuration.counterFrequency
              ), requiredTicks <= configuration.commandTimeoutTicks
        else { return false }
        let startedAt = registers.counterValue()
        var polls: UInt64 = 0
        while registers.counterValue() &- startedAt < requiredTicks {
            guard polls < configuration.maximumPollCount else { return false }
            polls += 1
            registers.spinWaitHint()
        }
        return true
    }

    private func commandArgument(for logicalBlock: UInt64) -> UInt32? {
        if isHighCapacity {
            guard logicalBlock <= UInt64(UInt32.max) else { return nil }
            return UInt32(logicalBlock)
        }
        guard logicalBlock <= UInt64(UInt32.max) / 512 else { return nil }
        return UInt32(logicalBlock * 512)
    }

    private func responseHasCardError(_ response: UInt32) -> Bool {
        response & SDHCIBit.cardStatusErrors != 0
    }

    private func cardIsReadyForTransfer(_ status: UInt32) -> Bool {
        status & SDHCIBit.cardStatusErrors == 0
            && status & SDHCIBit.readyForData != 0
            && status & SDHCIBit.cardStateMask == SDHCIBit.transferState
    }

    private mutating func recoverCommandAndDataLines() -> Bool {
        reset(mask: SDHCIBit.resetCommand | SDHCIBit.resetData)
    }

    private mutating func faultTransfer() -> BlockDeviceIOResult {
        _ = recoverCommandAndDataLines()
        state = .faulted
        return .transportFailure
    }

    private mutating func failInitialization(
        command: UInt8
    ) -> SDHCIInitializationResult {
        _ = recoverCommandAndDataLines()
        state = .faulted
        return .cardRejectedCommand(command)
    }
}
