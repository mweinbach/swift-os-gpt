/// Register geometry shared by every DesignWare USB 2.0 device-controller
/// integration. Board code supplies only the translated MMIO resource; the
/// controller driver never assumes a Raspberry Pi address.
enum DWC2RegisterLayout {
    static let minimumApertureLength: UInt64 = 0x4_004

    static let ahbConfiguration: UInt = 0x008
    static let usbConfiguration: UInt = 0x00c
    static let resetControl: UInt = 0x010
    static let interruptStatus: UInt = 0x014
    static let interruptMask: UInt = 0x018
    static let receiveStatusPeek: UInt = 0x01c
    static let receiveStatusPop: UInt = 0x020
    static let receiveFIFOSize: UInt = 0x024
    static let endpoint0TransmitFIFOSize: UInt = 0x028
    static let endpoint0TransmitFIFOStatus: UInt = 0x02c
    static let coreIdentifier: UInt = 0x040
    static let hardwareConfiguration2: UInt = 0x048
    static let hardwareConfiguration3: UInt = 0x04c
    static let hardwareConfiguration4: UInt = 0x050

    static let deviceConfiguration: UInt = 0x800
    static let deviceControl: UInt = 0x804
    static let deviceStatus: UInt = 0x808
    static let inEndpointInterruptMask: UInt = 0x810
    static let outEndpointInterruptMask: UInt = 0x814
    static let allEndpointInterrupts: UInt = 0x818
    static let allEndpointInterruptMask: UInt = 0x81c
    static let inEndpointFIFOEmptyMask: UInt = 0x834

    static func transmitFIFOSize(for endpoint: UInt8) -> UInt? {
        guard endpoint < 16 else { return nil }
        if endpoint == 0 { return endpoint0TransmitFIFOSize }
        return 0x104 + UInt(endpoint - 1) * 4
    }

    static func inEndpointControl(_ endpoint: UInt8) -> UInt? {
        endpointRegister(base: 0x900, endpoint: endpoint, member: 0)
    }

    static func inEndpointInterrupt(_ endpoint: UInt8) -> UInt? {
        endpointRegister(base: 0x900, endpoint: endpoint, member: 0x08)
    }

    static func inEndpointTransferSize(_ endpoint: UInt8) -> UInt? {
        endpointRegister(base: 0x900, endpoint: endpoint, member: 0x10)
    }

    static func inEndpointFIFOStatus(_ endpoint: UInt8) -> UInt? {
        endpointRegister(base: 0x900, endpoint: endpoint, member: 0x18)
    }

    static func outEndpointControl(_ endpoint: UInt8) -> UInt? {
        endpointRegister(base: 0xb00, endpoint: endpoint, member: 0)
    }

    static func outEndpointInterrupt(_ endpoint: UInt8) -> UInt? {
        endpointRegister(base: 0xb00, endpoint: endpoint, member: 0x08)
    }

    static func outEndpointTransferSize(_ endpoint: UInt8) -> UInt? {
        endpointRegister(base: 0xb00, endpoint: endpoint, member: 0x10)
    }

    static func fifoData(_ fifo: UInt8) -> UInt? {
        guard fifo < 16 else { return nil }
        return 0x1000 + UInt(fifo) * 0x1000
    }

    private static func endpointRegister(
        base: UInt,
        endpoint: UInt8,
        member: UInt
    ) -> UInt? {
        guard endpoint < 16 else { return nil }
        return base + UInt(endpoint) * 0x20 + member
    }
}

struct DWC2CoreIdentifier: Equatable {
    static let synopsysOTGSignature: UInt32 = 0x4f54_0000

    let rawValue: UInt32

    init?(rawValue: UInt32) {
        guard rawValue & 0xffff_0000 == Self.synopsysOTGSignature else {
            return nil
        }
        self.rawValue = rawValue
    }

    var revision: UInt16 {
        UInt16(truncatingIfNeeded: rawValue)
    }
}

enum DWC2OperationMode: UInt8, Equatable {
    case hnpAndSRPOTG = 0
    case srpOnlyOTG = 1
    case deviceAndHostWithoutHNPOrSRP = 2
    case srpCapableDevice = 3
    case deviceWithoutSRP = 4
    case srpCapableHost = 5
    case hostWithoutSRP = 6
    case undefined = 7

    var supportsDeviceMode: Bool {
        switch self {
        case .hnpAndSRPOTG, .srpOnlyOTG,
             .deviceAndHostWithoutHNPOrSRP,
             .srpCapableDevice, .deviceWithoutSRP:
            return true
        case .srpCapableHost, .hostWithoutSRP, .undefined:
            return false
        }
    }
}

enum DWC2BusArchitecture: UInt8, Equatable {
    case slaveOnly = 0
    case externalDMA = 1
    case internalDMA = 2
    case reserved = 3
}

/// Immutable capabilities read before the core is reset. The initial SwiftOS
/// driver intentionally operates in slave/PIO mode on every architecture so
/// USB bring-up does not depend on a board DMA or IOMMU contract.
struct DWC2HardwareCapabilities: Equatable {
    let operationMode: DWC2OperationMode
    let busArchitecture: DWC2BusArchitecture
    let deviceEndpointCount: UInt8
    let inEndpointCount: UInt8
    let fifoDepthInWords: UInt16
    let supportsDynamicFIFO: Bool
    let supportsDedicatedTransmitFIFOs: Bool

    init?(
        hardwareConfiguration2 configuration2: UInt32,
        hardwareConfiguration3 configuration3: UInt32,
        hardwareConfiguration4 configuration4: UInt32
    ) {
        guard let operationMode = DWC2OperationMode(
                  rawValue: UInt8(configuration2 & 0x7)
              ), operationMode.supportsDeviceMode,
              let busArchitecture = DWC2BusArchitecture(
                  rawValue: UInt8((configuration2 >> 3) & 0x3)
              ), busArchitecture != .reserved
        else {
            return nil
        }

        let nonControlEndpointCount = UInt8((configuration2 >> 10) & 0xf)
        let nonControlInEndpointCount = UInt8((configuration4 >> 26) & 0xf)
        let fifoDepth = UInt16(truncatingIfNeeded: configuration3 >> 16)
        guard nonControlEndpointCount < UInt8.max,
              nonControlInEndpointCount < UInt8.max,
              fifoDepth > 0
        else {
            return nil
        }

        self.operationMode = operationMode
        self.busArchitecture = busArchitecture
        deviceEndpointCount = nonControlEndpointCount + 1
        inEndpointCount = nonControlInEndpointCount + 1
        fifoDepthInWords = fifoDepth
        supportsDynamicFIFO = configuration2 & (1 << 19) != 0
        supportsDedicatedTransmitFIFOs = configuration4 & (1 << 25) != 0
    }

    var supportsSwiftOSDebugCompositeDevice: Bool {
        deviceEndpointCount >= 4
            && inEndpointCount >= 4
            && supportsDynamicFIFO
            && supportsDedicatedTransmitFIFOs
            && DWC2CompositeFIFOPlan(
                availableDepthInWords: fifoDepthInWords
            ) != nil
    }
}

struct DWC2FIFORegion: Equatable {
    let startWord: UInt16
    let depthInWords: UInt16

    init?(startWord: UInt16, depthInWords: UInt16) {
        guard depthInWords > 0 else { return nil }
        let end = UInt32(startWord) + UInt32(depthInWords)
        guard end <= UInt32(UInt16.max) else { return nil }
        self.startWord = startWord
        self.depthInWords = depthInWords
    }

    var endWord: UInt32 {
        UInt32(startWord) + UInt32(depthInWords)
    }

    var registerValue: UInt32 {
        UInt32(depthInWords) << 16 | UInt32(startWord)
    }
}

/// A fixed FIFO assignment for endpoint zero, CDC notification/data, and the
/// debug-display bulk endpoint. Larger cores devote the extra space to display
/// bursts; smaller valid cores retain a bounded 512-byte display FIFO.
struct DWC2CompositeFIFOPlan: Equatable {
    static let endpointCount: UInt8 = 4
    static let minimumDisplayDepthInWords: UInt16 = 128
    static let preferredDisplayDepthInWords: UInt16 = 1_024

    let receiveDepthInWords: UInt16
    let endpoint0Transmit: DWC2FIFORegion
    let cdcNotificationTransmit: DWC2FIFORegion
    let cdcDataTransmit: DWC2FIFORegion
    let debugDisplayTransmit: DWC2FIFORegion
    let consumedDepthInWords: UInt16

    init?(availableDepthInWords: UInt16) {
        let receiveDepth: UInt16 = availableDepthInWords >= 1_232 ? 512 : 256
        let endpoint0Depth: UInt16 = 64
        let notificationDepth: UInt16 = 16
        let cdcDataDepth: UInt16 = 128
        let fixed = UInt32(receiveDepth)
            + UInt32(endpoint0Depth)
            + UInt32(notificationDepth)
            + UInt32(cdcDataDepth)
        guard fixed <= UInt32(availableDepthInWords) else { return nil }
        let remaining = UInt32(availableDepthInWords) - fixed
        guard remaining >= UInt32(Self.minimumDisplayDepthInWords) else {
            return nil
        }
        let displayDepth = UInt16(
            remaining > UInt32(Self.preferredDisplayDepthInWords)
                ? UInt32(Self.preferredDisplayDepthInWords)
                : remaining
        )

        var start = receiveDepth
        guard let endpoint0 = DWC2FIFORegion(
                  startWord: start,
                  depthInWords: endpoint0Depth
              )
        else { return nil }
        start += endpoint0Depth
        guard let notification = DWC2FIFORegion(
                  startWord: start,
                  depthInWords: notificationDepth
              )
        else { return nil }
        start += notificationDepth
        guard let cdcData = DWC2FIFORegion(
                  startWord: start,
                  depthInWords: cdcDataDepth
              )
        else { return nil }
        start += cdcDataDepth
        guard let debugDisplay = DWC2FIFORegion(
                  startWord: start,
                  depthInWords: displayDepth
              ), debugDisplay.endWord <= UInt32(availableDepthInWords)
        else { return nil }

        receiveDepthInWords = receiveDepth
        endpoint0Transmit = endpoint0
        cdcNotificationTransmit = notification
        cdcDataTransmit = cdcData
        debugDisplayTransmit = debugDisplay
        consumedDepthInWords = UInt16(debugDisplay.endWord)
    }

    func transmitRegion(for endpoint: UInt8) -> DWC2FIFORegion? {
        switch endpoint {
        case 0: return endpoint0Transmit
        case 1: return cdcNotificationTransmit
        case 2: return cdcDataTransmit
        case 3: return debugDisplayTransmit
        default: return nil
        }
    }
}

enum DWC2ReceivePacketStatus: UInt8, Equatable {
    case globalOutNAK = 1
    case outDataReceived = 2
    case outTransferComplete = 3
    case setupTransactionComplete = 4
    case dataToggleError = 5
    case setupDataReceived = 6
}

/// One device-mode receive status entry popped from the controller FIFO.
/// Structural validation rejects malformed setup/completion records before a
/// byte count is ever used to drain the FIFO.
struct DWC2ReceiveStatus: Equatable {
    let endpoint: UInt8
    let byteCount: UInt16
    let dataPID: UInt8
    let packetStatus: DWC2ReceivePacketStatus
    let frameNumber: UInt8

    init?(rawValue: UInt32, maximumEndpointNumber: UInt8 = 15) {
        let endpoint = UInt8(rawValue & 0xf)
        let byteCount = UInt16((rawValue >> 4) & 0x7ff)
        let dataPID = UInt8((rawValue >> 15) & 0x3)
        guard endpoint <= maximumEndpointNumber,
              let packetStatus = DWC2ReceivePacketStatus(
                  rawValue: UInt8((rawValue >> 17) & 0xf)
              )
        else {
            return nil
        }

        switch packetStatus {
        case .setupDataReceived:
            guard endpoint == 0, byteCount == 8 else { return nil }
        case .globalOutNAK, .outTransferComplete,
             .setupTransactionComplete, .dataToggleError:
            guard byteCount == 0 else { return nil }
        case .outDataReceived:
            break
        }

        self.endpoint = endpoint
        self.byteCount = byteCount
        self.dataPID = dataPID
        self.packetStatus = packetStatus
        frameNumber = UInt8((rawValue >> 25) & 0x7f)
    }
}

enum DWC2TransferSize {
    static let endpoint0SetupReception: UInt32 = 3 << 29 | 1 << 19 | 64

    static func endpoint0In(byteCount: UInt16) -> UInt32? {
        guard byteCount <= 64 else { return nil }
        return 1 << 19 | UInt32(byteCount)
    }

    static func endpoint0Out(byteCount: UInt16) -> UInt32? {
        guard byteCount <= 64 else { return nil }
        return 1 << 19 | UInt32(byteCount)
    }

    static func bulk(byteCount: UInt32, maximumPacketSize: UInt16) -> UInt32? {
        guard byteCount > 0,
              byteCount <= 0x7ffff,
              maximumPacketSize > 0,
              maximumPacketSize <= 1_024
        else {
            return nil
        }
        let packets = (byteCount + UInt32(maximumPacketSize) - 1)
            / UInt32(maximumPacketSize)
        guard packets > 0, packets <= 0x3ff else { return nil }
        return packets << 19 | byteCount
    }
}

enum DWC2CoreBits {
    static let ahbGlobalInterruptEnable: UInt32 = 1 << 0
    static let ahbDMAEnable: UInt32 = 1 << 5

    static let forceHostMode: UInt32 = 1 << 29
    static let forceDeviceMode: UInt32 = 1 << 30

    static let coreSoftReset: UInt32 = 1 << 0
    static let receiveFIFOFlush: UInt32 = 1 << 4
    static let transmitFIFOFlush: UInt32 = 1 << 5
    static let allTransmitFIFOs: UInt32 = 0x10 << 6
    static let ahbIdle: UInt32 = 1 << 31

    static let receiveFIFOLevelInterrupt: UInt32 = 1 << 4
    static let usbSuspendInterrupt: UInt32 = 1 << 11
    static let usbResetInterrupt: UInt32 = 1 << 12
    static let enumerationDoneInterrupt: UInt32 = 1 << 13
    static let inEndpointInterrupt: UInt32 = 1 << 18
    static let outEndpointInterrupt: UInt32 = 1 << 19
    static let wakeupInterrupt: UInt32 = 1 << 31
    static let deviceModeInterrupts = receiveFIFOLevelInterrupt
        | usbSuspendInterrupt
        | usbResetInterrupt
        | enumerationDoneInterrupt
        | inEndpointInterrupt
        | outEndpointInterrupt
        | wakeupInterrupt

    static let endpointEnable: UInt32 = 1 << 31
    static let endpointDisable: UInt32 = 1 << 30
    static let setData0PID: UInt32 = 1 << 28
    static let setNAK: UInt32 = 1 << 27
    static let clearNAK: UInt32 = 1 << 26
    static let endpointFIFOShift: UInt32 = 22
    static let endpointStall: UInt32 = 1 << 21
    static let endpointTypeBulk: UInt32 = 2 << 18
    static let endpointTypeInterrupt: UInt32 = 3 << 18
    static let endpointActive: UInt32 = 1 << 15
    static let endpointTransferComplete: UInt32 = 1 << 0
    static let setupPhaseDone: UInt32 = 1 << 3

    static let deviceAddressMask: UInt32 = 0x7f << 4
    static let softDisconnect: UInt32 = 1 << 1
}
