/// The RP1 Ethernet board sequence is deliberately expressed through one
/// injected register/counter boundary. Host tests can model posted writes and
/// a stopped architectural counter without mapping any hardware, while the
/// bare-metal implementation remains allocation-free.
protocol RP1GEMBoardRegisterDelayAccess {
    mutating func read32(at address: UInt) -> UInt32
    mutating func write32(_ value: UInt32, at address: UInt)
    mutating func synchronizePostedWrites()
    mutating func counterFrequency() -> UInt64
    mutating func counterValue() -> UInt64
    mutating func spinWaitHint()
}

/// Volatile RP1 board access. RP1 is reached through PCIe, so a data barrier
/// orders every posted store and the preparation policy follows it with a
/// readback from the affected register block.
struct RP1GEMBoardMMIOAccess: RP1GEMBoardRegisterDelayAccess {
    @inline(__always)
    mutating func read32(at address: UInt) -> UInt32 {
        MMIO.load32(at: address)
    }

    @inline(__always)
    mutating func write32(_ value: UInt32, at address: UInt) {
        MMIO.store32(value, at: address)
    }

    @inline(__always)
    mutating func synchronizePostedWrites() {
        AArch64.synchronizeData()
    }

    @inline(__always)
    mutating func counterFrequency() -> UInt64 {
        AArch64.counterFrequency
    }

    @inline(__always)
    mutating func counterValue() -> UInt64 {
        AArch64.counterValue
    }

    @inline(__always)
    mutating func spinWaitHint() {
        AArch64.spinHint()
    }
}

enum RP1GEMBoardRegisterLayout {
    // Clock IDs in the current RP1 Device Tree binding.
    static let systemClockID: UInt32 = 12
    static let ethernetClockID: UInt32 = 16
    static let ethernetTimestampClockID: UInt32 = 29

    // RP1 clock-generator CTRL registers. Their ENABLE field is bit 11.
    static let systemClockControl: UInt64 = 0x014
    static let ethernetClockControl: UInt64 = 0x064
    static let ethernetTimestampClockControl: UInt64 = 0x134
    static let clockEnable: UInt32 = 1 << 11

    // Each RP1 GPIO bank occupies one complete 16-KiB atomic aperture.
    static let gpioBankStride: UInt64 = 0x4_000
    static let gpioAggregateLength: UInt64 = 0xc_000
    static let gpioResourceStride: UInt64 = 0x1_0000
    static let atomicSet: UInt64 = 0x2_000
    static let atomicClear: UInt64 = 0x3_000

    static let rioOutput: UInt64 = 0x000
    static let rioOutputEnable: UInt64 = 0x004
    static let gpioStatusStride: UInt64 = 0x008
    static let gpioControl: UInt64 = 0x004
    static let padControl: UInt64 = 0x004
    static let padControlStride: UInt64 = 0x004

    static let systemRIOFunction: UInt32 = 5
    static let functionSelectMask: UInt32 = 0x1f
    static let outputOverrideMask: UInt32 = 3 << 12
    static let outputEnableOverrideMask: UInt32 = 3 << 14
    static let padOutputDisable: UInt32 = 1 << 7
    static let outputEnabledToPad: UInt32 = 1 << 13
    static let outputValueToPad: UInt32 = 1 << 9
}

private struct RP1GEMResetGPIOAddresses {
    let status: UInt
    let control: UInt
    let output: UInt
    let outputSet: UInt
    let outputClear: UInt
    let outputEnable: UInt
    let outputEnableSet: UInt
    let padControl: UInt
    let padOutputDisableClear: UInt
    let mask: UInt32
}

private enum RP1GEMDelayResult: UInt8 {
    case complete
    case timedOut
    case failed
}

/// Stable stage identifiers written to the persistent boot log when RP1 board
/// preparation fails. Raw values are part of the diagnostic wire contract.
enum RP1GEMBoardPreparationStage: UInt8, Equatable {
    case invalidConfiguration = 1
    case systemClockEnable = 2
    case ethernetClockEnable = 3
    case timestampClockEnable = 4
    case phyResetGPIOLayout = 5
    case phyResetAssertOutput = 6
    case phyResetOutputEnable = 7
    case phyResetFunctionSelect = 8
    case phyResetPadOutput = 9
    case phyResetAssertStatus = 10
    case phyResetDelayCounter = 11
    case phyResetDelayTimeout = 12
    case phyResetDeassertOutput = 13
    case phyResetDeassertStatus = 14
}

/// Exact failed readback or delay observation. `registerAddress` is zero for
/// validation and architectural-counter stages; otherwise it is the translated
/// RP1 register address used by the failed operation.
struct RP1GEMBoardPreparationDiagnostic: Equatable {
    let stage: RP1GEMBoardPreparationStage
    let registerAddress: UInt64
    let expectedValue: UInt64
    let observedValue: UInt64
}

/// Enables the three RP1 clocks needed by GEM and, when described by firmware,
/// performs a glitch-free external PHY reset through SYS_RIO. No undocumented
/// ETH_CFG policy is written here; link status remains owned by the separate
/// read-only configuration-register adapter.
struct RP1GEMBoardPreparation<Access: RP1GEMBoardRegisterDelayAccess>:
    RP1GEMHardwarePreparation
{
    private let resources: RP1GEMBoardResources
    private var access: Access
    private var isPrepared = false
    private(set) var lastDiagnostic: RP1GEMBoardPreparationDiagnostic?

    init(resources: RP1GEMBoardResources, access: Access) {
        self.resources = resources
        self.access = access
    }

    mutating func prepareRP1Ethernet(
        maximumPollCount: UInt64
    ) -> CadenceGEMBoardPreparationResult {
        lastDiagnostic = nil
        if isPrepared { return .ready }

        guard maximumPollCount > 0 else {
            recordFailure(
                stage: .invalidConfiguration,
                expectedValue: 1,
                observedValue: maximumPollCount
            )
            return .failed
        }
        guard Self.valid(resources: resources) else {
            recordFailure(stage: .invalidConfiguration)
            return .failed
        }
        let resetGPIO: RP1GEMResetGPIOAddresses?
        if let reset = resources.phyReset {
            guard let gpio = Self.resetGPIOAddresses(for: reset) else {
                recordFailure(stage: .phyResetGPIOLayout)
                return .failed
            }
            resetGPIO = gpio
        } else {
            resetGPIO = nil
        }

        guard enableClock(
                  at: RP1GEMBoardRegisterLayout.systemClockControl,
                  stage: .systemClockEnable
              ),
              enableClock(
                  at: RP1GEMBoardRegisterLayout.ethernetClockControl,
                  stage: .ethernetClockEnable
              ),
              enableClock(
                  at: RP1GEMBoardRegisterLayout
                      .ethernetTimestampClockControl,
                  stage: .timestampClockEnable
              )
        else {
            return .failed
        }

        guard let reset = resources.phyReset else {
            isPrepared = true
            return .ready
        }
        guard let gpio = resetGPIO else {
            recordFailure(stage: .phyResetGPIOLayout)
            return .failed
        }

        let assertedHigh = reset.assertedLevel == .high
        guard driveGPIO(
                  gpio,
                  high: assertedHigh,
                  stage: .phyResetAssertOutput
              ),
              enableGPIOOutput(
                  gpio,
                  stage: .phyResetOutputEnable
              ),
              selectSystemRIO(
                  gpio,
                  stage: .phyResetFunctionSelect
              ),
              enablePadOutput(
                  gpio,
                  stage: .phyResetPadOutput
              ),
              verifyGPIO(
                  gpio,
                  high: assertedHigh,
                  stage: .phyResetAssertStatus
              )
        else {
            return .failed
        }

        switch delay(
            milliseconds: reset.durationMilliseconds,
            maximumPollCount: maximumPollCount
        ) {
        case .complete:
            break
        case .timedOut:
            // Keeping the PHY asserted is the safest state when the required
            // reset pulse width could not be established.
            return .timedOut
        case .failed:
            return .failed
        }

        let deassertedHigh = !assertedHigh
        guard driveGPIO(
                  gpio,
                  high: deassertedHigh,
                  stage: .phyResetDeassertOutput
              ),
              verifyGPIO(
                  gpio,
                  high: deassertedHigh,
                  stage: .phyResetDeassertStatus
              )
        else {
            return .failed
        }
        isPrepared = true
        return .ready
    }

    private mutating func enableClock(
        at offset: UInt64,
        stage: RP1GEMBoardPreparationStage
    ) -> Bool {
        guard let address = Self.wordAddress(
                  in: resources.clocks.controllerRegisters,
                  offset: offset
              ),
              let setAddress = Self.wordAddress(
                  in: resources.clocks.controllerRegisters,
                  offset: RP1GEMBoardRegisterLayout.atomicSet + offset
              )
        else {
            recordFailure(stage: stage)
            return false
        }
        let current = access.read32(at: address)
        if current & RP1GEMBoardRegisterLayout.clockEnable != 0 {
            return true
        }
        // clocks_main implements RP1's published atomic register aliases. Use
        // the SET aperture so the posted PCIe transaction carries only the
        // ENABLE bit and cannot replay stale source/divider fields from the
        // preceding read across the link.
        access.write32(
            RP1GEMBoardRegisterLayout.clockEnable,
            at: setAddress
        )
        access.synchronizePostedWrites()
        let observed = access.read32(at: address)
        guard observed & RP1GEMBoardRegisterLayout.clockEnable != 0 else {
            recordFailure(
                stage: stage,
                registerAddress: UInt64(address),
                expectedValue: UInt64(RP1GEMBoardRegisterLayout.clockEnable),
                observedValue: UInt64(observed)
            )
            return false
        }
        return true
    }

    private mutating func driveGPIO(
        _ gpio: RP1GEMResetGPIOAddresses,
        high: Bool,
        stage: RP1GEMBoardPreparationStage
    ) -> Bool {
        access.write32(
            gpio.mask,
            at: high ? gpio.outputSet : gpio.outputClear
        )
        access.synchronizePostedWrites()
        let output = access.read32(at: gpio.output)
        let expected = high ? gpio.mask : 0
        guard output & gpio.mask == expected else {
            recordFailure(
                stage: stage,
                registerAddress: UInt64(gpio.output),
                expectedValue: UInt64(expected),
                observedValue: UInt64(output)
            )
            return false
        }
        return true
    }

    private mutating func enableGPIOOutput(
        _ gpio: RP1GEMResetGPIOAddresses,
        stage: RP1GEMBoardPreparationStage
    ) -> Bool {
        access.write32(gpio.mask, at: gpio.outputEnableSet)
        access.synchronizePostedWrites()
        let observed = access.read32(at: gpio.outputEnable)
        guard observed & gpio.mask != 0 else {
            recordFailure(
                stage: stage,
                registerAddress: UInt64(gpio.outputEnable),
                expectedValue: UInt64(gpio.mask),
                observedValue: UInt64(observed)
            )
            return false
        }
        return true
    }

    private mutating func selectSystemRIO(
        _ gpio: RP1GEMResetGPIOAddresses,
        stage: RP1GEMBoardPreparationStage
    ) -> Bool {
        let current = access.read32(at: gpio.control)
        let selected = current
            & ~RP1GEMBoardRegisterLayout.functionSelectMask
            & ~RP1GEMBoardRegisterLayout.outputOverrideMask
            & ~RP1GEMBoardRegisterLayout.outputEnableOverrideMask
            | RP1GEMBoardRegisterLayout.systemRIOFunction
        access.write32(selected, at: gpio.control)
        access.synchronizePostedWrites()
        let observed = access.read32(at: gpio.control)
        guard observed == selected else {
            recordFailure(
                stage: stage,
                registerAddress: UInt64(gpio.control),
                expectedValue: UInt64(selected),
                observedValue: UInt64(observed)
            )
            return false
        }
        return true
    }

    private mutating func enablePadOutput(
        _ gpio: RP1GEMResetGPIOAddresses,
        stage: RP1GEMBoardPreparationStage
    ) -> Bool {
        let current = access.read32(at: gpio.padControl)
        access.write32(
            RP1GEMBoardRegisterLayout.padOutputDisable,
            at: gpio.padOutputDisableClear
        )
        access.synchronizePostedWrites()
        let expected = current
            & ~RP1GEMBoardRegisterLayout.padOutputDisable
        let observed = access.read32(at: gpio.padControl)
        guard observed == expected else {
            recordFailure(
                stage: stage,
                registerAddress: UInt64(gpio.padControl),
                expectedValue: UInt64(expected),
                observedValue: UInt64(observed)
            )
            return false
        }
        return true
    }

    private mutating func verifyGPIO(
        _ gpio: RP1GEMResetGPIOAddresses,
        high: Bool,
        stage: RP1GEMBoardPreparationStage
    ) -> Bool {
        let status = access.read32(at: gpio.status)
        let outputEnabled = status
            & RP1GEMBoardRegisterLayout.outputEnabledToPad != 0
        let outputHigh = status
            & RP1GEMBoardRegisterLayout.outputValueToPad != 0
        guard outputEnabled && outputHigh == high else {
            let expected = RP1GEMBoardRegisterLayout.outputEnabledToPad
                | (high
                    ? RP1GEMBoardRegisterLayout.outputValueToPad
                    : 0)
            recordFailure(
                stage: stage,
                registerAddress: UInt64(gpio.status),
                expectedValue: UInt64(expected),
                observedValue: UInt64(status)
            )
            return false
        }
        return true
    }

    private mutating func delay(
        milliseconds: UInt32,
        maximumPollCount: UInt64
    ) -> RP1GEMDelayResult {
        let frequency = access.counterFrequency()
        guard frequency > 0,
              let requiredTicks = Self.counterTicks(
                  frequency: frequency,
                  milliseconds: milliseconds
              )
        else {
            recordFailure(
                stage: .phyResetDelayCounter,
                expectedValue: UInt64(milliseconds),
                observedValue: frequency
            )
            return .failed
        }

        let start = access.counterValue()
        var pollCount: UInt64 = 0
        while true {
            let elapsed = access.counterValue() &- start
            if elapsed >= requiredTicks { return .complete }
            guard pollCount < maximumPollCount else {
                recordFailure(
                    stage: .phyResetDelayTimeout,
                    expectedValue: requiredTicks,
                    observedValue: elapsed
                )
                return .timedOut
            }
            pollCount += 1
            access.spinWaitHint()
        }
    }

    private mutating func recordFailure(
        stage: RP1GEMBoardPreparationStage,
        registerAddress: UInt64 = 0,
        expectedValue: UInt64 = 0,
        observedValue: UInt64 = 0
    ) {
        lastDiagnostic = RP1GEMBoardPreparationDiagnostic(
            stage: stage,
            registerAddress: registerAddress,
            expectedValue: expectedValue,
            observedValue: observedValue
        )
    }

    private static func counterTicks(
        frequency: UInt64,
        milliseconds: UInt32
    ) -> UInt64? {
        guard frequency > 0,
              milliseconds > 0,
              milliseconds <= 1_000
        else {
            return nil
        }
        let duration = UInt64(milliseconds)
        let wholeFrequency = frequency / 1_000
        guard wholeFrequency <= UInt64.max / duration else { return nil }
        let wholeTicks = wholeFrequency * duration
        let remainderProduct = frequency % 1_000 * duration
        let fractionalTicks = (remainderProduct + 999) / 1_000
        guard wholeTicks <= UInt64.max - fractionalTicks else { return nil }
        let ticks = wholeTicks + fractionalTicks
        return ticks > 0 ? ticks : nil
    }

    private static func valid(resources: RP1GEMBoardResources) -> Bool {
        let blockLength: UInt64 = 0x4_000
        guard validResource(resources.gemRegisters, length: blockLength),
              validResource(
                  resources.ethernetConfigurationRegisters,
                  length: blockLength
              ),
              resources.gemRegisters.baseAddress
                  <= UInt64.max - blockLength,
              resources.ethernetConfigurationRegisters.baseAddress
                  == resources.gemRegisters.baseAddress + blockLength,
              resources.clocks.controllerPhandle != 0,
              validResource(resources.clocks.controllerRegisters),
              wordAddress(
                  in: resources.clocks.controllerRegisters,
                  offset: RP1GEMBoardRegisterLayout.atomicSet
                      + RP1GEMBoardRegisterLayout
                          .ethernetTimestampClockControl
              ) != nil,
              resources.clocks.peripheralClockID
                  == RP1GEMBoardRegisterLayout.systemClockID,
              resources.clocks.hostClockID
                  == RP1GEMBoardRegisterLayout.systemClockID,
              resources.clocks.timestampClockID
                  == RP1GEMBoardRegisterLayout.ethernetTimestampClockID,
              resources.clocks.transmitClockID
                  == RP1GEMBoardRegisterLayout.ethernetClockID,
              resources.phy.clause22Address < 32
        else {
            return false
        }

        if let mac = resources.localMACAddress,
           !mac.isAllZero && !mac.isUsableUnicast {
            return false
        }
        guard let reset = resources.phyReset else { return true }
        return reset.gpioControllerPhandle != 0
            && reset.durationMilliseconds > 0
            && reset.durationMilliseconds <= 1_000
    }

    private static func validResource(
        _ resource: DeviceResource,
        length exactLength: UInt64? = nil
    ) -> Bool {
        guard resource.baseAddress & 3 == 0,
              resource.length >= 4,
              resource.length <= UInt64.max - resource.baseAddress,
              resource.baseAddress <= UInt64(UInt.max)
        else {
            return false
        }
        return exactLength == nil || resource.length == exactLength
    }

    private static func wordAddress(
        in resource: DeviceResource,
        offset: UInt64
    ) -> UInt? {
        guard validResource(resource),
              offset & 3 == 0,
              offset <= resource.length - 4,
              resource.baseAddress <= UInt64.max - offset
        else {
            return nil
        }
        let address = resource.baseAddress + offset
        guard address <= UInt64(UInt.max) else { return nil }
        return UInt(address)
    }

    private static func resetGPIOAddresses(
        for reset: PlatformPHYResetDescription
    ) -> RP1GEMResetGPIOAddresses? {
        let registers = reset.gpioRegisters
        let stride = RP1GEMBoardRegisterLayout.gpioResourceStride
        guard reset.line < 54,
              validResource(
                  registers.ioBank,
                  length: RP1GEMBoardRegisterLayout.gpioAggregateLength
              ),
              validResource(
                  registers.rio,
                  length: RP1GEMBoardRegisterLayout.gpioAggregateLength
              ),
              validResource(
                  registers.padsBank,
                  length: RP1GEMBoardRegisterLayout.gpioAggregateLength
              ),
              registers.ioBank.baseAddress <= UInt64.max - 2 * stride,
              registers.rio.baseAddress
                  == registers.ioBank.baseAddress + stride,
              registers.padsBank.baseAddress
                  == registers.ioBank.baseAddress + 2 * stride
        else {
            return nil
        }

        let bank: UInt64
        let localLine: UInt64
        switch reset.line {
        case 0...27:
            bank = 0
            localLine = UInt64(reset.line)
        case 28...33:
            bank = 1
            localLine = UInt64(reset.line - 28)
        case 34...53:
            bank = 2
            localLine = UInt64(reset.line - 34)
        default:
            return nil
        }

        let bankOffset = bank * RP1GEMBoardRegisterLayout.gpioBankStride
        let statusOffset = bankOffset
            + localLine * RP1GEMBoardRegisterLayout.gpioStatusStride
        let controlOffset = statusOffset
            + RP1GEMBoardRegisterLayout.gpioControl
        let padOffset = bankOffset + RP1GEMBoardRegisterLayout.padControl
            + localLine * RP1GEMBoardRegisterLayout.padControlStride
        let outputOffset = bankOffset + RP1GEMBoardRegisterLayout.rioOutput
        let outputEnableOffset = bankOffset
            + RP1GEMBoardRegisterLayout.rioOutputEnable

        guard let status = wordAddress(
                  in: registers.ioBank,
                  offset: statusOffset
              ),
              let control = wordAddress(
                  in: registers.ioBank,
                  offset: controlOffset
              ),
              let output = wordAddress(
                  in: registers.rio,
                  offset: outputOffset
              ),
              let outputSet = wordAddress(
                  in: registers.rio,
                  offset: outputOffset
                      + RP1GEMBoardRegisterLayout.atomicSet
              ),
              let outputClear = wordAddress(
                  in: registers.rio,
                  offset: outputOffset
                      + RP1GEMBoardRegisterLayout.atomicClear
              ),
              let outputEnable = wordAddress(
                  in: registers.rio,
                  offset: outputEnableOffset
              ),
              let outputEnableSet = wordAddress(
                  in: registers.rio,
                  offset: outputEnableOffset
                      + RP1GEMBoardRegisterLayout.atomicSet
              ),
              let padControl = wordAddress(
                  in: registers.padsBank,
                  offset: padOffset
              ),
              let padOutputDisableClear = wordAddress(
                  in: registers.padsBank,
                  offset: padOffset
                      + RP1GEMBoardRegisterLayout.atomicClear
              )
        else {
            return nil
        }

        return RP1GEMResetGPIOAddresses(
            status: status,
            control: control,
            output: output,
            outputSet: outputSet,
            outputClear: outputClear,
            outputEnable: outputEnable,
            outputEnableSet: outputEnableSet,
            padControl: padControl,
            padOutputDisableClear: padOutputDisableClear,
            mask: UInt32(1) << UInt32(localLine)
        )
    }
}
