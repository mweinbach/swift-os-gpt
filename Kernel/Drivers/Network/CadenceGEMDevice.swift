/// Allocation-free Cadence GEM policy used by the RP1 Ethernet path.
///
/// The MAC core intentionally has no knowledge of clocks, GPIO muxing, PHY
/// reset wiring, RP1 address translation, interrupts, or an IP stack. Those
/// responsibilities cross explicit interfaces below. This driver uses the
/// standard two-word, 32-bit-address GEM descriptor format and polling only.
protocol CadenceGEMRegisterAccess {
    func read32(at offset: UInt) -> UInt32
    mutating func write32(_ value: UInt32, at offset: UInt)
    func spinWaitHint()
}

/// DMA operations are explicit because RP1 is not cache coherent with the CPU.
/// Descriptor regions are required to be CPU-uncached; packet data may remain
/// write-back cached and crosses the clean/invalidate ownership boundary here.
protocol CadenceGEMDMAAccess {
    func loadDescriptorWord(at cpuAddress: UInt64) -> UInt32
    mutating func storeDescriptorWord(_ value: UInt32, at cpuAddress: UInt64)

    mutating func copyIntoDMA(
        _ source: UnsafeRawBufferPointer,
        destinationCPUAddress: UInt64
    ) -> Bool
    mutating func copyFromDMA(
        sourceCPUAddress: UInt64,
        byteCount: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) -> Bool

    mutating func cleanForDevice(
        cpuAddress: UInt64,
        byteCount: UInt64
    ) -> Bool
    mutating func invalidateForCPU(
        cpuAddress: UInt64,
        byteCount: UInt64
    ) -> Bool
    mutating func synchronizeOwnership()
}

enum CadenceGEMBoardPreparationResult: UInt8, Equatable {
    case ready
    case timedOut
    case failed
}

enum CadenceGEMLinkMode: UInt8, Equatable {
    case megabit10HalfDuplex
    case megabit10FullDuplex
    case megabit100HalfDuplex
    case megabit100FullDuplex
    case gigabitHalfDuplex
    case gigabitFullDuplex
}

enum CadenceGEMBoardLinkStatus: Equatable {
    case down
    case up(CadenceGEMLinkMode)
    case faulted
}

/// Board policy owns clocks, pin muxing, GPIO PHY reset, and any wrapper status
/// register. `prepareHardware` must leave GEM's APB aperture and MDIO pins live.
protocol CadenceGEMBoardControl {
    mutating func prepareHardware(
        maximumPollCount: UInt64
    ) -> CadenceGEMBoardPreparationResult

    func currentLinkStatus() -> CadenceGEMBoardLinkStatus
}

enum CadenceGEMCPUCacheMode: UInt8, Equatable {
    /// Normal non-cacheable (or another mapping whose CPU accesses cannot be
    /// satisfied by stale private cache lines).
    case uncached
    /// Normal write-back memory requiring explicit ownership maintenance.
    case writeBack
}

struct CadenceGEMDMARegion: Equatable {
    let mapping: DMAMapping
    let cpuCacheMode: CadenceGEMCPUCacheMode

    init?(mapping: DMAMapping, cpuCacheMode: CadenceGEMCPUCacheMode) {
        guard mapping.coherency == .softwareManaged,
              mapping.cpuPhysicalAddress > 0,
              mapping.cpuPhysicalAddress <= UInt64(UInt.max),
              mapping.byteCount - 1
                  <= UInt64(UInt.max) - mapping.cpuPhysicalAddress,
              UnsafeMutableRawPointer(
                  bitPattern: UInt(mapping.cpuPhysicalAddress)
              ) != nil
        else {
            return nil
        }
        self.mapping = mapping
        self.cpuCacheMode = cpuCacheMode
    }
}

enum CadenceGEMConfiguration {
    static let ethernetHeaderByteCount = 14
    static let mtu: UInt16 = 1_500
    static let maximumFrameByteCount = ethernetHeaderByteCount + Int(mtu)
    static let packetBufferByteCount: UInt64 = 1_536
    static let descriptorByteCount: UInt64 = 8
    static let minimumDescriptorCount: UInt16 = 2
    static let maximumDescriptorCount: UInt16 = 64
}

/// Caller-owned DMA mappings. GEM receives one complete non-jumbo frame per
/// 1536-byte buffer, so the bounded polling path never has to assemble a frame.
struct CadenceGEMDMAStorage: Equatable {
    let receiveDescriptors: CadenceGEMDMARegion
    let transmitDescriptors: CadenceGEMDMARegion
    let receiveBuffers: CadenceGEMDMARegion
    let transmitBuffers: CadenceGEMDMARegion
    let receiveDescriptorCount: UInt16
    let transmitDescriptorCount: UInt16

    init?(
        receiveDescriptors: CadenceGEMDMARegion,
        receiveDescriptorCount: UInt16,
        transmitDescriptors: CadenceGEMDMARegion,
        transmitDescriptorCount: UInt16,
        receiveBuffers: CadenceGEMDMARegion,
        transmitBuffers: CadenceGEMDMARegion
    ) {
        guard Self.validDescriptorCount(receiveDescriptorCount),
              Self.validDescriptorCount(transmitDescriptorCount),
              receiveDescriptors.cpuCacheMode == .uncached,
              transmitDescriptors.cpuCacheMode == .uncached,
              receiveBuffers.cpuCacheMode == .writeBack,
              transmitBuffers.cpuCacheMode == .writeBack,
              Self.usable(
                  receiveDescriptors.mapping,
                  minimumByteCount: UInt64(receiveDescriptorCount)
                      * CadenceGEMConfiguration.descriptorByteCount,
                  alignment: 8
              ),
              Self.usable(
                  transmitDescriptors.mapping,
                  minimumByteCount: UInt64(transmitDescriptorCount)
                      * CadenceGEMConfiguration.descriptorByteCount,
                  alignment: 8
              ),
              Self.usable(
                  receiveBuffers.mapping,
                  minimumByteCount: UInt64(receiveDescriptorCount)
                      * CadenceGEMConfiguration.packetBufferByteCount,
                  alignment: 4
              ),
              Self.usable(
                  transmitBuffers.mapping,
                  minimumByteCount: UInt64(transmitDescriptorCount)
                      * CadenceGEMConfiguration.packetBufferByteCount,
                  alignment: 4
              ),
              Self.disjoint(receiveDescriptors.mapping, transmitDescriptors.mapping),
              Self.disjoint(receiveDescriptors.mapping, receiveBuffers.mapping),
              Self.disjoint(receiveDescriptors.mapping, transmitBuffers.mapping),
              Self.disjoint(transmitDescriptors.mapping, receiveBuffers.mapping),
              Self.disjoint(transmitDescriptors.mapping, transmitBuffers.mapping),
              Self.disjoint(receiveBuffers.mapping, transmitBuffers.mapping)
        else {
            return nil
        }

        self.receiveDescriptors = receiveDescriptors
        self.transmitDescriptors = transmitDescriptors
        self.receiveBuffers = receiveBuffers
        self.transmitBuffers = transmitBuffers
        self.receiveDescriptorCount = receiveDescriptorCount
        self.transmitDescriptorCount = transmitDescriptorCount
    }

    private static func validDescriptorCount(_ count: UInt16) -> Bool {
        count >= CadenceGEMConfiguration.minimumDescriptorCount
            && count <= CadenceGEMConfiguration.maximumDescriptorCount
    }

    private static func usable(
        _ mapping: DMAMapping,
        minimumByteCount: UInt64,
        alignment: UInt64
    ) -> Bool {
        guard mapping.byteCount >= minimumByteCount,
              mapping.deviceAddress <= UInt64(UInt32.max),
              mapping.byteCount - 1
                  <= UInt64(UInt32.max) - mapping.deviceAddress,
              mapping.cpuPhysicalAddress & (alignment - 1) == 0,
              mapping.deviceAddress & (alignment - 1) == 0
        else {
            return false
        }
        return true
    }

    private static func disjoint(_ first: DMAMapping, _ second: DMAMapping) -> Bool {
        !Self.overlap(
            first.cpuPhysicalAddress,
            first.byteCount,
            second.cpuPhysicalAddress,
            second.byteCount
        ) && !Self.overlap(
            first.deviceAddress,
            first.byteCount,
            second.deviceAddress,
            second.byteCount
        )
    }

    private static func overlap(
        _ firstAddress: UInt64,
        _ firstByteCount: UInt64,
        _ secondAddress: UInt64,
        _ secondByteCount: UInt64
    ) -> Bool {
        let firstEnd = firstAddress + firstByteCount
        let secondEnd = secondAddress + secondByteCount
        return firstAddress < secondEnd && secondAddress < firstEnd
    }
}

struct CadenceGEMDeviceConfiguration: Equatable {
    let macAddress: MACAddress
    let phyAddress: UInt8
    /// Encoding written to Network Configuration bits 20:18. The board owner
    /// selects it from the actual GEM peripheral clock; the core never guesses.
    let mdcClockDividerEncoding: UInt8
    let maximumPollCount: UInt64

    init?(
        macAddress: MACAddress,
        phyAddress: UInt8,
        mdcClockDividerEncoding: UInt8,
        maximumPollCount: UInt64
    ) {
        guard macAddress.isUnicast,
              phyAddress < 32,
              mdcClockDividerEncoding < 8,
              maximumPollCount > 0
        else {
            return nil
        }
        self.macAddress = macAddress
        self.phyAddress = phyAddress
        self.mdcClockDividerEncoding = mdcClockDividerEncoding
        self.maximumPollCount = maximumPollCount
    }
}

enum CadenceGEMInitializationResult: Equatable {
    case ready
    case invalidState
    case boardPreparationTimedOut
    case boardPreparationFailed
    case dmaCacheMaintenanceFailed
    case mdioTimedOut
    case phyNotFound(identifier1: UInt16, identifier2: UInt16)
    case phyAutonegotiationTimedOut
    case linkModeUnavailable
}

private enum CadenceGEMDeviceState: UInt8 {
    case cold
    case ready
    case faulted
}

enum CadenceGEMRegisterLayout {
    static let minimumApertureLength: UInt64 = 0x100

    static let networkControl: UInt = 0x000
    static let networkConfiguration: UInt = 0x004
    static let networkStatus: UInt = 0x008
    static let dmaConfiguration: UInt = 0x010
    static let transmitStatus: UInt = 0x014
    static let receiveQueuePointer: UInt = 0x018
    static let transmitQueuePointer: UInt = 0x01c
    static let receiveStatus: UInt = 0x020
    static let interruptStatus: UInt = 0x024
    static let interruptDisable: UInt = 0x02c
    static let phyMaintenance: UInt = 0x034
    static let specificAddress1Bottom: UInt = 0x088
    static let specificAddress1Top: UInt = 0x08c
    static let revision: UInt = 0x0fc
}

/// Two-word-descriptor, 32-bit-address Cadence GEM NetworkLink backend.
/// External serialization is required, matching the NetworkLink contract.
struct CadenceGEMNetworkDevice<
    Registers: CadenceGEMRegisterAccess,
    DMA: CadenceGEMDMAAccess,
    Board: CadenceGEMBoardControl
>: NetworkLink {
    private enum NetworkControl {
        static var receiveEnable: UInt32 { 1 << 2 }
        static var transmitEnable: UInt32 { 1 << 3 }
        static var managementPortEnable: UInt32 { 1 << 4 }
        static var startTransmit: UInt32 { 1 << 9 }
    }

    private enum NetworkConfiguration {
        static var speed100: UInt32 { 1 << 0 }
        static var fullDuplex: UInt32 { 1 << 1 }
        static var jumbo: UInt32 { 1 << 3 }
        static var copyAll: UInt32 { 1 << 4 }
        static var noBroadcast: UInt32 { 1 << 5 }
        static var multicastHash: UInt32 { 1 << 6 }
        static var unicastHash: UInt32 { 1 << 7 }
        static var gigabit: UInt32 { 1 << 10 }
        static var pcsSelect: UInt32 { 1 << 11 }
        static var receiveBufferOffset: UInt32 { 3 << 14 }
        static var fcsRemove: UInt32 { 1 << 17 }
        static var mdcDivider: UInt32 { 7 << 18 }
        static var ignoreFCS: UInt32 { 1 << 26 }

        static var ownedMask: UInt32 {
            speed100 | fullDuplex | jumbo | copyAll | noBroadcast
                | multicastHash | unicastHash | gigabit | pcsSelect
                | receiveBufferOffset | fcsRemove | mdcDivider | ignoreFCS
        }
    }

    private enum DMAConfiguration {
        static var burstLength: UInt32 { 0x1f }
        static var headerSplit: UInt32 { 1 << 5 }
        static var managementEndianSwap: UInt32 { 1 << 6 }
        static var packetEndianSwap: UInt32 { 1 << 7 }
        static var receivePacketBufferSize: UInt32 { 3 << 8 }
        static var transmitPacketBufferSize: UInt32 { 1 << 10 }
        static var checksumOffload: UInt32 { 1 << 11 }
        static var infiniteLastBuffer: UInt32 { 1 << 12 }
        static var crcErrorReport: UInt32 { 1 << 13 }
        static var receiveBufferSize: UInt32 { 0xff << 16 }
        static var discardOnResourceError: UInt32 { 1 << 24 }
        static var forceMaximumBurstRX: UInt32 { 1 << 25 }
        static var forceMaximumBurstTX: UInt32 { 1 << 26 }
        static var extendedRXDescriptor: UInt32 { 1 << 28 }
        static var extendedTXDescriptor: UInt32 { 1 << 29 }
        static var address64: UInt32 { 1 << 30 }

        static var ownedMask: UInt32 {
            burstLength | headerSplit | managementEndianSwap | packetEndianSwap
                | receivePacketBufferSize | transmitPacketBufferSize
                | checksumOffload | infiniteLastBuffer | crcErrorReport
                | receiveBufferSize | discardOnResourceError
                | forceMaximumBurstRX | forceMaximumBurstTX
                | extendedRXDescriptor | extendedTXDescriptor | address64
        }

        static var pollingValue: UInt32 {
            // 24 * 64 = 1536-byte receive buffers; INCR16 AXI bursts.
            (24 << 16) | discardOnResourceError
                | receivePacketBufferSize | transmitPacketBufferSize | (1 << 4)
        }
    }

    private enum ReceiveDescriptor {
        static var ownedByCPU: UInt32 { 1 << 0 }
        static var wrap: UInt32 { 1 << 1 }
        static var lengthMask: UInt32 { 0x1fff }
        static var startOfFrame: UInt32 { 1 << 14 }
        static var endOfFrame: UInt32 { 1 << 15 }
    }

    private enum TransmitDescriptor {
        static var lengthMask: UInt32 { 0x3fff }
        static var lastBuffer: UInt32 { 1 << 15 }
        static var lateCollision: UInt32 { 1 << 26 }
        static var frameCorruption: UInt32 { 1 << 27 }
        static var retryLimitExceeded: UInt32 { 1 << 29 }
        static var wrap: UInt32 { 1 << 30 }
        static var used: UInt32 { 1 << 31 }
        static var errorMask: UInt32 {
            lateCollision | frameCorruption | retryLimitExceeded
        }
    }

    private enum TransmitStatus {
        static var usedBitRead: UInt32 { 1 << 0 }
        static var retryLimitExceeded: UInt32 { 1 << 2 }
        static var busError: UInt32 { 1 << 4 }
        static var underRun: UInt32 { 1 << 6 }
        static var lateCollision: UInt32 { 1 << 7 }
        static var responseNotOK: UInt32 { 1 << 8 }
        static var macLockup: UInt32 { 1 << 9 }
        static var dmaLockup: UInt32 { 1 << 10 }
        static var errorMask: UInt32 {
            usedBitRead | retryLimitExceeded | busError | underRun
                | lateCollision | responseNotOK | macLockup | dmaLockup
        }
    }

    private enum Clause22 {
        static var basicControl: UInt8 { 0 }
        static var basicStatus: UInt8 { 1 }
        static var identifier1: UInt8 { 2 }
        static var identifier2: UInt8 { 3 }
        static var autonegotiationEnable: UInt16 { 1 << 12 }
        static var restartAutonegotiation: UInt16 { 1 << 9 }
        static var autonegotiationComplete: UInt16 { 1 << 5 }
        static var linkUp: UInt16 { 1 << 2 }
        static var managementIdle: UInt32 { 1 << 2 }
    }

    private var registers: Registers
    private var dma: DMA
    private var board: Board
    private let storage: CadenceGEMDMAStorage
    private let configuration: CadenceGEMDeviceConfiguration
    private var state: CadenceGEMDeviceState = .cold
    private var receiveIndex: UInt16 = 0
    private var transmitIndex: UInt16 = 0
    private var configuredLinkMode: CadenceGEMLinkMode?

    private(set) var phyIdentifier1: UInt16 = 0
    private(set) var phyIdentifier2: UInt16 = 0

    init(
        registers: Registers,
        dma: DMA,
        board: Board,
        storage: CadenceGEMDMAStorage,
        configuration: CadenceGEMDeviceConfiguration
    ) {
        self.registers = registers
        self.dma = dma
        self.board = board
        self.storage = storage
        self.configuration = configuration
    }

    var macAddress: MACAddress { configuration.macAddress }
    var mtu: UInt16 { CadenceGEMConfiguration.mtu }

    var linkState: NetworkLinkState {
        guard state == .ready else {
            return state == .faulted ? .faulted : .down
        }
        switch board.currentLinkStatus() {
        case .down:
            return .down
        case .up:
            return .up
        case .faulted:
            return .faulted
        }
    }

    mutating func initialize() -> CadenceGEMInitializationResult {
        guard state == .cold else { return .invalidState }

        switch board.prepareHardware(
            maximumPollCount: configuration.maximumPollCount
        ) {
        case .ready:
            break
        case .timedOut:
            return rejectInitialization(.boardPreparationTimedOut)
        case .failed:
            return rejectInitialization(.boardPreparationFailed)
        }

        disableController()
        configureMACAddress()
        configureNetworkForMDIO()
        guard prepareDMAStorage() else {
            return failInitialization(.dmaCacheMaintenanceFailed)
        }

        registers.write32(
            NetworkControl.managementPortEnable,
            at: CadenceGEMRegisterLayout.networkControl
        )

        guard let identifier1 = readClause22(Clause22.identifier1),
              let identifier2 = readClause22(Clause22.identifier2)
        else {
            return failInitialization(.mdioTimedOut)
        }
        phyIdentifier1 = identifier1
        phyIdentifier2 = identifier2
        guard !Self.invalidPHYIdentifier(identifier1, identifier2) else {
            return failInitialization(
                .phyNotFound(identifier1: identifier1, identifier2: identifier2)
            )
        }

        guard writeClause22(
            Clause22.basicControl,
            value: Clause22.autonegotiationEnable
                | Clause22.restartAutonegotiation
        ) else {
            return failInitialization(.mdioTimedOut)
        }

        var resolvedMode: CadenceGEMLinkMode?
        var pollCount: UInt64 = 0
        while pollCount < configuration.maximumPollCount {
            // BMSR link is latch-low, so use the second of two reads.
            guard readClause22(Clause22.basicStatus) != nil,
                  let status = readClause22(Clause22.basicStatus)
            else {
                return failInitialization(.mdioTimedOut)
            }
            if status & Clause22.autonegotiationComplete != 0,
               status & Clause22.linkUp != 0,
               case let .up(mode) = board.currentLinkStatus() {
                resolvedMode = mode
                break
            }
            pollCount += 1
            registers.spinWaitHint()
        }
        guard pollCount < configuration.maximumPollCount else {
            return failInitialization(.phyAutonegotiationTimedOut)
        }
        guard let resolvedMode else {
            return failInitialization(.linkModeUnavailable)
        }

        configureNetwork(linkMode: resolvedMode)
        configuredLinkMode = resolvedMode
        registers.write32(
            NetworkControl.managementPortEnable
                | NetworkControl.receiveEnable
                | NetworkControl.transmitEnable,
            at: CadenceGEMRegisterLayout.networkControl
        )
        state = .ready
        return .ready
    }

    mutating func pollReceive(
        into output: UnsafeMutableRawBufferPointer
    ) -> NetworkLinkReceiveResult {
        guard state == .ready else { return .deviceFault }
        if board.currentLinkStatus() == .faulted {
            faultDevice()
            return .deviceFault
        }

        let descriptorAddress = receiveDescriptorCPUAddress(at: receiveIndex)
        let addressWord = dma.loadDescriptorWord(at: descriptorAddress)
        guard addressWord & ReceiveDescriptor.ownedByCPU != 0 else {
            return .noPacket
        }
        dma.synchronizeOwnership()
        let statusWord = dma.loadDescriptorWord(at: descriptorAddress + 4)
        let frameByteCount = Int(statusWord & ReceiveDescriptor.lengthMask)
        let bufferAddress = receiveBufferCPUAddress(at: receiveIndex)

        guard dma.invalidateForCPU(
            cpuAddress: bufferAddress,
            byteCount: CadenceGEMConfiguration.packetBufferByteCount
        ) else {
            faultDevice()
            return .deviceFault
        }

        let isWholeFrame = statusWord & ReceiveDescriptor.startOfFrame != 0
            && statusWord & ReceiveDescriptor.endOfFrame != 0
        let isValidLength = frameByteCount
            >= CadenceGEMConfiguration.ethernetHeaderByteCount
            && frameByteCount <= CadenceGEMConfiguration.maximumFrameByteCount

        let result: NetworkLinkReceiveResult
        if !isWholeFrame || !isValidLength {
            result = .malformedFrame
        } else if output.count < frameByteCount {
            result = .outputTooSmall(requiredByteCount: frameByteCount)
        } else if output.baseAddress == nil {
            faultDevice()
            return .deviceFault
        } else if dma.copyFromDMA(
            sourceCPUAddress: bufferAddress,
            byteCount: frameByteCount,
            into: output
        ) {
            result = .received(byteCount: frameByteCount)
        } else {
            faultDevice()
            return .deviceFault
        }

        guard recycleReceiveDescriptor(
            at: receiveIndex,
            addressWord: addressWord
        ) else {
            faultDevice()
            return .deviceFault
        }
        receiveIndex = Self.nextIndex(
            receiveIndex,
            count: storage.receiveDescriptorCount
        )
        return result
    }

    mutating func transmit(
        _ frame: UnsafeRawBufferPointer
    ) -> NetworkLinkTransmitResult {
        guard state == .ready else { return .deviceFault }
        switch board.currentLinkStatus() {
        case .down:
            return .linkDown
        case .faulted:
            faultDevice()
            return .deviceFault
        case let .up(mode):
            if configuredLinkMode != mode {
                configureNetwork(linkMode: mode)
                configuredLinkMode = mode
            }
        }
        guard frame.count >= CadenceGEMConfiguration.ethernetHeaderByteCount,
              frame.count <= CadenceGEMConfiguration.maximumFrameByteCount,
              frame.baseAddress != nil
        else {
            return .invalidFrame
        }

        let descriptorAddress = transmitDescriptorCPUAddress(at: transmitIndex)
        var descriptorStatus = dma.loadDescriptorWord(at: descriptorAddress + 4)
        var availabilityPoll: UInt64 = 0
        while descriptorStatus & TransmitDescriptor.used == 0,
              availabilityPoll < configuration.maximumPollCount {
            availabilityPoll += 1
            registers.spinWaitHint()
            descriptorStatus = dma.loadDescriptorWord(at: descriptorAddress + 4)
        }
        guard availabilityPoll < configuration.maximumPollCount else {
            faultDevice()
            return .timedOut
        }

        let bufferAddress = transmitBufferCPUAddress(at: transmitIndex)
        guard dma.copyIntoDMA(frame, destinationCPUAddress: bufferAddress),
              dma.cleanForDevice(
                  cpuAddress: bufferAddress,
                  byteCount: UInt64(frame.count)
              )
        else {
            faultDevice()
            return .deviceFault
        }

        var submission = UInt32(frame.count) & TransmitDescriptor.lengthMask
        submission |= TransmitDescriptor.lastBuffer
        if transmitIndex == storage.transmitDescriptorCount - 1 {
            submission |= TransmitDescriptor.wrap
        }
        dma.storeDescriptorWord(submission, at: descriptorAddress + 4)
        dma.synchronizeOwnership()

        let currentControl = registers.read32(
            at: CadenceGEMRegisterLayout.networkControl
        )
        registers.write32(
            currentControl | NetworkControl.startTransmit,
            at: CadenceGEMRegisterLayout.networkControl
        )

        var completionPoll: UInt64 = 0
        while completionPoll < configuration.maximumPollCount {
            descriptorStatus = dma.loadDescriptorWord(at: descriptorAddress + 4)
            if descriptorStatus & TransmitDescriptor.used != 0 {
                dma.synchronizeOwnership()
                break
            }
            completionPoll += 1
            registers.spinWaitHint()
        }
        guard completionPoll < configuration.maximumPollCount else {
            faultDevice()
            return .timedOut
        }
        let transmitStatus = registers.read32(
            at: CadenceGEMRegisterLayout.transmitStatus
        )
        registers.write32(
            transmitStatus,
            at: CadenceGEMRegisterLayout.transmitStatus
        )
        guard descriptorStatus & TransmitDescriptor.errorMask == 0,
              transmitStatus & TransmitStatus.errorMask == 0
        else {
            faultDevice()
            return .deviceFault
        }

        transmitIndex = Self.nextIndex(
            transmitIndex,
            count: storage.transmitDescriptorCount
        )
        return .sent
    }

    private mutating func prepareDMAStorage() -> Bool {
        var index: UInt16 = 0
        while index < storage.receiveDescriptorCount {
            let bufferCPUAddress = receiveBufferCPUAddress(at: index)
            guard dma.cleanForDevice(
                cpuAddress: bufferCPUAddress,
                byteCount: CadenceGEMConfiguration.packetBufferByteCount
            ) else {
                return false
            }
            let descriptorAddress = receiveDescriptorCPUAddress(at: index)
            var addressWord = UInt32(
                storage.receiveBuffers.mapping.deviceAddress
                    + UInt64(index)
                        * CadenceGEMConfiguration.packetBufferByteCount
            )
            if index == storage.receiveDescriptorCount - 1 {
                addressWord |= ReceiveDescriptor.wrap
            }
            dma.storeDescriptorWord(addressWord, at: descriptorAddress)
            dma.storeDescriptorWord(0, at: descriptorAddress + 4)
            index += 1
        }

        index = 0
        while index < storage.transmitDescriptorCount {
            let descriptorAddress = transmitDescriptorCPUAddress(at: index)
            let bufferDeviceAddress = UInt32(
                storage.transmitBuffers.mapping.deviceAddress
                    + UInt64(index)
                        * CadenceGEMConfiguration.packetBufferByteCount
            )
            dma.storeDescriptorWord(bufferDeviceAddress, at: descriptorAddress)
            var status = TransmitDescriptor.used
            if index == storage.transmitDescriptorCount - 1 {
                status |= TransmitDescriptor.wrap
            }
            dma.storeDescriptorWord(status, at: descriptorAddress + 4)
            index += 1
        }
        dma.synchronizeOwnership()

        registers.write32(
            configuredDMAValue(),
            at: CadenceGEMRegisterLayout.dmaConfiguration
        )
        registers.write32(
            UInt32(storage.receiveDescriptors.mapping.deviceAddress),
            at: CadenceGEMRegisterLayout.receiveQueuePointer
        )
        registers.write32(
            UInt32(storage.transmitDescriptors.mapping.deviceAddress),
            at: CadenceGEMRegisterLayout.transmitQueuePointer
        )
        return true
    }

    private mutating func recycleReceiveDescriptor(
        at index: UInt16,
        addressWord: UInt32
    ) -> Bool {
        let bufferAddress = receiveBufferCPUAddress(at: index)
        guard dma.cleanForDevice(
            cpuAddress: bufferAddress,
            byteCount: CadenceGEMConfiguration.packetBufferByteCount
        ) else {
            return false
        }
        let descriptorAddress = receiveDescriptorCPUAddress(at: index)
        dma.storeDescriptorWord(0, at: descriptorAddress + 4)
        dma.synchronizeOwnership()
        dma.storeDescriptorWord(
            addressWord & ~ReceiveDescriptor.ownedByCPU,
            at: descriptorAddress
        )
        dma.synchronizeOwnership()
        return true
    }

    private mutating func configureMACAddress() {
        let mac = configuration.macAddress
        let bottom = UInt32(mac.octet0)
            | UInt32(mac.octet1) << 8
            | UInt32(mac.octet2) << 16
            | UInt32(mac.octet3) << 24
        let top = UInt32(mac.octet4) | UInt32(mac.octet5) << 8
        registers.write32(bottom, at: CadenceGEMRegisterLayout.specificAddress1Bottom)
        registers.write32(top, at: CadenceGEMRegisterLayout.specificAddress1Top)
    }

    private mutating func configureNetworkForMDIO() {
        var value = registers.read32(
            at: CadenceGEMRegisterLayout.networkConfiguration
        )
        value &= ~NetworkConfiguration.ownedMask
        value |= NetworkConfiguration.fcsRemove
        value |= UInt32(configuration.mdcClockDividerEncoding) << 18
        registers.write32(value, at: CadenceGEMRegisterLayout.networkConfiguration)
    }

    private mutating func configureNetwork(linkMode: CadenceGEMLinkMode) {
        var value = registers.read32(
            at: CadenceGEMRegisterLayout.networkConfiguration
        )
        value &= ~(NetworkConfiguration.speed100
            | NetworkConfiguration.fullDuplex
            | NetworkConfiguration.gigabit)
        switch linkMode {
        case .megabit10HalfDuplex:
            break
        case .megabit10FullDuplex:
            value |= NetworkConfiguration.fullDuplex
        case .megabit100HalfDuplex:
            value |= NetworkConfiguration.speed100
        case .megabit100FullDuplex:
            value |= NetworkConfiguration.speed100
                | NetworkConfiguration.fullDuplex
        case .gigabitHalfDuplex:
            value |= NetworkConfiguration.gigabit
        case .gigabitFullDuplex:
            value |= NetworkConfiguration.gigabit
                | NetworkConfiguration.fullDuplex
        }
        registers.write32(value, at: CadenceGEMRegisterLayout.networkConfiguration)
    }

    private func configuredDMAValue() -> UInt32 {
        let current = registers.read32(at: CadenceGEMRegisterLayout.dmaConfiguration)
        return (current & ~DMAConfiguration.ownedMask)
            | DMAConfiguration.pollingValue
    }

    private mutating func readClause22(_ register: UInt8) -> UInt16? {
        guard waitForMDIOIdle() else { return nil }
        let command = UInt32(1) << 30
            | UInt32(2) << 28
            | UInt32(configuration.phyAddress) << 23
            | UInt32(register) << 18
            | UInt32(2) << 16
        registers.write32(command, at: CadenceGEMRegisterLayout.phyMaintenance)
        guard waitForMDIOIdle() else { return nil }
        return UInt16(truncatingIfNeeded: registers.read32(
            at: CadenceGEMRegisterLayout.phyMaintenance
        ))
    }

    private mutating func writeClause22(
        _ register: UInt8,
        value: UInt16
    ) -> Bool {
        guard waitForMDIOIdle() else { return false }
        let command = UInt32(1) << 30
            | UInt32(1) << 28
            | UInt32(configuration.phyAddress) << 23
            | UInt32(register) << 18
            | UInt32(2) << 16
            | UInt32(value)
        registers.write32(command, at: CadenceGEMRegisterLayout.phyMaintenance)
        return waitForMDIOIdle()
    }

    private func waitForMDIOIdle() -> Bool {
        var pollCount: UInt64 = 0
        while pollCount < configuration.maximumPollCount {
            if registers.read32(at: CadenceGEMRegisterLayout.networkStatus)
                & Clause22.managementIdle != 0 {
                return true
            }
            pollCount += 1
            registers.spinWaitHint()
        }
        return false
    }

    private mutating func disableController() {
        registers.write32(0, at: CadenceGEMRegisterLayout.networkControl)
        registers.write32(UInt32.max, at: CadenceGEMRegisterLayout.interruptDisable)
        registers.write32(UInt32.max, at: CadenceGEMRegisterLayout.transmitStatus)
        registers.write32(UInt32.max, at: CadenceGEMRegisterLayout.receiveStatus)
        _ = registers.read32(at: CadenceGEMRegisterLayout.interruptStatus)
    }

    private mutating func rejectInitialization(
        _ result: CadenceGEMInitializationResult
    ) -> CadenceGEMInitializationResult {
        state = .faulted
        return result
    }

    private mutating func failInitialization(
        _ result: CadenceGEMInitializationResult
    ) -> CadenceGEMInitializationResult {
        faultDevice()
        return result
    }

    private mutating func faultDevice() {
        state = .faulted
        registers.write32(0, at: CadenceGEMRegisterLayout.networkControl)
    }

    private func receiveDescriptorCPUAddress(at index: UInt16) -> UInt64 {
        storage.receiveDescriptors.mapping.cpuPhysicalAddress
            + UInt64(index) * CadenceGEMConfiguration.descriptorByteCount
    }

    private func transmitDescriptorCPUAddress(at index: UInt16) -> UInt64 {
        storage.transmitDescriptors.mapping.cpuPhysicalAddress
            + UInt64(index) * CadenceGEMConfiguration.descriptorByteCount
    }

    private func receiveBufferCPUAddress(at index: UInt16) -> UInt64 {
        storage.receiveBuffers.mapping.cpuPhysicalAddress
            + UInt64(index) * CadenceGEMConfiguration.packetBufferByteCount
    }

    private func transmitBufferCPUAddress(at index: UInt16) -> UInt64 {
        storage.transmitBuffers.mapping.cpuPhysicalAddress
            + UInt64(index) * CadenceGEMConfiguration.packetBufferByteCount
    }

    private static func invalidPHYIdentifier(
        _ identifier1: UInt16,
        _ identifier2: UInt16
    ) -> Bool {
        identifier1 == 0 || identifier1 == UInt16.max
            || identifier2 == 0 || identifier2 == UInt16.max
    }

    private static func nextIndex(_ index: UInt16, count: UInt16) -> UInt16 {
        index + 1 == count ? 0 : index + 1
    }
}
