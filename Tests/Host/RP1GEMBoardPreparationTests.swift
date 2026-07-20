struct DeviceResource: Equatable {
    let baseAddress: UInt64
    let length: UInt64
}

enum PlatformNetworkPHYMode: UInt8, Equatable {
    case rgmiiID
}

struct PlatformNetworkPHYDescription: Equatable {
    let clause22Address: UInt32
    let mode: PlatformNetworkPHYMode
}

enum PlatformGPIOAssertedLevel: UInt8, Equatable {
    case high
    case low
}

struct RP1GPIORegisterResources: Equatable {
    let ioBank: DeviceResource
    let rio: DeviceResource
    let padsBank: DeviceResource
}

struct PlatformPHYResetDescription: Equatable {
    let gpioControllerPhandle: UInt32
    let gpioRegisters: RP1GPIORegisterResources
    let line: UInt32
    let assertedLevel: PlatformGPIOAssertedLevel
    let durationMilliseconds: UInt32
}

struct RP1GEMClockResources: Equatable {
    let controllerPhandle: UInt32
    let controllerRegisters: DeviceResource
    let peripheralClockID: UInt32
    let hostClockID: UInt32
    let timestampClockID: UInt32
    let transmitClockID: UInt32
}

struct PlatformMACAddressBytes: Equatable {
    let byte0: UInt8
    let byte1: UInt8
    let byte2: UInt8
    let byte3: UInt8
    let byte4: UInt8
    let byte5: UInt8

    var isAllZero: Bool {
        byte0 == 0 && byte1 == 0 && byte2 == 0 && byte3 == 0
            && byte4 == 0 && byte5 == 0
    }

    var isUsableUnicast: Bool {
        !isAllZero && byte0 & 1 == 0
    }
}

struct RP1GEMBoardResources: Equatable {
    let gemRegisters: DeviceResource
    let ethernetConfigurationRegisters: DeviceResource
    let clocks: RP1GEMClockResources
    let phy: PlatformNetworkPHYDescription
    let phyReset: PlatformPHYResetDescription?
    let localMACAddress: PlatformMACAddressBytes?
}

enum CadenceGEMBoardPreparationResult: UInt8, Equatable {
    case ready
    case timedOut
    case failed
}

protocol RP1GEMHardwarePreparation {
    mutating func prepareRP1Ethernet(
        maximumPollCount: UInt64
    ) -> CadenceGEMBoardPreparationResult
}

enum MMIO {
    static func load32(at address: UInt) -> UInt32 {
        UnsafeRawPointer(bitPattern: address)!.load(as: UInt32.self)
    }

    static func store32(_ value: UInt32, at address: UInt) {
        UnsafeMutableRawPointer(bitPattern: address)!.storeBytes(
            of: value,
            as: UInt32.self
        )
    }
}

enum AArch64 {
    static var counterFrequency: UInt64 { 1_000 }
    static var counterValue: UInt64 { 0 }
    static func synchronizeData() {}
    static func spinHint() {}
}

private enum TestRegisterEvent: Equatable {
    case read(UInt)
    case write(UInt, UInt32)
    case barrier
    case counterFrequency
    case counterValue
    case spin
}

private struct TestGPIOMap {
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

private struct DelayedClockSet {
    let value: UInt32
    var remainingReads: Int
}

private final class TestBoardAccess: RP1GEMBoardRegisterDelayAccess {
    var registers: [UInt: UInt32] = [:]
    var events: [TestRegisterEvent] = []
    var ignoredWriteAddresses: Set<UInt> = []
    var forcedReadValues: [UInt: UInt32] = [:]
    var clockSetVisibilityDelayReads: [UInt: Int] = [:]
    var pendingClockSets: [UInt: DelayedClockSet] = [:]
    var gpio: TestGPIOMap?
    var forceGPIOStatusFailure = false
    var frequency: UInt64 = 1_000
    var counter: UInt64 = 0
    var counterAdvancePerSpin: UInt64 = 1

    func read32(at address: UInt) -> UInt32 {
        events.append(.read(address))
        if let forced = forcedReadValues[address] { return forced }
        let clockSetBase = UInt(TestAddress.clocks + 0x2_000)
        let clockSetEnd = UInt(TestAddress.clocks + 0x3_000)
        let clockAddress = address >= clockSetBase && address < clockSetEnd
            ? address - 0x2_000 : address
        if var pending = pendingClockSets[clockAddress] {
            if pending.remainingReads == 0 {
                registers[clockAddress, default: 0] |= pending.value
                pendingClockSets[clockAddress] = nil
            } else {
                pending.remainingReads -= 1
                pendingClockSets[clockAddress] = pending
            }
        }
        if let gpio, address == gpio.status {
            if forceGPIOStatusFailure { return 0 }
            var status: UInt32 = 0
            let control = registers[gpio.control, default: 0]
            let pad = registers[gpio.padControl, default: 0]
            let outputEnabled = registers[gpio.outputEnable, default: 0]
                & gpio.mask != 0
            let systemRIOSelected = control
                & RP1GEMBoardRegisterLayout.functionSelectMask
                == RP1GEMBoardRegisterLayout.systemRIOFunction
                && control & RP1GEMBoardRegisterLayout.outputOverrideMask == 0
                && control
                    & RP1GEMBoardRegisterLayout.outputEnableOverrideMask == 0
            if outputEnabled && systemRIOSelected
                && pad & RP1GEMBoardRegisterLayout.padOutputDisable == 0 {
                status |= RP1GEMBoardRegisterLayout.outputEnabledToPad
            }
            if registers[gpio.output, default: 0] & gpio.mask != 0 {
                status |= RP1GEMBoardRegisterLayout.outputValueToPad
            }
            return status
        }
        return registers[clockAddress, default: 0]
    }

    func write32(_ value: UInt32, at address: UInt) {
        events.append(.write(address, value))
        guard !ignoredWriteAddresses.contains(address) else { return }
        let clockSetBase = UInt(TestAddress.clocks + 0x2_000)
        let clockSetEnd = UInt(TestAddress.clocks + 0x3_000)
        if address >= clockSetBase && address < clockSetEnd {
            let clockAddress = address - 0x2_000
            let delay = clockSetVisibilityDelayReads[clockAddress, default: 0]
            if delay > 0 {
                pendingClockSets[clockAddress] = DelayedClockSet(
                    value: value,
                    remainingReads: delay
                )
            } else {
                registers[clockAddress, default: 0] |= value
            }
            return
        }
        if let gpio {
            switch address {
            case gpio.outputSet:
                registers[gpio.output, default: 0] |= value
                return
            case gpio.outputClear:
                registers[gpio.output, default: 0] &= ~value
                return
            case gpio.outputEnableSet:
                registers[gpio.outputEnable, default: 0] |= value
                return
            case gpio.padOutputDisableClear:
                registers[gpio.padControl, default: 0] &= ~value
                return
            default:
                break
            }
        }
        registers[address] = value
    }

    func synchronizePostedWrites() {
        events.append(.barrier)
    }

    func counterFrequency() -> UInt64 {
        events.append(.counterFrequency)
        return frequency
    }

    func counterValue() -> UInt64 {
        events.append(.counterValue)
        return counter
    }

    func spinWaitHint() {
        events.append(.spin)
        counter &+= counterAdvancePerSpin
    }
}

private enum TestAddress {
    static let gem: UInt64 = 0x0010_0000
    static let clocks: UInt64 = 0x0020_0000
    static let io: UInt64 = 0x0030_0000
    static let rio: UInt64 = io + 0x1_0000
    static let pads: UInt64 = io + 0x2_0000
}

private struct GPIOBoundary {
    let line: UInt32
    let bank: UInt64
    let localLine: UInt64
}

private let emptySystemClockSnapshot = RP1GEMSystemClockSnapshot(
    control: 0,
    dividerInteger: 0,
    selection: 0,
    pllControlStatus: 0,
    pllPower: 0,
    pllPrimary: 0,
    pllSecondary: 0
)

@main
struct RP1GEMBoardPreparationTests {
    static func main() {
        preservesStableDiagnosticStageValues()
        enablesExactClocksAndPreservesFields()
        provesBoundedClockEnablePaths()
        resetsActiveLowGPIO32WithoutOutputGlitches()
        resetsActiveHighGPIO53AndMapsEveryBankBoundary()
        rejectsMalformedResourcesBeforeTouchingHardware()
        reportsReadbackAndBoundedCounterFailures()
        preparesExactlyOnceAndRetriesIncompleteAttempts()
        exercisesConcreteMMIOAccess()
        print("RP1 GEM board preparation: 9 groups passed")
    }

    private static func preservesStableDiagnosticStageValues() {
        let stages: [RP1GEMBoardPreparationStage] = [
            .invalidConfiguration,
            .systemClockEnable,
            .ethernetClockEnable,
            .timestampClockEnable,
            .phyResetGPIOLayout,
            .phyResetAssertOutput,
            .phyResetOutputEnable,
            .phyResetFunctionSelect,
            .phyResetPadOutput,
            .phyResetAssertStatus,
            .phyResetDelayCounter,
            .phyResetDelayTimeout,
            .phyResetDeassertOutput,
            .phyResetDeassertStatus,
        ]
        expect(
            stages.map(\.rawValue) == Array(UInt8(1)...UInt8(14)),
            "persistent diagnostic stage raw values drifted"
        )
        expect(
            [
                RP1GEMClockEnableMethod.none,
                .alreadyEnabled,
                .atomicSet,
                .normalReadModifyWrite,
            ].map(\.rawValue) == [0, 1, 2, 3],
            "persistent clock method raw values drifted"
        )
        expect(
            [
                RP1GEMClockEnableResult.ready,
                .aliasMismatch,
                .boundedFailure,
            ].map(\.rawValue) == [1, 2, 3],
            "persistent clock result raw values drifted"
        )
    }

    private static func enablesExactClocksAndPreservesFields() {
        let access = TestBoardAccess()
        let resources = makeResources(resetLine: nil)
        let system = UInt(TestAddress.clocks + 0x014)
        let ethernet = UInt(TestAddress.clocks + 0x064)
        let timestamp = UInt(TestAddress.clocks + 0x134)
        let systemSet = system + 0x2_000
        let ethernetSet = ethernet + 0x2_000
        let timestampSet = timestamp + 0x2_000
        access.registers[system] = 0x0101_0003
        access.registers[UInt(TestAddress.clocks + 0x018)] = 5
        access.registers[UInt(TestAddress.clocks + 0x020)] = 4
        access.registers[UInt(TestAddress.clocks + 0x8_000)] = 0x8000_0001
        access.registers[UInt(TestAddress.clocks + 0x8_004)] = 2
        access.registers[UInt(TestAddress.clocks + 0x8_010)] = 3
        access.registers[UInt(TestAddress.clocks + 0x8_014)] = 4
        access.registers[ethernet] = 0x0202_0005
        access.registers[timestamp] = 0x0404_0007
        var preparation = RP1GEMBoardPreparation(
            resources: resources,
            access: access
        )

        expect(
            preparation.prepareRP1Ethernet(maximumPollCount: 8) == .ready,
            "valid clock-only board preparation failed"
        )
        expect(
            writeEvents(in: access.events) == [
                .write(systemSet, 0x0000_0800),
                .write(ethernetSet, 0x0000_0800),
                .write(timestampSet, 0x0000_0800),
            ],
            "atomic clock enable write order changed"
        )
        expect(
            count(.barrier, in: access.events) == 3
                && access.events.contains(.read(systemSet))
                && access.events.contains(.read(ethernetSet))
                && access.events.contains(.read(timestampSet)),
            "atomic alias drain or barrier was omitted"
        )
        expect(
            access.registers[system] == 0x0101_0803
                && access.registers[ethernet] == 0x0202_0805
                && access.registers[timestamp] == 0x0404_0807,
            "clock programming did not preserve non-ENABLE fields"
        )
        expect(
            preparation.clockDiagnostics.timestamp
                == RP1GEMClockEnableDiagnostic(
                    stage: .timestampClockEnable,
                    method: .atomicSet,
                    result: .ready,
                    initialControl: 0x0404_0007,
                    initialSetAlias: 0x0404_0007,
                    atomicDrain: 0x0404_0807,
                    finalControl: 0x0404_0807,
                    pollCount: 1,
                    elapsedTicks: 0,
                    system: RP1GEMSystemClockSnapshot(
                        control: 0x0101_0003,
                        dividerInteger: 5,
                        selection: 4,
                        pllControlStatus: 0x8000_0001,
                        pllPower: 2,
                        pllPrimary: 3,
                        pllSecondary: 4
                    )
                ),
            "clock telemetry lost method, readback, or SYS/PLL snapshot"
        )

        expectInvalidClockIDs(
            makeResources(resetLine: nil, peripheralClockID: 11),
            "non-SYS peripheral clock accepted"
        )
        expectInvalidClockIDs(
            makeResources(resetLine: nil, hostClockID: 13),
            "non-SYS host clock accepted"
        )
        expectInvalidClockIDs(
            makeResources(resetLine: nil, timestampClockID: 28),
            "non-ETH_TSU timestamp clock accepted"
        )
        expectInvalidClockIDs(
            makeResources(resetLine: nil, transmitClockID: 15),
            "non-ETH transmit clock accepted"
        )
    }

    private static func provesBoundedClockEnablePaths() {
        do {
            let access = TestBoardAccess()
            let timestamp = UInt(TestAddress.clocks + 0x134)
            access.registers[timestamp] = 2
            access.clockSetVisibilityDelayReads[timestamp] = 2
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: nil),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 8) == .ready,
                "delayed atomic SET visibility failed"
            )
            expect(
                preparation.clockDiagnostics.timestamp
                    == RP1GEMClockEnableDiagnostic(
                        stage: .timestampClockEnable,
                        method: .atomicSet,
                        result: .ready,
                        initialControl: 2,
                        initialSetAlias: 2,
                        atomicDrain: 2,
                        finalControl: 0x802,
                        pollCount: 2,
                        elapsedTicks: 1,
                        system: emptySystemClockSnapshot
                    ),
                "delayed atomic success telemetry is incorrect"
            )
            expect(
                !writeEvents(in: access.events).contains(
                    .write(timestamp, 0x802)
                ),
                "delayed atomic success unnecessarily used normal fallback"
            )
        }

        do {
            let access = TestBoardAccess()
            let system = UInt(TestAddress.clocks + 0x014)
            let systemSet = system + 0x2_000
            access.registers[system] = 0x802
            access.forcedReadValues[systemSet] = 0
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: nil),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 8) == .ready,
                "enabled normal CTRL was rejected when SET alias read zero"
            )
            let writes = writeEvents(in: access.events)
            expect(
                !writes.contains(.write(systemSet, 0x800))
                    && !writes.contains(.write(system, 0x802)),
                "already-enabled clock wrote through a divergent SET alias"
            )
            expect(
                preparation.clockDiagnostics.system
                    == RP1GEMClockEnableDiagnostic(
                        stage: .systemClockEnable,
                        method: .alreadyEnabled,
                        result: .ready,
                        initialControl: 0x802,
                        initialSetAlias: 0,
                        atomicDrain: 0,
                        finalControl: 0x802,
                        pollCount: 0,
                        elapsedTicks: 0,
                        system: RP1GEMSystemClockSnapshot(
                            control: 0x802,
                            dividerInteger: 0,
                            selection: 0,
                            pllControlStatus: 0,
                            pllPower: 0,
                            pllPrimary: 0,
                            pllSecondary: 0
                        )
                    ),
                "already-enabled divergent-alias telemetry is incorrect"
            )
        }

        do {
            let access = TestBoardAccess()
            let system = UInt(TestAddress.clocks + 0x014)
            let systemSet = system + 0x2_000
            access.registers[system] = 2
            // Returned Pi 5 media proved that the normal CTRL register can
            // read 0x2 while the SET alias reads zero. The alias observation
            // must not prevent the documented normal-register fallback.
            access.forcedReadValues[systemSet] = 0
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: nil),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 8) == .ready,
                "normal RMW fallback did not recover an ignored SET"
            )
            expect(
                writeEvents(in: access.events).contains(
                    .write(system, 0x802)
                ) && !writeEvents(in: access.events).contains(
                    .write(systemSet, 0x800)
                ),
                "divergent alias was written or normal RMW lost CTRL fields"
            )
            expect(
                preparation.clockDiagnostics.system
                    == RP1GEMClockEnableDiagnostic(
                        stage: .systemClockEnable,
                        method: .normalReadModifyWrite,
                        result: .ready,
                        initialControl: 2,
                        initialSetAlias: 0,
                        atomicDrain: 0,
                        finalControl: 0x802,
                        pollCount: 1,
                        elapsedTicks: 0,
                        system: RP1GEMSystemClockSnapshot(
                            control: 2,
                            dividerInteger: 0,
                            selection: 0,
                            pllControlStatus: 0,
                            pllPower: 0,
                            pllPrimary: 0,
                            pllSecondary: 0
                        )
                    ),
                "normal fallback success was lost after later clocks"
            )
            expect(
                preparation.clockDiagnostics.ethernet?.stage
                    == .ethernetClockEnable
                    && preparation.clockDiagnostics.timestamp?.stage
                        == .timestampClockEnable,
                "later successful clocks did not retain their own telemetry"
            )
        }

        do {
            let access = TestBoardAccess()
            let system = UInt(TestAddress.clocks + 0x014)
            let systemSet = system + 0x2_000
            access.registers[system] = 2
            access.ignoredWriteAddresses.insert(systemSet)
            access.ignoredWriteAddresses.insert(system)
            access.frequency = 0
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: nil),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 2) == .failed,
                "ignored SET and normal writes did not fail closed"
            )
            expect(
                preparation.lastDiagnostic
                    == RP1GEMBoardPreparationDiagnostic(
                        stage: .systemClockEnable,
                        registerAddress: UInt64(system),
                        expectedValue: 0x800,
                        observedValue: 2
                    ),
                "bounded clock failure lost the stable board diagnostic"
            )
            expect(
                preparation.clockDiagnostics.system
                    == RP1GEMClockEnableDiagnostic(
                        stage: .systemClockEnable,
                        method: .normalReadModifyWrite,
                        result: .boundedFailure,
                        initialControl: 2,
                        initialSetAlias: 2,
                        atomicDrain: 2,
                        finalControl: 2,
                        pollCount: 4,
                        elapsedTicks: 0,
                        system: RP1GEMSystemClockSnapshot(
                            control: 2,
                            dividerInteger: 0,
                            selection: 0,
                            pllControlStatus: 0,
                            pllPower: 0,
                            pllPrimary: 0,
                            pllSecondary: 0
                        )
                    ),
                "bounded clock failure telemetry is incorrect"
            )
            expect(
                count(.spin, in: access.events) == 2
                    && count(.counterValue, in: access.events) == 0,
                "clock failure exceeded its counter-independent read cap"
            )
        }

        do {
            let access = TestBoardAccess()
            let system = UInt(TestAddress.clocks + 0x014)
            let systemSet = system + 0x2_000
            access.registers[system] = 2
            access.forcedReadValues[systemSet] = 0
            access.ignoredWriteAddresses.insert(system)
            access.frequency = 0
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: nil),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 2) == .failed,
                "ignored normal write did not fail closed after alias skip"
            )
            expect(
                preparation.clockDiagnostics.system
                    == RP1GEMClockEnableDiagnostic(
                        stage: .systemClockEnable,
                        method: .normalReadModifyWrite,
                        result: .boundedFailure,
                        initialControl: 2,
                        initialSetAlias: 0,
                        atomicDrain: 0,
                        finalControl: 2,
                        pollCount: 2,
                        elapsedTicks: 0,
                        system: RP1GEMSystemClockSnapshot(
                            control: 2,
                            dividerInteger: 0,
                            selection: 0,
                            pllControlStatus: 0,
                            pllPower: 0,
                            pllPrimary: 0,
                            pllSecondary: 0
                        )
                    ),
                "divergent-alias bounded failure telemetry is incorrect"
            )
            expect(
                !writeEvents(in: access.events).contains(
                    .write(systemSet, 0x800)
                ) && count(.spin, in: access.events) == 1,
                "alias-skip failure wrote the alias or exceeded its read cap"
            )
        }
    }

    private static func resetsActiveLowGPIO32WithoutOutputGlitches() {
        let access = TestBoardAccess()
        let resources = makeResources(
            resetLine: 32,
            assertedLevel: .low,
            durationMilliseconds: 5
        )
        let gpio = gpioMap(line: 32)
        access.gpio = gpio
        let initialControl: UInt32 = 0xa5a5_f0ff
        let initialPad: UInt32 = 0x0000_00db
        access.registers[gpio.control] = initialControl
        access.registers[gpio.padControl] = initialPad
        var preparation = RP1GEMBoardPreparation(
            resources: resources,
            access: access
        )

        expect(
            preparation.prepareRP1Ethernet(maximumPollCount: 8) == .ready,
            "active-low GPIO32 PHY reset failed"
        )
        expect(
            gpio.status == UInt(TestAddress.io + 0x4_020)
                && gpio.control == UInt(TestAddress.io + 0x4_024)
                && gpio.outputClear == UInt(TestAddress.rio + 0x7_000)
                && gpio.outputEnableSet
                    == UInt(TestAddress.rio + 0x6_004)
                && gpio.padOutputDisableClear
                    == UInt(TestAddress.pads + 0x7_014)
                && gpio.mask == 1 << 4,
            "GPIO32 was not mapped as bank 1 local line 4"
        )
        let writes = writeEvents(in: access.events)
        expect(
            Array(writes.suffix(5)) == [
                .write(gpio.outputClear, gpio.mask),
                .write(gpio.outputEnableSet, gpio.mask),
                .write(
                    gpio.control,
                    initialControl & ~UInt32(0xf01f) | 5
                ),
                .write(
                    gpio.padOutputDisableClear,
                    RP1GEMBoardRegisterLayout.padOutputDisable
                ),
                .write(gpio.outputSet, gpio.mask),
            ],
            "GPIO32 reset write order changed"
        )
        let selectedControl = access.registers[gpio.control, default: 0]
        expect(
            selectedControl == initialControl & ~UInt32(0xf01f) | 5,
            "SYS_RIO selection did not clear FUNCSEL/OUTOVER/OEOVER residue"
        )
        expect(
            access.registers[gpio.padControl]
                == initialPad
                    & ~RP1GEMBoardRegisterLayout.padOutputDisable,
            "pad output-enable programming changed unrelated pad fields"
        )
        expect(
            count(.barrier, in: access.events) == writes.count,
            "one or more posted writes lacked a barrier/readback sequence"
        )
        expect(
            count(.spin, in: access.events) == 5,
            "5-ms reset did not use five 1-kHz architectural-counter ticks"
        )
        expect(
            access.registers[gpio.output, default: 0] & gpio.mask != 0,
            "active-low PHY was not deasserted high"
        )
    }

    private static func resetsActiveHighGPIO53AndMapsEveryBankBoundary() {
        let access = TestBoardAccess()
        let resources = makeResources(
            resetLine: 53,
            assertedLevel: .high,
            durationMilliseconds: 1
        )
        let gpio = gpioMap(line: 53)
        access.gpio = gpio
        access.registers[gpio.control] = 0xffff_ffff
        access.registers[gpio.padControl] = 0xff
        var preparation = RP1GEMBoardPreparation(
            resources: resources,
            access: access
        )
        expect(
            preparation.prepareRP1Ethernet(maximumPollCount: 2) == .ready,
            "active-high GPIO53 PHY reset failed"
        )
        let writes = writeEvents(in: access.events)
        expect(
            writes[3] == .write(gpio.outputSet, 1 << 19)
                && writes.last == .write(gpio.outputClear, 1 << 19),
            "active-high reset polarity was inverted"
        )

        let boundaries = [
            GPIOBoundary(line: 0, bank: 0, localLine: 0),
            GPIOBoundary(line: 27, bank: 0, localLine: 27),
            GPIOBoundary(line: 28, bank: 1, localLine: 0),
            GPIOBoundary(line: 33, bank: 1, localLine: 5),
            GPIOBoundary(line: 34, bank: 2, localLine: 0),
            GPIOBoundary(line: 53, bank: 2, localLine: 19),
        ]
        for boundary in boundaries {
            let mapped = gpioMap(line: boundary.line)
            let bankOffset = boundary.bank * 0x4_000
            expect(
                mapped.status == UInt(
                    TestAddress.io + bankOffset
                        + boundary.localLine * 8
                )
                    && mapped.control == UInt(
                        TestAddress.io + bankOffset
                            + boundary.localLine * 8 + 4
                    )
                    && mapped.padControl == UInt(
                        TestAddress.pads + bankOffset
                            + 4 + boundary.localLine * 4
                ),
                "GPIO bank boundary mapping is incorrect"
            )
            let boundaryAccess = TestBoardAccess()
            boundaryAccess.gpio = mapped
            boundaryAccess.registers[mapped.control] = 0xf01f
            boundaryAccess.registers[mapped.padControl] = 0xff
            var boundaryPreparation = RP1GEMBoardPreparation(
                resources: makeResources(
                    resetLine: boundary.line,
                    durationMilliseconds: 1
                ),
                access: boundaryAccess
            )
            expect(
                boundaryPreparation.prepareRP1Ethernet(
                    maximumPollCount: 2
                ) == .ready,
                "production GPIO selection rejected a valid bank boundary"
            )
            let boundaryWrites = writeEvents(in: boundaryAccess.events)
            expect(
                boundaryWrites[3] == .write(mapped.outputClear, mapped.mask),
                "production GPIO selection used the wrong bank/local line"
            )
        }
    }

    private static func rejectsMalformedResourcesBeforeTouchingHardware() {
        expectRejected(
            makeResources(resetLine: 54),
            "GPIO line 54 accepted",
            expectedStage: .phyResetGPIOLayout
        )
        expectRejected(
            makeResources(resetLine: 32, durationMilliseconds: 0),
            "zero PHY reset duration accepted"
        )
        expectRejected(
            makeResources(resetLine: 32, durationMilliseconds: 1_001),
            "PHY reset duration above 1000 ms accepted"
        )
        expectRejected(
            makeResources(resetLine: 32, gpioLength: 0x8_000),
            "short aggregate GPIO resources accepted",
            expectedStage: .phyResetGPIOLayout
        )
        expectRejected(
            makeResources(resetLine: 32, rioBaseAddress: TestAddress.rio + 4),
            "noncontiguous RP1 GPIO resources accepted",
            expectedStage: .phyResetGPIOLayout
        )
        expectRejected(
            makeResources(resetLine: nil, clockLength: 0x2_134),
            "clock aperture missing ETH_TSU atomic SET register accepted"
        )
        expectRejected(
            makeResources(resetLine: nil, clockLength: 0x8_014),
            "clock aperture missing PLL_SYS_SEC snapshot register accepted"
        )
        expectRejected(
            makeResources(resetLine: nil, clockControllerPhandle: 0),
            "zero clock-controller phandle accepted"
        )
        expectRejected(
            makeResources(resetLine: nil, gemLength: 0x3_000),
            "short GEM aperture accepted"
        )
        expectRejected(
            makeResources(
                resetLine: nil,
                localMACAddress: PlatformMACAddressBytes(
                    byte0: 1,
                    byte1: 2,
                    byte2: 3,
                    byte3: 4,
                    byte4: 5,
                    byte5: 6
                )
            ),
            "multicast firmware MAC accepted"
        )

        let access = TestBoardAccess()
        var preparation = RP1GEMBoardPreparation(
            resources: makeResources(resetLine: nil),
            access: access
        )
        expect(
            preparation.prepareRP1Ethernet(maximumPollCount: 0) == .failed
                && access.events.isEmpty,
            "zero poll bound touched hardware"
        )
        expect(
            preparation.lastDiagnostic
                == RP1GEMBoardPreparationDiagnostic(
                    stage: .invalidConfiguration,
                    registerAddress: 0,
                    expectedValue: 1,
                    observedValue: 0
                ),
            "zero poll bound lost its typed diagnostic"
        )
    }

    private static func reportsReadbackAndBoundedCounterFailures() {
        do {
            let access = TestBoardAccess()
            let ethernet = UInt(TestAddress.clocks + 0x064)
            access.forcedReadValues[ethernet] = 0
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: nil),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 4) == .failed,
                "missing clock ENABLE readback accepted"
            )
            expect(
                preparation.lastDiagnostic
                    == RP1GEMBoardPreparationDiagnostic(
                        stage: .ethernetClockEnable,
                        registerAddress: UInt64(ethernet),
                        expectedValue: UInt64(
                            RP1GEMBoardRegisterLayout.clockEnable
                        ),
                        observedValue: 0
                    ),
                "clock readback failure lost address/value diagnostics"
            )
            expect(
                !access.events.contains(
                    .read(UInt(TestAddress.clocks + 0x134))
                ),
                "clock failure did not stop before ETH_TSU"
            )
        }

        do {
            let access = resetAccess(line: 32)
            let gpio = gpioMap(line: 32)
            access.registers[gpio.output] = gpio.mask
            access.ignoredWriteAddresses.insert(gpio.outputClear)
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: 32),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 4) == .failed
                    && count(.counterFrequency, in: access.events) == 3,
                "GPIO output readback failure reached the delay"
            )
            expect(
                preparation.lastDiagnostic
                    == RP1GEMBoardPreparationDiagnostic(
                        stage: .phyResetAssertOutput,
                        registerAddress: UInt64(gpio.output),
                        expectedValue: 0,
                        observedValue: UInt64(gpio.mask)
                    ),
                "GPIO output failure lost its exact readback"
            )
        }

        do {
            let access = resetAccess(line: 32)
            access.forceGPIOStatusFailure = true
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: 32),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 4) == .failed
                    && count(.counterFrequency, in: access.events) == 3,
                "invalid GPIO status reached the reset delay"
            )
            let gpio = gpioMap(line: 32)
            expect(
                preparation.lastDiagnostic
                    == RP1GEMBoardPreparationDiagnostic(
                        stage: .phyResetAssertStatus,
                        registerAddress: UInt64(gpio.status),
                        expectedValue: UInt64(
                            RP1GEMBoardRegisterLayout.outputEnabledToPad
                        ),
                        observedValue: 0
                    ),
                "GPIO status failure lost its pad-state diagnostic"
            )
        }

        do {
            let access = resetAccess(line: 32)
            access.counterAdvancePerSpin = 0
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: 32),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 3)
                    == .timedOut,
                "stopped counter did not time out"
            )
            expect(
                count(.spin, in: access.events) == 3,
                "counter timeout exceeded its caller-supplied poll bound"
            )
            expect(
                preparation.lastDiagnostic
                    == RP1GEMBoardPreparationDiagnostic(
                        stage: .phyResetDelayTimeout,
                        registerAddress: 0,
                        expectedValue: 5,
                        observedValue: 0
                    ),
                "reset timeout lost required/elapsed counter ticks"
            )
            let gpio = gpioMap(line: 32)
            expect(
                !writeEvents(in: access.events).contains(
                    .write(gpio.outputSet, gpio.mask)
                ),
                "timed-out active-low reset was unsafely deasserted"
            )
        }

        do {
            let access = resetAccess(line: 32)
            access.frequency = 0
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: 32),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 3) == .failed
                    && count(.spin, in: access.events) == 0,
                "invalid architectural-counter frequency was not rejected"
            )
            expect(
                preparation.lastDiagnostic
                    == RP1GEMBoardPreparationDiagnostic(
                        stage: .phyResetDelayCounter,
                        registerAddress: 0,
                        expectedValue: 5,
                        observedValue: 0
                    ),
                "invalid counter lost reset-delay diagnostics"
            )
        }
    }

    private static func preparesExactlyOnceAndRetriesIncompleteAttempts() {
        do {
            let access = resetAccess(line: 32)
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(
                    resetLine: 32,
                    durationMilliseconds: 1
                ),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 2) == .ready,
                "first board preparation did not complete"
            )
            let completedEvents = access.events
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 0) == .ready
                    && access.events == completedEvents,
                "completed board preparation touched hardware a second time"
            )
        }

        do {
            let access = TestBoardAccess()
            let ethernet = UInt(TestAddress.clocks + 0x064)
            access.forcedReadValues[ethernet] = 0
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(resetLine: nil),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 2) == .failed,
                "clock readback failure did not fail preparation"
            )
            let failedEventCount = access.events.count
            access.forcedReadValues[ethernet] = nil
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 2) == .ready
                    && access.events.count > failedEventCount,
                "failed board preparation was incorrectly latched ready"
            )
        }

        do {
            let access = resetAccess(line: 32)
            access.counterAdvancePerSpin = 0
            var preparation = RP1GEMBoardPreparation(
                resources: makeResources(
                    resetLine: 32,
                    durationMilliseconds: 1
                ),
                access: access
            )
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 1)
                    == .timedOut,
                "stopped counter did not time out preparation"
            )
            let gpio = gpioMap(line: 32)
            expect(
                access.registers[gpio.output, default: 0] & gpio.mask == 0,
                "timed-out active-low reset was not left asserted"
            )
            let timedOutEventCount = access.events.count
            access.counterAdvancePerSpin = 1
            expect(
                preparation.prepareRP1Ethernet(maximumPollCount: 2) == .ready
                    && access.events.count > timedOutEventCount,
                "timed-out board preparation was incorrectly latched ready"
            )
            expect(
                access.registers[gpio.output, default: 0] & gpio.mask != 0,
                "successful retry did not deassert active-low reset"
            )
        }
    }

    private static func exercisesConcreteMMIOAccess() {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: 4,
            alignment: 4
        )
        defer { pointer.deallocate() }
        pointer.storeBytes(of: UInt32(0), as: UInt32.self)
        var access = RP1GEMBoardMMIOAccess()
        let address = UInt(bitPattern: pointer)
        access.write32(0x5357_4946, at: address)
        access.synchronizePostedWrites()
        expect(
            access.read32(at: address) == 0x5357_4946
                && access.counterFrequency() == 1_000,
            "concrete volatile RP1 board access failed"
        )
    }

    private static func expectInvalidClockIDs(
        _ resources: RP1GEMBoardResources,
        _ message: StaticString
    ) {
        expectRejected(resources, message)
    }

    private static func expectRejected(
        _ resources: RP1GEMBoardResources,
        _ message: StaticString,
        expectedStage: RP1GEMBoardPreparationStage = .invalidConfiguration
    ) {
        let access = TestBoardAccess()
        var preparation = RP1GEMBoardPreparation(
            resources: resources,
            access: access
        )
        expect(
            preparation.prepareRP1Ethernet(maximumPollCount: 8) == .failed
                && access.events.isEmpty
                && preparation.lastDiagnostic
                    == RP1GEMBoardPreparationDiagnostic(
                        stage: expectedStage,
                        registerAddress: 0,
                        expectedValue: 0,
                        observedValue: 0
                    ),
            message
        )
    }

    private static func resetAccess(line: UInt32) -> TestBoardAccess {
        let access = TestBoardAccess()
        let gpio = gpioMap(line: line)
        access.gpio = gpio
        access.registers[gpio.control] = 0xf01f
        access.registers[gpio.padControl] = 0xff
        return access
    }

    private static func gpioMap(line: UInt32) -> TestGPIOMap {
        let bank: UInt64
        let localLine: UInt64
        switch line {
        case 0...27:
            bank = 0
            localLine = UInt64(line)
        case 28...33:
            bank = 1
            localLine = UInt64(line - 28)
        default:
            bank = 2
            localLine = UInt64(line - 34)
        }
        let bankOffset = bank * 0x4_000
        let statusOffset = bankOffset + localLine * 8
        let padOffset = bankOffset + 4 + localLine * 4
        let outputOffset = bankOffset
        let outputEnableOffset = bankOffset + 4
        return TestGPIOMap(
            status: UInt(TestAddress.io + statusOffset),
            control: UInt(TestAddress.io + statusOffset + 4),
            output: UInt(TestAddress.rio + outputOffset),
            outputSet: UInt(TestAddress.rio + outputOffset + 0x2_000),
            outputClear: UInt(TestAddress.rio + outputOffset + 0x3_000),
            outputEnable: UInt(TestAddress.rio + outputEnableOffset),
            outputEnableSet: UInt(
                TestAddress.rio + outputEnableOffset + 0x2_000
            ),
            padControl: UInt(TestAddress.pads + padOffset),
            padOutputDisableClear: UInt(
                TestAddress.pads + padOffset + 0x3_000
            ),
            mask: UInt32(1) << UInt32(localLine)
        )
    }

    private static func makeResources(
        resetLine: UInt32?,
        assertedLevel: PlatformGPIOAssertedLevel = .low,
        durationMilliseconds: UInt32 = 5,
        peripheralClockID: UInt32 = 12,
        hostClockID: UInt32 = 12,
        timestampClockID: UInt32 = 29,
        transmitClockID: UInt32 = 16,
        clockControllerPhandle: UInt32 = 2,
        clockLength: UInt64 = 0x1_0038,
        gpioLength: UInt64 = 0xc_000,
        rioBaseAddress: UInt64 = TestAddress.rio,
        gemLength: UInt64 = 0x4_000,
        localMACAddress: PlatformMACAddressBytes? = PlatformMACAddressBytes(
            byte0: 0,
            byte1: 0,
            byte2: 0,
            byte3: 0,
            byte4: 0,
            byte5: 0
        )
    ) -> RP1GEMBoardResources {
        let reset = resetLine.map {
            PlatformPHYResetDescription(
                gpioControllerPhandle: 0x2e,
                gpioRegisters: RP1GPIORegisterResources(
                    ioBank: DeviceResource(
                        baseAddress: TestAddress.io,
                        length: gpioLength
                    ),
                    rio: DeviceResource(
                        baseAddress: rioBaseAddress,
                        length: gpioLength
                    ),
                    padsBank: DeviceResource(
                        baseAddress: TestAddress.pads,
                        length: gpioLength
                    )
                ),
                line: $0,
                assertedLevel: assertedLevel,
                durationMilliseconds: durationMilliseconds
            )
        }
        return RP1GEMBoardResources(
            gemRegisters: DeviceResource(
                baseAddress: TestAddress.gem,
                length: gemLength
            ),
            ethernetConfigurationRegisters: DeviceResource(
                baseAddress: TestAddress.gem + 0x4_000,
                length: 0x4_000
            ),
            clocks: RP1GEMClockResources(
                controllerPhandle: clockControllerPhandle,
                controllerRegisters: DeviceResource(
                    baseAddress: TestAddress.clocks,
                    length: clockLength
                ),
                peripheralClockID: peripheralClockID,
                hostClockID: hostClockID,
                timestampClockID: timestampClockID,
                transmitClockID: transmitClockID
            ),
            phy: PlatformNetworkPHYDescription(
                clause22Address: 1,
                mode: .rgmiiID
            ),
            phyReset: reset,
            localMACAddress: localMACAddress
        )
    }

    private static func writeEvents(
        in events: [TestRegisterEvent]
    ) -> [TestRegisterEvent] {
        events.filter {
            if case .write = $0 { return true }
            return false
        }
    }

    private static func count(
        _ expected: TestRegisterEvent,
        in events: [TestRegisterEvent]
    ) -> Int {
        events.reduce(into: 0) { result, event in
            if event == expected { result += 1 }
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("RP1 GEM board preparation host test failed: \(message)")
    }
}
