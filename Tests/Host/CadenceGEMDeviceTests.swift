// Minimal host stand-ins used only to compile the concrete RP1 access layer.
// The core driver tests below use deterministic register and DMA protocols.
struct DeviceResource {
    let baseAddress: UInt64
    let length: UInt64
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
    static func spinHint() {}
    static func synchronizeData() {}
    static func cleanDataCache(address: UInt64, byteCount: UInt64) -> Bool {
        address > 0 && byteCount > 0
    }
    static func invalidateDataCache(address: UInt64, byteCount: UInt64) -> Bool {
        address > 0 && byteCount > 0
    }
}

private final class TestAllocation {
    let pointer: UnsafeMutableRawPointer
    let byteCount: Int

    init(byteCount: Int, alignment: Int = 64) {
        self.byteCount = byteCount
        pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    }

    deinit {
        pointer.deallocate()
    }

    var address: UInt64 {
        UInt64(UInt(bitPattern: pointer))
    }
}

private final class TestHardware {
    var registerValues: [UInt: UInt32] = [
        CadenceGEMRegisterLayout.networkStatus: 1 << 2,
        CadenceGEMRegisterLayout.networkConfiguration: 0,
        CadenceGEMRegisterLayout.dmaConfiguration: 0,
    ]
    var phyRegisters: [UInt8: UInt16] = [
        1: (1 << 5) | (1 << 2),
        2: 0x600d,
        3: 0x8421,
    ]
    var writes: [(UInt, UInt32)] = []
    var events: [String] = []
    var mdioStuck = false
    var completeTransmit = true
    var transmitErrorMask: UInt32 = 0
    var transmitStatusErrorMask: UInt32 = 0
    var transmitDescriptorCPUAddress: UInt64 = 0
    var transmitDescriptorCount: UInt16 = 2
    var transmitCompletionIndex: UInt16 = 0
    var spinCount = 0

    func read32(at offset: UInt) -> UInt32 {
        if offset == CadenceGEMRegisterLayout.networkStatus && mdioStuck {
            return 0
        }
        return registerValues[offset, default: 0]
    }

    func write32(_ value: UInt32, at offset: UInt) {
        writes.append((offset, value))
        if offset == CadenceGEMRegisterLayout.transmitStatus
            || offset == CadenceGEMRegisterLayout.receiveStatus {
            registerValues[offset, default: 0] &= ~value
        } else {
            registerValues[offset] = value
        }
        if offset == CadenceGEMRegisterLayout.phyMaintenance {
            let operation = UInt8(truncatingIfNeeded: value >> 28) & 3
            let register = UInt8(truncatingIfNeeded: value >> 18) & 0x1f
            if operation == 2 {
                registerValues[offset] = value & 0xffff_0000
                    | UInt32(phyRegisters[register, default: UInt16.max])
            } else if operation == 1 {
                phyRegisters[register] = UInt16(truncatingIfNeeded: value)
            }
        }
        if offset == CadenceGEMRegisterLayout.networkControl,
           value & (1 << 9) != 0 {
            events.append("startTransmit")
            if completeTransmit {
                let descriptor = transmitDescriptorCPUAddress
                    + UInt64(transmitCompletionIndex) * 8 + 4
                let pointer = UnsafeMutableRawPointer(
                    bitPattern: UInt(descriptor)
                )!
                var status = pointer.load(as: UInt32.self)
                status |= (1 << 31) | transmitErrorMask
                pointer.storeBytes(of: status, as: UInt32.self)
                registerValues[CadenceGEMRegisterLayout.transmitStatus]
                    = (1 << 5) | transmitStatusErrorMask
                transmitCompletionIndex = transmitCompletionIndex + 1
                    == transmitDescriptorCount ? 0 : transmitCompletionIndex + 1
            }
        }
    }
}

private struct TestRegisters: CadenceGEMRegisterAccess {
    let hardware: TestHardware

    func read32(at offset: UInt) -> UInt32 {
        hardware.read32(at: offset)
    }

    mutating func write32(_ value: UInt32, at offset: UInt) {
        hardware.write32(value, at: offset)
    }

    func spinWaitHint() {
        hardware.spinCount += 1
    }
}

private final class TestDMA: CadenceGEMDMAAccess {
    let hardware: TestHardware
    var cleanResult = true
    var invalidateResult = true
    var copyResult = true
    var cleanCalls: [(UInt64, UInt64)] = []
    var invalidateCalls: [(UInt64, UInt64)] = []

    init(hardware: TestHardware) {
        self.hardware = hardware
    }

    func loadDescriptorWord(at cpuAddress: UInt64) -> UInt32 {
        UnsafeRawPointer(bitPattern: UInt(cpuAddress))!.load(as: UInt32.self)
    }

    func storeDescriptorWord(_ value: UInt32, at cpuAddress: UInt64) {
        hardware.events.append("descriptorStore")
        UnsafeMutableRawPointer(bitPattern: UInt(cpuAddress))!.storeBytes(
            of: value,
            as: UInt32.self
        )
    }

    func copyIntoDMA(
        _ source: UnsafeRawBufferPointer,
        destinationCPUAddress: UInt64
    ) -> Bool {
        hardware.events.append("copyIntoDMA")
        guard copyResult, let sourceBase = source.baseAddress else { return false }
        UnsafeMutableRawPointer(bitPattern: UInt(destinationCPUAddress))!.copyMemory(
            from: sourceBase,
            byteCount: source.count
        )
        return true
    }

    func copyFromDMA(
        sourceCPUAddress: UInt64,
        byteCount: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) -> Bool {
        hardware.events.append("copyFromDMA")
        guard copyResult, let destinationBase = destination.baseAddress else {
            return false
        }
        destinationBase.copyMemory(
            from: UnsafeRawPointer(bitPattern: UInt(sourceCPUAddress))!,
            byteCount: byteCount
        )
        return true
    }

    func cleanForDevice(cpuAddress: UInt64, byteCount: UInt64) -> Bool {
        hardware.events.append("clean")
        cleanCalls.append((cpuAddress, byteCount))
        return cleanResult
    }

    func invalidateForCPU(cpuAddress: UInt64, byteCount: UInt64) -> Bool {
        hardware.events.append("invalidate")
        invalidateCalls.append((cpuAddress, byteCount))
        return invalidateResult
    }

    func synchronizeOwnership() {
        hardware.events.append("barrier")
    }
}

private final class TestBoard: CadenceGEMBoardControl {
    var preparationResult = CadenceGEMBoardPreparationResult.ready
    var linkStatus = CadenceGEMBoardLinkStatus.up(.gigabitFullDuplex)
    var preparationCalls: [UInt64] = []

    func prepareHardware(
        maximumPollCount: UInt64
    ) -> CadenceGEMBoardPreparationResult {
        preparationCalls.append(maximumPollCount)
        return preparationResult
    }

    func currentLinkStatus() -> CadenceGEMBoardLinkStatus {
        linkStatus
    }
}

private final class TestRP1Preparation: RP1GEMHardwarePreparation {
    var result = CadenceGEMBoardPreparationResult.ready
    var calls: [UInt64] = []

    func prepareRP1Ethernet(
        maximumPollCount: UInt64
    ) -> CadenceGEMBoardPreparationResult {
        calls.append(maximumPollCount)
        return result
    }
}

private final class TestRP1StatusRegisters: RP1GEMConfigurationRegisterAccess {
    var status: UInt32 = 0

    func read32(at offset: UInt) -> UInt32 {
        offset == RP1GEMConfigurationRegisterLayout.status ? status : 0
    }
}

private final class GEMFixture {
    let receiveDescriptors = TestAllocation(byteCount: 64)
    let transmitDescriptors = TestAllocation(byteCount: 64)
    let receiveBuffers = TestAllocation(byteCount: 3_072)
    let transmitBuffers = TestAllocation(byteCount: 3_072)
    let hardware = TestHardware()
    let dma: TestDMA
    let board = TestBoard()
    let storage: CadenceGEMDMAStorage
    let configuration: CadenceGEMDeviceConfiguration

    init(maximumPollCount: UInt64 = 8) {
        dma = TestDMA(hardware: hardware)
        guard let receiveDescriptorRegion = Self.region(
                  receiveDescriptors,
                  deviceAddress: 0x0010_0000,
                  cacheMode: .uncached
              ),
              let transmitDescriptorRegion = Self.region(
                  transmitDescriptors,
                  deviceAddress: 0x0011_0000,
                  cacheMode: .uncached
              ),
              let receiveBufferRegion = Self.region(
                  receiveBuffers,
                  deviceAddress: 0x0012_0000,
                  cacheMode: .writeBack
              ),
              let transmitBufferRegion = Self.region(
                  transmitBuffers,
                  deviceAddress: 0x0013_0000,
                  cacheMode: .writeBack
              ),
              let storage = CadenceGEMDMAStorage(
                  receiveDescriptors: receiveDescriptorRegion,
                  receiveDescriptorCount: 2,
                  transmitDescriptors: transmitDescriptorRegion,
                  transmitDescriptorCount: 2,
                  receiveBuffers: receiveBufferRegion,
                  transmitBuffers: transmitBufferRegion
              ),
              let configuration = CadenceGEMDeviceConfiguration(
                  macAddress: MACAddress(0x02, 0x53, 0x57, 0x49, 0x46, 0x54),
                  phyAddress: 1,
                  mdcClockDividerEncoding: 5,
                  maximumPollCount: maximumPollCount
              )
        else {
            fatalError("valid GEM fixture rejected")
        }
        self.storage = storage
        self.configuration = configuration
        hardware.transmitDescriptorCPUAddress = transmitDescriptors.address
    }

    func makeDevice() -> CadenceGEMNetworkDevice<
        TestRegisters,
        TestDMA,
        TestBoard
    > {
        CadenceGEMNetworkDevice(
            registers: TestRegisters(hardware: hardware),
            dma: dma,
            board: board,
            storage: storage,
            configuration: configuration
        )
    }

    static func region(
        _ allocation: TestAllocation,
        deviceAddress: UInt64,
        cacheMode: CadenceGEMCPUCacheMode,
        coherency: DMACoherency = .softwareManaged
    ) -> CadenceGEMDMARegion? {
        guard let mapping = DMAMapping(
            cpuPhysicalAddress: allocation.address,
            deviceAddress: deviceAddress,
            byteCount: UInt64(allocation.byteCount),
            deviceAddressWidth: .bits32,
            coherency: coherency
        ) else {
            return nil
        }
        return CadenceGEMDMARegion(mapping: mapping, cpuCacheMode: cacheMode)
    }
}

@main
struct CadenceGEMDeviceTests {
    static func main() {
        validatesDMAStorageAndConfiguration()
        initializesMACDMAClause22AndLink()
        reportsBoundedInitializationFailures()
        receivesAndRecyclesBuffersWithCacheOwnership()
        transmitsAndReportsBoundedCompletionFailures()
        mapsRP1WrapperStatusWithoutEmbeddingBringUpPolicy()
        print("cadence GEM network device: 6 groups passed")
    }

    private static func validatesDMAStorageAndConfiguration() {
        let fixture = GEMFixture()
        expect(
            CadenceGEMDeviceConfiguration(
                macAddress: .zero,
                phyAddress: 1,
                mdcClockDividerEncoding: 5,
                maximumPollCount: 8
            ) == nil,
            "zero MAC address accepted"
        )
        expect(
            CadenceGEMDeviceConfiguration(
                macAddress: MACAddress(2, 1, 2, 3, 4, 5),
                phyAddress: 32,
                mdcClockDividerEncoding: 5,
                maximumPollCount: 8
            ) == nil,
            "out-of-range Clause 22 PHY address accepted"
        )
        expect(
            GEMFixture.region(
                fixture.receiveDescriptors,
                deviceAddress: 0x0020_0000,
                cacheMode: .uncached,
                coherency: .hardwareCoherent
            ) == nil,
            "coherent mapping accepted for non-coherent RP1 policy"
        )

        guard let rxDescriptors = GEMFixture.region(
                  fixture.receiveDescriptors,
                  deviceAddress: 0x0020_0000,
                  cacheMode: .writeBack
              ),
              let txDescriptors = GEMFixture.region(
                  fixture.transmitDescriptors,
                  deviceAddress: 0x0021_0000,
                  cacheMode: .uncached
              ),
              let rxBuffers = GEMFixture.region(
                  fixture.receiveBuffers,
                  deviceAddress: 0x0022_0000,
                  cacheMode: .writeBack
              ),
              let txBuffers = GEMFixture.region(
                  fixture.transmitBuffers,
                  deviceAddress: 0x0023_0000,
                  cacheMode: .writeBack
              )
        else {
            fatalError("storage validation fixture creation failed")
        }
        expect(
            CadenceGEMDMAStorage(
                receiveDescriptors: rxDescriptors,
                receiveDescriptorCount: 2,
                transmitDescriptors: txDescriptors,
                transmitDescriptorCount: 2,
                receiveBuffers: rxBuffers,
                transmitBuffers: txBuffers
            ) == nil,
            "write-back descriptor ring accepted"
        )
        let uncachedRX = CadenceGEMDMARegion(
            mapping: rxDescriptors.mapping,
            cpuCacheMode: .uncached
        )!
        expect(
            CadenceGEMDMAStorage(
                receiveDescriptors: uncachedRX,
                receiveDescriptorCount: 1,
                transmitDescriptors: txDescriptors,
                transmitDescriptorCount: 2,
                receiveBuffers: rxBuffers,
                transmitBuffers: txBuffers
            ) == nil,
            "single-descriptor GEM ring accepted"
        )
    }

    private static func initializesMACDMAClause22AndLink() {
        let fixture = GEMFixture()
        var device = fixture.makeDevice()
        expect(device.initialize() == .ready, "valid GEM initialization failed")
        expect(device.linkState == .up, "resolved link was not exposed")
        expect(device.phyIdentifier1 == 0x600d, "PHY identifier 1 lost")
        expect(device.phyIdentifier2 == 0x8421, "PHY identifier 2 lost")
        expect(fixture.board.preparationCalls == [8], "board preparation mismatch")
        expect(
            fixture.hardware.phyRegisters[0] == 0x1200,
            "Clause 22 autonegotiation was not restarted"
        )
        expect(
            fixture.hardware.registerValues[
                CadenceGEMRegisterLayout.specificAddress1Bottom
            ] == 0x4957_5302
                && fixture.hardware.registerValues[
                    CadenceGEMRegisterLayout.specificAddress1Top
                ] == 0x5446,
            "specific address register encoding mismatch"
        )
        let networkConfiguration = fixture.hardware.registerValues[
            CadenceGEMRegisterLayout.networkConfiguration,
            default: 0
        ]
        expect(
            networkConfiguration & ((1 << 10) | (1 << 1) | (1 << 17))
                == (1 << 10) | (1 << 1) | (1 << 17),
            "gigabit/full-duplex/FCS removal configuration mismatch"
        )
        expect(
            (networkConfiguration >> 18) & 7 == 5,
            "board-selected MDC divider was lost"
        )
        let dmaConfiguration = fixture.hardware.registerValues[
            CadenceGEMRegisterLayout.dmaConfiguration,
            default: 0
        ]
        expect(
            (dmaConfiguration >> 16) & 0xff == 24,
            "1536-byte RX buffer size was not programmed"
        )
        expect(
            dmaConfiguration & ((1 << 30) | (1 << 29) | (1 << 28) | (1 << 7))
                == 0,
            "32-bit two-word little-endian descriptor mode not enforced"
        )
        expect(
            read32(fixture.receiveDescriptors.pointer) == 0x0012_0000
                && read32(fixture.receiveDescriptors.pointer + 8)
                    == 0x0012_0602,
            "RX descriptor addresses/wrap bit mismatch"
        )
        expect(
            read32(fixture.transmitDescriptors.pointer + 4) == 1 << 31
                && read32(fixture.transmitDescriptors.pointer + 12)
                    == (1 << 31) | (1 << 30),
            "TX descriptors did not begin software-owned"
        )
        expect(
            fixture.dma.cleanCalls.count == 2,
            "RX buffers were not cleaned before first device ownership"
        )
    }

    private static func reportsBoundedInitializationFailures() {
        do {
            let fixture = GEMFixture(maximumPollCount: 4)
            fixture.board.preparationResult = .timedOut
            var device = fixture.makeDevice()
            expect(
                device.initialize() == .boardPreparationTimedOut,
                "board timeout was hidden"
            )
        }
        do {
            let fixture = GEMFixture(maximumPollCount: 4)
            fixture.hardware.mdioStuck = true
            var device = fixture.makeDevice()
            expect(device.initialize() == .mdioTimedOut, "MDIO timeout was hidden")
            expect(fixture.hardware.spinCount == 4, "MDIO polling was not bounded")
        }
        do {
            let fixture = GEMFixture(maximumPollCount: 4)
            fixture.hardware.phyRegisters[2] = 0
            fixture.hardware.phyRegisters[3] = 0
            var device = fixture.makeDevice()
            expect(
                device.initialize() == .phyNotFound(identifier1: 0, identifier2: 0),
                "absent PHY identifiers were accepted"
            )
        }
        do {
            let fixture = GEMFixture(maximumPollCount: 4)
            fixture.hardware.phyRegisters[1] = 0
            var device = fixture.makeDevice()
            expect(
                device.initialize() == .phyAutonegotiationTimedOut,
                "incomplete autonegotiation was accepted"
            )
            expect(fixture.hardware.spinCount == 4, "link polling was not bounded")
        }
        do {
            let fixture = GEMFixture(maximumPollCount: 4)
            fixture.dma.cleanResult = false
            var device = fixture.makeDevice()
            expect(
                device.initialize() == .dmaCacheMaintenanceFailed,
                "initial DMA clean failure was hidden"
            )
        }
    }

    private static func receivesAndRecyclesBuffersWithCacheOwnership() {
        let fixture = GEMFixture()
        var device = fixture.makeDevice()
        expect(device.initialize() == .ready, "RX fixture did not initialize")
        fixture.hardware.events.removeAll(keepingCapacity: true)
        fixture.dma.cleanCalls.removeAll(keepingCapacity: true)
        fixture.dma.invalidateCalls.removeAll(keepingCapacity: true)

        let frame = (0..<64).map { UInt8(truncatingIfNeeded: $0 &+ 1) }
        frame.withUnsafeBytes { bytes in
            fixture.receiveBuffers.pointer.copyMemory(
                from: bytes.baseAddress!,
                byteCount: bytes.count
            )
        }
        write32((1 << 14) | (1 << 15) | UInt32(frame.count),
                to: fixture.receiveDescriptors.pointer + 4)
        write32(read32(fixture.receiveDescriptors.pointer) | 1,
                to: fixture.receiveDescriptors.pointer)

        var output = [UInt8](repeating: 0, count: 128)
        let result = output.withUnsafeMutableBytes { bytes in
            device.pollReceive(into: bytes)
        }
        expect(result == .received(byteCount: 64), "valid RX frame was not returned")
        expect(Array(output.prefix(64)) == frame, "RX payload copy mismatch")
        expect(
            fixture.hardware.events.prefix(3) == [
                "barrier", "invalidate", "copyFromDMA",
            ],
            "RX device-to-CPU ownership order mismatch"
        )
        expect(
            fixture.dma.cleanCalls.count == 1
                && fixture.dma.invalidateCalls.count == 1,
            "RX buffer did not cross both cache ownership boundaries"
        )
        expect(
            read32(fixture.receiveDescriptors.pointer) & 1 == 0,
            "RX descriptor was not recycled to hardware"
        )
        expect(
            output.withUnsafeMutableBytes { device.pollReceive(into: $0) }
                == .noPacket,
            "empty RX descriptor did not report no packet"
        )

        let descriptor1 = fixture.receiveDescriptors.pointer + 8
        write32((1 << 14) | (1 << 15) | 100, to: descriptor1 + 4)
        write32(read32(descriptor1) | 1, to: descriptor1)
        var shortOutput = [UInt8](repeating: 0, count: 32)
        expect(
            shortOutput.withUnsafeMutableBytes { device.pollReceive(into: $0) }
                == .outputTooSmall(requiredByteCount: 100),
            "short receive output was not diagnosed"
        )

        write32((1 << 14) | 64, to: fixture.receiveDescriptors.pointer + 4)
        write32(read32(fixture.receiveDescriptors.pointer) | 1,
                to: fixture.receiveDescriptors.pointer)
        expect(
            output.withUnsafeMutableBytes { device.pollReceive(into: $0) }
                == .malformedFrame,
            "fragmented frame was accepted despite one-buffer mode"
        )
    }

    private static func transmitsAndReportsBoundedCompletionFailures() {
        do {
            let fixture = GEMFixture()
            var device = fixture.makeDevice()
            expect(device.initialize() == .ready, "TX fixture did not initialize")
            fixture.hardware.events.removeAll(keepingCapacity: true)
            let frame = [UInt8](repeating: 0xa5, count: 60)
            let result = frame.withUnsafeBytes { device.transmit($0) }
            expect(result == .sent, "valid TX frame was not sent")
            expect(
                fixture.hardware.events.prefix(4) == [
                    "copyIntoDMA", "clean", "descriptorStore", "barrier",
                ],
                "TX CPU-to-device ownership order mismatch"
            )
            expect(
                fixture.hardware.events.contains("startTransmit"),
                "TX start command was not issued"
            )
            let transmitted = UnsafeRawBufferPointer(
                start: fixture.transmitBuffers.pointer,
                count: frame.count
            )
            expect(Array(transmitted) == frame, "TX DMA buffer copy mismatch")
        }
        do {
            let fixture = GEMFixture(maximumPollCount: 4)
            fixture.hardware.completeTransmit = false
            var device = fixture.makeDevice()
            expect(device.initialize() == .ready, "TX timeout fixture init failed")
            let frame = [UInt8](repeating: 0x5a, count: 60)
            expect(
                frame.withUnsafeBytes { device.transmit($0) } == .timedOut,
                "TX completion timeout was hidden"
            )
            expect(device.linkState == .faulted, "timed-out DMA stayed reusable")
        }
        do {
            let fixture = GEMFixture()
            fixture.hardware.transmitStatusErrorMask = 1 << 4
            var device = fixture.makeDevice()
            expect(device.initialize() == .ready, "TX error fixture init failed")
            let frame = [UInt8](repeating: 0x5a, count: 60)
            expect(
                frame.withUnsafeBytes { device.transmit($0) } == .deviceFault,
                "TX bus-error status was ignored"
            )
        }
    }

    private static func mapsRP1WrapperStatusWithoutEmbeddingBringUpPolicy() {
        let preparation = TestRP1Preparation()
        let status = TestRP1StatusRegisters()
        var board = RP1GEMBoardControl(
            preparation: preparation,
            statusRegisters: status
        )
        expect(
            board.prepareHardware(maximumPollCount: 99) == .ready
                && preparation.calls == [99],
            "RP1 preparation policy was not delegated"
        )
        status.status = 1
        expect(
            board.currentLinkStatus() == .up(.megabit10HalfDuplex),
            "RP1 10M half-duplex decode mismatch"
        )
        status.status = 1 | (1 << 1) | (1 << 3)
        expect(
            board.currentLinkStatus() == .up(.megabit100FullDuplex),
            "RP1 100M full-duplex decode mismatch"
        )
        status.status = 1 | (2 << 1) | (1 << 3)
        expect(
            board.currentLinkStatus() == .up(.gigabitFullDuplex),
            "RP1 gigabit full-duplex decode mismatch"
        )
        status.status = 1 << 5
        expect(
            board.currentLinkStatus() == .faulted,
            "RP1 illegal AXI burst was not promoted to a fault"
        )

        let gemRegisters = TestAllocation(byteCount: 256)
        expect(
            RP1GEMMMIORegisterAccess(
                resource: DeviceResource(
                    baseAddress: gemRegisters.address,
                    length: 0xff
                )
            ) == nil,
            "undersized RP1 GEM aperture was accepted"
        )
        guard var gemAccess = RP1GEMMMIORegisterAccess(
                  resource: DeviceResource(
                      baseAddress: gemRegisters.address,
                      length: 0x100
                  )
              )
        else {
            fatalError("valid RP1 GEM aperture rejected")
        }
        gemAccess.write32(0x1234_5678, at: CadenceGEMRegisterLayout.networkControl)
        expect(
            gemAccess.read32(at: CadenceGEMRegisterLayout.networkControl)
                == 0x1234_5678,
            "RP1 GEM volatile register access mismatch"
        )

        let wrapperRegisters = TestAllocation(byteCount: 64)
        write32(1 | (2 << 1) | (1 << 3), to: wrapperRegisters.pointer + 4)
        guard let wrapperAccess = RP1GEMConfigurationMMIORegisterAccess(
                  resource: DeviceResource(
                      baseAddress: wrapperRegisters.address,
                      length: 8
                  )
              )
        else {
            fatalError("valid RP1 ETH_CFG aperture rejected")
        }
        expect(
            wrapperAccess.read32(at: RP1GEMConfigurationRegisterLayout.status)
                == 13,
            "RP1 ETH_CFG volatile status access mismatch"
        )
    }

    private static func read32(_ pointer: UnsafeRawPointer) -> UInt32 {
        pointer.load(as: UInt32.self)
    }

    private static func write32(_ value: UInt32, to pointer: UnsafeMutableRawPointer) {
        pointer.storeBytes(of: value, as: UInt32.self)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() {
            fatalError(message)
        }
    }
}
