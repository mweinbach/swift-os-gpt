/// Absolute board-register and architectural-delay boundary for BCM2712 slot
/// handoff. It is separate from SDHCIRegisterAccess because GPIO and wrapper
/// configuration are board policy, not part of the host-controller standard.
protocol BCM2712SDCardBoardRegisterAccess {
    mutating func read32(at address: UInt) -> UInt32
    mutating func write32(_ value: UInt32, at address: UInt)
    mutating func synchronizePostedWrites()
    mutating func counterFrequency() -> UInt64
    mutating func counterValue() -> UInt64
    mutating func spinWaitHint()
}

struct BCM2712SDCardBoardMMIOAccess: BCM2712SDCardBoardRegisterAccess {
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

private enum BCM2712SDCardBoardState: UInt8 {
    case cold
    case ready
    case failed
}

private enum BCM2712SDCardRegisterLayout {
    static let sdPinSelection: UInt64 = 0x44
    static let sdPinSelectionMask: UInt32 = 3
    static let sdPinSelectionSD: UInt32 = 1 << 1
    static let capabilityTimerFrequency: UInt64 = 0x4c
    static let capabilityMultiplier: UInt32 = 3 << 12

    // brcmstb GIO bank zero. IODIR is active-high for input.
    static let gpioData: UInt64 = 0x04
    static let gpioDirection: UInt64 = 0x08
}

/// Clean-room BCM2712 board sequence for the firmware-booted removable slot.
/// All resource and polarity checks happen before the first write. The card is
/// then power-cycled into 3.3 V, and no voltage-switch path exists in this type.
struct BCM2712SDCardBoardControl<Access: BCM2712SDCardBoardRegisterAccess>:
    SDCardBoardControl
{
    private let configurationAddress: UInt
    private let capabilityAddress: UInt
    private let capabilityValue: UInt32
    private let gpioDataAddress: UInt
    private let gpioDirectionAddress: UInt
    private let ioVoltageMask: UInt32
    private let io3V3High: Bool
    private let powerMask: UInt32
    private let powerEnabledHigh: Bool
    private let detectMask: UInt32
    private let detectPresentHigh: Bool
    private let settlingMicroseconds: UInt32
    private var access: Access
    private var state: BCM2712SDCardBoardState = .cold

    init?(
        description: PlatformStorageDeviceDescription,
        access: Access
    ) {
        let power = description.power
        guard description.controller == .bcm2712SDHCI,
              description.busWidth == 4,
              description.hostRegisters.length >= 0x100,
              description.configurationRegisters.length
                  >= BCM2712SDCardRegisterLayout.capabilityTimerFrequency + 4,
              power.gpioRegisters.length
                  >= BCM2712SDCardRegisterLayout.gpioDirection + 4,
              description.hostRegisters.length <= UInt64.max
                  - description.hostRegisters.baseAddress,
              description.configurationRegisters.length <= UInt64.max
                  - description.configurationRegisters.baseAddress,
              power.gpioRegisters.length <= UInt64.max
                  - power.gpioRegisters.baseAddress,
              description.configurationRegisters.baseAddress
                  <= UInt64(UInt.max),
              power.gpioRegisters.baseAddress <= UInt64(UInt.max),
              BCM2712SDCardRegisterLayout.sdPinSelection
                  <= UInt64(UInt.max)
                    - description.configurationRegisters.baseAddress,
              BCM2712SDCardRegisterLayout.gpioDirection
                  <= UInt64(UInt.max) - power.gpioRegisters.baseAddress,
              power.ioVoltageSelectLine < 32,
              power.cardPowerEnableLine < 32,
              power.cardDetectLine < 32,
              power.ioVoltageSelectLine != power.cardPowerEnableLine,
              power.ioVoltageSelectLine != power.cardDetectLine,
              power.cardPowerEnableLine != power.cardDetectLine,
              power.voltageSettlingMicroseconds > 0,
              power.voltageSettlingMicroseconds <= 1_000_000,
              description.inputClockHertz % 1_000_000 == 0,
              description.inputClockHertz / 1_000_000 > 0,
              description.inputClockHertz / 1_000_000 <= 0xff
        else { return nil }

        self.configurationAddress = UInt(
            description.configurationRegisters.baseAddress
                + BCM2712SDCardRegisterLayout.sdPinSelection
        )
        self.capabilityAddress = UInt(
            description.configurationRegisters.baseAddress
                + BCM2712SDCardRegisterLayout.capabilityTimerFrequency
        )
        self.capabilityValue = BCM2712SDCardRegisterLayout.capabilityMultiplier
            | description.inputClockHertz / 1_000_000
        self.gpioDataAddress = UInt(
            power.gpioRegisters.baseAddress
                + BCM2712SDCardRegisterLayout.gpioData
        )
        self.gpioDirectionAddress = UInt(
            power.gpioRegisters.baseAddress
                + BCM2712SDCardRegisterLayout.gpioDirection
        )
        self.ioVoltageMask = UInt32(1) << power.ioVoltageSelectLine
        self.io3V3High = power.io3V3SelectLevel == .high
        self.powerMask = UInt32(1) << power.cardPowerEnableLine
        self.powerEnabledHigh = power.cardPowerEnabledLevel == .high
        self.detectMask = UInt32(1) << power.cardDetectLine
        self.detectPresentHigh = power.cardDetectPresentLevel == .high
        self.settlingMicroseconds = power.voltageSettlingMicroseconds
        self.access = access
    }

    mutating func prepareSDCard(
        maximumPollCount: UInt64,
        maximumElapsedTicks: UInt64
    ) -> SDCardBoardPreparationResult {
        if state == .ready { return .ready }
        guard state == .cold,
              maximumPollCount > 0,
              maximumElapsedTicks > 0
        else { return .failed }

        // Resolve every precondition with reads only. In particular, an
        // ambiguous direction contract or absent card cannot toggle supplies.
        let frequency = access.counterFrequency()
        guard let settlingTicks = Self.ticks(
                  microseconds: settlingMicroseconds,
                  frequency: frequency
              ), settlingTicks > 0,
              settlingTicks <= maximumElapsedTicks
        else { return reject(.failed) }
        let originalDirection = access.read32(at: gpioDirectionAddress)
        let originalData = access.read32(at: gpioDataAddress)
        let originalSelection = access.read32(at: configurationAddress)
        _ = access.read32(at: capabilityAddress)
        guard originalDirection & detectMask != 0 else {
            return reject(.failed)
        }
        guard isHigh(originalData, mask: detectMask) == detectPresentHigh else {
            return .cardAbsent
        }

        let outputMask = ioVoltageMask | powerMask
        var poweredOffData = originalData
        poweredOffData = setting(
            poweredOffData,
            mask: ioVoltageMask,
            high: io3V3High
        )
        poweredOffData = setting(
            poweredOffData,
            mask: powerMask,
            high: !powerEnabledHigh
        )
        access.write32(poweredOffData, at: gpioDataAddress)
        access.synchronizePostedWrites()
        access.write32(
            originalDirection & ~outputMask,
            at: gpioDirectionAddress
        )
        access.synchronizePostedWrites()
        guard access.read32(at: gpioDirectionAddress) & outputMask == 0,
              access.read32(at: gpioDataAddress) & outputMask
                  == poweredOffData & outputMask
        else { return reject(.failed) }

        let selected = originalSelection
            & ~BCM2712SDCardRegisterLayout.sdPinSelectionMask
            | BCM2712SDCardRegisterLayout.sdPinSelectionSD
        access.write32(selected, at: configurationAddress)
        access.synchronizePostedWrites()
        guard access.read32(at: configurationAddress)
                  & BCM2712SDCardRegisterLayout.sdPinSelectionMask
                == BCM2712SDCardRegisterLayout.sdPinSelectionSD
        else { return reject(.failed) }

        // BCM2712 requires its wrapper's timer-frequency estimate even when
        // SwiftOS leaves CQE disabled. The low byte is the DT clock in MHz;
        // the multiplier field is the documented BCM2712 value.
        access.write32(capabilityValue, at: capabilityAddress)
        access.synchronizePostedWrites()
        guard access.read32(at: capabilityAddress) == capabilityValue else {
            return reject(.failed)
        }

        guard delay(
                  requiredTicks: settlingTicks,
                  maximumPollCount: maximumPollCount,
                  maximumElapsedTicks: maximumElapsedTicks
              )
        else { return reject(.timedOut) }

        let poweredOnData = setting(
            poweredOffData,
            mask: powerMask,
            high: powerEnabledHigh
        )
        access.write32(poweredOnData, at: gpioDataAddress)
        access.synchronizePostedWrites()
        guard access.read32(at: gpioDataAddress) & outputMask
                  == poweredOnData & outputMask,
              delay(
                  requiredTicks: settlingTicks,
                  maximumPollCount: maximumPollCount,
                  maximumElapsedTicks: maximumElapsedTicks
              ), isHigh(
                  access.read32(at: gpioDataAddress),
                  mask: detectMask
              ) == detectPresentHigh
        else { return reject(.timedOut) }

        state = .ready
        return .ready
    }

    private mutating func delay(
        requiredTicks: UInt64,
        maximumPollCount: UInt64,
        maximumElapsedTicks: UInt64
    ) -> Bool {
        let startedAt = access.counterValue()
        var polls: UInt64 = 0
        while access.counterValue() &- startedAt < requiredTicks {
            guard polls < maximumPollCount,
                  access.counterValue() &- startedAt <= maximumElapsedTicks
            else { return false }
            polls += 1
            access.spinWaitHint()
        }
        return true
    }

    private mutating func reject(
        _ result: SDCardBoardPreparationResult
    ) -> SDCardBoardPreparationResult {
        state = .failed
        return result
    }

    private func isHigh(_ value: UInt32, mask: UInt32) -> Bool {
        value & mask != 0
    }

    private func setting(
        _ value: UInt32,
        mask: UInt32,
        high: Bool
    ) -> UInt32 {
        high ? value | mask : value & ~mask
    }

    private static func ticks(
        microseconds: UInt32,
        frequency: UInt64
    ) -> UInt64? {
        guard frequency > 0 else { return nil }
        let wholeSeconds = UInt64(microseconds / 1_000_000)
        let remainder = UInt64(microseconds % 1_000_000)
        guard wholeSeconds <= UInt64.max / frequency else { return nil }
        let wholeTicks = wholeSeconds * frequency
        let frequencyWhole = frequency / 1_000_000
        let frequencyRemainder = frequency % 1_000_000
        guard remainder == 0 || frequencyWhole <= UInt64.max / remainder else {
            return nil
        }
        let partialWhole = frequencyWhole * remainder
        let partialRemainder = frequencyRemainder * remainder
        let rounded = (partialRemainder + 999_999) / 1_000_000
        guard partialWhole <= UInt64.max - rounded,
              wholeTicks <= UInt64.max - partialWhole - rounded
        else { return nil }
        return wholeTicks + partialWhole + rounded
    }
}

struct BCM2712SDHCIMMIORegisterAccess: SDHCIRegisterAccess {
    private let baseAddress: UInt

    init?(description: PlatformStorageDeviceDescription) {
        let resource = description.hostRegisters
        guard description.controller == .bcm2712SDHCI,
              resource.baseAddress <= UInt64(UInt.max),
              resource.baseAddress & 3 == 0,
              resource.length >= 0x100,
              resource.length <= UInt64.max - resource.baseAddress,
              resource.length - 1 <= UInt64(UInt.max)
                  - resource.baseAddress
        else { return nil }
        self.baseAddress = UInt(resource.baseAddress)
    }

    @inline(__always)
    mutating func read8(at offset: UInt) -> UInt8 {
        MMIO.load8(at: baseAddress + offset)
    }

    @inline(__always)
    mutating func read16(at offset: UInt) -> UInt16 {
        MMIO.load16(at: baseAddress + offset)
    }

    @inline(__always)
    mutating func read32(at offset: UInt) -> UInt32 {
        MMIO.load32(at: baseAddress + offset)
    }

    @inline(__always)
    mutating func write8(_ value: UInt8, at offset: UInt) {
        MMIO.store8(value, at: baseAddress + offset)
    }

    @inline(__always)
    mutating func write16(_ value: UInt16, at offset: UInt) {
        MMIO.store16(value, at: baseAddress + offset)
    }

    @inline(__always)
    mutating func write32(_ value: UInt32, at offset: UInt) {
        MMIO.store32(value, at: baseAddress + offset)
    }

    @inline(__always)
    mutating func synchronizePostedWrites() {
        AArch64.synchronizeData()
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

typealias RaspberryPi5SDCardBlockDevice = SDHCIBlockDevice<
    BCM2712SDHCIMMIORegisterAccess,
    BCM2712SDCardBoardControl<BCM2712SDCardBoardMMIOAccess>
>

enum RaspberryPi5SDCardTransport {
    static func coldDevice(
        description: PlatformStorageDeviceDescription,
        maximumPollCount: UInt64 = 2_000_000
    ) -> RaspberryPi5SDCardBlockDevice? {
        let frequency = AArch64.counterFrequency
        guard frequency > 0,
              let registers = BCM2712SDHCIMMIORegisterAccess(
                  description: description
              ), let board = BCM2712SDCardBoardControl(
                  description: description,
                  access: BCM2712SDCardBoardMMIOAccess()
              ), let configuration = SDHCIDeviceConfiguration(
                  inputClockHertz: UInt64(description.inputClockHertz),
                  counterFrequency: frequency,
                  maximumPollCount: maximumPollCount,
                  commandTimeoutMilliseconds: 1_000,
                  initializationTimeoutMilliseconds: 2_000
              )
        else { return nil }
        return RaspberryPi5SDCardBlockDevice(
            registers: registers,
            board: board,
            configuration: configuration
        )
    }
}
