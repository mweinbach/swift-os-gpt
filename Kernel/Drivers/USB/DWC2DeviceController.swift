protocol DWC2RegisterAccess {
    mutating func read32(at offset: UInt) -> UInt32
    mutating func write32(_ value: UInt32, at offset: UInt)
    mutating func settleAfterModeChange() -> Bool
    mutating func settleAfterPowerOnProgramming() -> Bool
}

extension DWC2RegisterAccess {
    mutating func settleAfterModeChange() -> Bool { true }
    mutating func settleAfterPowerOnProgramming() -> Bool { true }
}

enum DWC2ControllerState: UInt8, Equatable {
    case cold
    case disconnected
    case connected
    case configured
    case faulted
}

enum DWC2InitializationResult: Equatable {
    case ready(DWC2HardwareCapabilities)
    case invalidPollLimit
    case unsupportedCore
    case unsupportedConfiguration
    case ahbNotIdle
    case coreResetTimedOut
    case deviceModeTimedOut
    case powerOnProgrammingTimedOut
    case transmitFIFOFlushTimedOut
    case receiveFIFOFlushTimedOut
    case invalidState
}

enum DWC2BusSpeed: UInt8, Equatable {
    case high = 0
    case full = 1
    case low = 2
    case fullSpeed48MHz = 3

    init(deviceStatus: UInt32) {
        self = DWC2BusSpeed(rawValue: UInt8((deviceStatus >> 1) & 0x3))
            ?? .full
    }

    var bulkMaximumPacketSize: UInt16 {
        self == .high ? 512 : 64
    }
}

struct DWC2InterruptSnapshot: Equatable {
    let global: UInt32
    let endpoint: UInt32
    let busSpeed: DWC2BusSpeed

    var hasReceiveFIFOEntry: Bool {
        global & DWC2CoreBits.receiveFIFOLevelInterrupt != 0
    }

    var didReset: Bool {
        global & DWC2CoreBits.usbResetInterrupt != 0
    }

    var didEnumerate: Bool {
        global & DWC2CoreBits.enumerationDoneInterrupt != 0
    }

    var didSuspend: Bool {
        global & DWC2CoreBits.usbSuspendInterrupt != 0
    }

    var didWake: Bool {
        global & DWC2CoreBits.wakeupInterrupt != 0
    }

    func hasInEndpointInterrupt(_ endpointNumber: UInt8) -> Bool {
        endpointNumber < 16 && endpoint & (1 << UInt32(endpointNumber)) != 0
    }

    func hasOutEndpointInterrupt(_ endpointNumber: UInt8) -> Bool {
        endpointNumber < 16
            && endpoint & (1 << UInt32(endpointNumber + 16)) != 0
    }
}

enum DWC2ReceiveResult: Equatable {
    case noPacket
    case packet(
        status: DWC2ReceiveStatus,
        copiedByteCount: UInt16,
        wasTruncated: Bool
    )
    case malformedStatus(rawValue: UInt32, drainedByteCount: UInt16)
}

enum DWC2TransferResult: Equatable {
    case queued
    case invalidState
    case invalidEndpoint
    case invalidBuffer
    case invalidTransferSize
    case fifoBusy
}

/// Polling DWC2 device-mode engine. It owns register and FIFO mechanics only;
/// USB descriptors, control-request policy, and the debug-display protocol are
/// kept in device-neutral layers above it.
struct DWC2Controller<Registers: DWC2RegisterAccess> {
    static var readyMarker: StaticString { "SWIFTOS:USB_DWC2_READY\n" }

    private var registers: Registers
    private(set) var state: DWC2ControllerState = .cold
    private(set) var capabilities: DWC2HardwareCapabilities?
    private(set) var fifoPlan: DWC2CompositeFIFOPlan?
    private(set) var busSpeed: DWC2BusSpeed = .full

    init(registers: Registers) {
        self.registers = registers
    }

    mutating func inspectHardware() -> DWC2HardwareCapabilities? {
        guard DWC2CoreIdentifier(
                  rawValue: read(DWC2RegisterLayout.coreIdentifier)
              ) != nil
        else {
            return nil
        }
        return DWC2HardwareCapabilities(
            hardwareConfiguration2: read(
                DWC2RegisterLayout.hardwareConfiguration2
            ),
            hardwareConfiguration3: read(
                DWC2RegisterLayout.hardwareConfiguration3
            ),
            hardwareConfiguration4: read(
                DWC2RegisterLayout.hardwareConfiguration4
            )
        )
    }

    mutating func initialize(
        maximumPollCount: Int = 100_000
    ) -> DWC2InitializationResult {
        guard maximumPollCount > 0 else { return .invalidPollLimit }
        guard state == .cold else { return .invalidState }
        guard DWC2CoreIdentifier(
                  rawValue: read(DWC2RegisterLayout.coreIdentifier)
              ) != nil
        else {
            state = .faulted
            return .unsupportedCore
        }
        guard let capabilities = inspectHardware(),
              capabilities.supportsSwiftOSDebugCompositeDevice,
              let fifoPlan = DWC2CompositeFIFOPlan(
                  availableDepthInWords: capabilities.fifoDepthInWords
              )
        else {
            state = .faulted
            return .unsupportedConfiguration
        }

        var deviceControl = read(DWC2RegisterLayout.deviceControl)
        deviceControl &= ~DWC2CoreBits.deviceControlCommandMask
        deviceControl |= DWC2CoreBits.softDisconnect
        write(deviceControl, DWC2RegisterLayout.deviceControl)

        var ahb = read(DWC2RegisterLayout.ahbConfiguration)
        ahb &= ~(
            DWC2CoreBits.ahbDMAEnable
                | DWC2CoreBits.ahbGlobalInterruptEnable
        )
        write(ahb, DWC2RegisterLayout.ahbConfiguration)

        guard waitForSet(
                  offset: DWC2RegisterLayout.resetControl,
                  mask: DWC2CoreBits.ahbIdle,
                  maximumPollCount: maximumPollCount
              )
        else {
            state = .faulted
            return .ahbNotIdle
        }
        write(
            DWC2CoreBits.coreSoftReset,
            DWC2RegisterLayout.resetControl
        )
        guard waitForClear(
                  offset: DWC2RegisterLayout.resetControl,
                  mask: DWC2CoreBits.coreSoftReset,
                  maximumPollCount: maximumPollCount
              ), waitForSet(
                  offset: DWC2RegisterLayout.resetControl,
                  mask: DWC2CoreBits.ahbIdle,
                  maximumPollCount: maximumPollCount
              )
        else {
            state = .faulted
            return .coreResetTimedOut
        }

        guard let utmiBitCount = capabilities.utmiDataWidth.selectedBitCount
        else {
            state = .faulted
            return .unsupportedConfiguration
        }
        var usb = read(DWC2RegisterLayout.usbConfiguration)
        usb &= ~(
            DWC2CoreBits.forceHostMode
                | DWC2CoreBits.forceDeviceMode
                | DWC2CoreBits.usbTimeoutCalibrationMask
                | DWC2CoreBits.usbPHYInterface16
                | DWC2CoreBits.usbULPIUTMISelect
                | DWC2CoreBits.usbFullSpeedPHYSelect
                | DWC2CoreBits.usbDDRSelect
                | DWC2CoreBits.usbSRPCapable
                | DWC2CoreBits.usbHNPCapable
                | DWC2CoreBits.usbTurnaroundTimeMask
        )
        usb |= 7 | DWC2CoreBits.forceDeviceMode
        if utmiBitCount == 16 {
            usb |= DWC2CoreBits.usbPHYInterface16 | 5 << 10
        } else {
            usb |= 9 << 10
        }
        write(usb, DWC2RegisterLayout.usbConfiguration)
        guard registers.settleAfterModeChange(),
              waitForClear(
                  offset: DWC2RegisterLayout.interruptStatus,
                  mask: 1,
                  maximumPollCount: maximumPollCount
              )
        else {
            state = .faulted
            return .deviceModeTimedOut
        }

        write(
            UInt32(fifoPlan.receiveDepthInWords),
            DWC2RegisterLayout.receiveFIFOSize
        )
        var endpoint: UInt8 = 0
        while endpoint < DWC2CompositeFIFOPlan.endpointCount {
            guard let registerOffset = DWC2RegisterLayout.transmitFIFOSize(
                      for: endpoint
                  ), let region = fifoPlan.transmitRegion(for: endpoint)
            else {
                state = .faulted
                return .unsupportedConfiguration
            }
            write(region.registerValue, registerOffset)
            endpoint += 1
        }
        guard fifoPlan.consumedDepthInWords <= capabilities.fifoDepthInWords
        else {
            state = .faulted
            return .unsupportedConfiguration
        }
        write(
            UInt32(fifoPlan.consumedDepthInWords) << 16
                | UInt32(capabilities.fifoDepthInWords),
            DWC2RegisterLayout.globalDFIFOConfiguration
        )

        write(
            DWC2CoreBits.transmitFIFOFlush
                | DWC2CoreBits.allTransmitFIFOs,
            DWC2RegisterLayout.resetControl
        )
        guard waitForClear(
                  offset: DWC2RegisterLayout.resetControl,
                  mask: DWC2CoreBits.transmitFIFOFlush,
                  maximumPollCount: maximumPollCount
              )
        else {
            state = .faulted
            return .transmitFIFOFlushTimedOut
        }
        write(
            DWC2CoreBits.receiveFIFOFlush,
            DWC2RegisterLayout.resetControl
        )
        guard waitForClear(
                  offset: DWC2RegisterLayout.resetControl,
                  mask: DWC2CoreBits.receiveFIFOFlush,
                  maximumPollCount: maximumPollCount
              )
        else {
            state = .faulted
            return .receiveFIFOFlushTimedOut
        }

        var deviceConfiguration = read(
            DWC2RegisterLayout.deviceConfiguration
        )
        deviceConfiguration &= ~(DWC2CoreBits.deviceAddressMask | 0x3)
        write(deviceConfiguration, DWC2RegisterLayout.deviceConfiguration)

        write(0, DWC2RegisterLayout.inEndpointInterruptMask)
        write(0, DWC2RegisterLayout.outEndpointInterruptMask)
        write(0, DWC2RegisterLayout.allEndpointInterruptMask)
        write(0, DWC2RegisterLayout.inEndpointFIFOEmptyMask)
        write(UInt32.max, DWC2RegisterLayout.interruptStatus)
        write(
            DWC2CoreBits.deviceModeInterrupts,
            DWC2RegisterLayout.interruptMask
        )
        // Core reset may restore DCTL independently of the pre-reset write.
        // Reassert disconnect only after every endpoint/FIFO mask is safe so
        // the host can never observe a half-configured default device.
        deviceControl = read(DWC2RegisterLayout.deviceControl)
        deviceControl &= ~(
            DWC2CoreBits.deviceControlCommandMask
                | DWC2CoreBits.powerOnProgrammingDone
        )
        deviceControl |= DWC2CoreBits.softDisconnect
        write(
            deviceControl | DWC2CoreBits.powerOnProgrammingDone,
            DWC2RegisterLayout.deviceControl
        )
        guard registers.settleAfterPowerOnProgramming() else {
            state = .faulted
            return .powerOnProgrammingTimedOut
        }
        write(deviceControl, DWC2RegisterLayout.deviceControl)
        write(
            deviceControl
                | DWC2CoreBits.clearGlobalOutNAK
                | DWC2CoreBits.clearGlobalNonPeriodicInNAK,
            DWC2RegisterLayout.deviceControl
        )

        self.capabilities = capabilities
        self.fifoPlan = fifoPlan
        state = .disconnected
        return .ready(capabilities)
    }

    mutating func connect() -> Bool {
        guard state == .disconnected else { return false }
        var control = read(DWC2RegisterLayout.deviceControl)
        control &= ~DWC2CoreBits.deviceControlCommandMask
        control &= ~DWC2CoreBits.softDisconnect
        write(control, DWC2RegisterLayout.deviceControl)
        state = .connected
        return true
    }

    mutating func disconnect() {
        guard state == .connected || state == .configured else { return }
        var control = read(DWC2RegisterLayout.deviceControl)
        control &= ~DWC2CoreBits.deviceControlCommandMask
        control |= DWC2CoreBits.softDisconnect
        write(control, DWC2RegisterLayout.deviceControl)
        write(0, DWC2RegisterLayout.allEndpointInterruptMask)
        state = .disconnected
    }

    mutating func interruptSnapshot() -> DWC2InterruptSnapshot {
        let global = read(DWC2RegisterLayout.interruptStatus)
            & read(DWC2RegisterLayout.interruptMask)
        let endpoint = read(DWC2RegisterLayout.allEndpointInterrupts)
            & read(DWC2RegisterLayout.allEndpointInterruptMask)
        return DWC2InterruptSnapshot(
            global: global,
            endpoint: endpoint,
            busSpeed: DWC2BusSpeed(
                deviceStatus: read(DWC2RegisterLayout.deviceStatus)
            )
        )
    }

    /// Acknowledges only edge/status sources. RXFLVL is level-sensitive and is
    /// cleared by draining receive-status entries, so it is never written back.
    mutating func acknowledgeGlobalInterrupts(_ mask: UInt32) {
        write(
            mask & ~DWC2CoreBits.receiveFIFOLevelInterrupt,
            DWC2RegisterLayout.interruptStatus
        )
    }

    mutating func handleBusReset(
        maximumPollCount: Int = 100_000
    ) -> Bool {
        guard state == .connected || state == .configured,
              maximumPollCount > 0
        else { return false }
        quiesceNonControlEndpoints()
        write(
            DWC2CoreBits.transmitFIFOFlush
                | DWC2CoreBits.allTransmitFIFOs,
            DWC2RegisterLayout.resetControl
        )
        guard waitForClear(
                  offset: DWC2RegisterLayout.resetControl,
                  mask: DWC2CoreBits.transmitFIFOFlush,
                  maximumPollCount: maximumPollCount
              )
        else { return false }
        write(DWC2CoreBits.receiveFIFOFlush, DWC2RegisterLayout.resetControl)
        guard waitForClear(
                  offset: DWC2RegisterLayout.resetControl,
                  mask: DWC2CoreBits.receiveFIFOFlush,
                  maximumPollCount: maximumPollCount
              )
        else { return false }
        setDeviceAddress(0)
        write(0, DWC2RegisterLayout.inEndpointInterruptMask)
        write(0, DWC2RegisterLayout.outEndpointInterruptMask)
        write(0x0001_0001, DWC2RegisterLayout.allEndpointInterruptMask)
        var endpoint: UInt8 = 0
        while endpoint < DWC2CompositeFIFOPlan.endpointCount {
            clearEndpointInterrupts(endpoint: endpoint)
            endpoint += 1
        }

        guard let inControl = DWC2RegisterLayout.inEndpointControl(0),
              let outControl = DWC2RegisterLayout.outEndpointControl(0)
        else {
            state = .faulted
            return false
        }
        write(
            DWC2CoreBits.endpointActive | DWC2CoreBits.setNAK,
            inControl
        )
        write(
            DWC2CoreBits.endpointActive | DWC2CoreBits.setNAK,
            outControl
        )
        write(
            DWC2CoreBits.endpointTransferComplete,
            DWC2RegisterLayout.inEndpointInterruptMask
        )
        write(
            DWC2CoreBits.endpointTransferComplete
                | DWC2CoreBits.setupPhaseDone,
            DWC2RegisterLayout.outEndpointInterruptMask
        )
        state = .connected
        return armEndpoint0ForSetup()
    }

    mutating func handleEnumerationDone() {
        busSpeed = DWC2BusSpeed(
            deviceStatus: read(DWC2RegisterLayout.deviceStatus)
        )
    }

    mutating func armEndpoint0ForSetup(
        preservingStall: Bool = false
    ) -> Bool {
        guard state == .connected || state == .configured,
              let transferSize = DWC2RegisterLayout.outEndpointTransferSize(0),
              let control = DWC2RegisterLayout.outEndpointControl(0)
        else {
            return false
        }
        write(DWC2TransferSize.endpoint0SetupReception, transferSize)
        var endpointControl = read(control)
        if !preservingStall {
            endpointControl &= ~DWC2CoreBits.endpointStall
        }
        endpointControl |= DWC2CoreBits.endpointEnable
            | DWC2CoreBits.clearNAK
            | DWC2CoreBits.endpointActive
        write(endpointControl, control)
        return true
    }

    mutating func clearEndpoint0Stall() {
        guard let input = DWC2RegisterLayout.inEndpointControl(0),
              let output = DWC2RegisterLayout.outEndpointControl(0)
        else { return }
        write(read(input) & ~DWC2CoreBits.endpointStall, input)
        write(read(output) & ~DWC2CoreBits.endpointStall, output)
    }

    mutating func armEndpoint0Out(byteCount: UInt16) -> Bool {
        guard state == .connected || state == .configured,
              let encoded = DWC2TransferSize.endpoint0Out(
                  byteCount: byteCount
              ), let transferSize = DWC2RegisterLayout.outEndpointTransferSize(0),
              let control = DWC2RegisterLayout.outEndpointControl(0)
        else {
            return false
        }
        write(encoded, transferSize)
        var endpointControl = read(control)
        endpointControl &= ~DWC2CoreBits.endpointStall
        endpointControl |= DWC2CoreBits.endpointEnable
            | DWC2CoreBits.clearNAK
            | DWC2CoreBits.endpointActive
        write(endpointControl, control)
        return true
    }

    mutating func configureCompositeEndpoints() -> Bool {
        guard state == .connected,
              let capabilities,
              capabilities.supportsSwiftOSDebugCompositeDevice
        else {
            return false
        }
        let bulkPacketSize = busSpeed.bulkMaximumPacketSize
        guard configureInEndpoint(
                  1,
                  maximumPacketSize: 16,
                  type: DWC2CoreBits.endpointTypeInterrupt
              ), configureInEndpoint(
                  2,
                  maximumPacketSize: bulkPacketSize,
                  type: DWC2CoreBits.endpointTypeBulk
              ), configureOutEndpoint(
                  2,
                  maximumPacketSize: bulkPacketSize,
                  type: DWC2CoreBits.endpointTypeBulk
              ), configureInEndpoint(
                  3,
                  maximumPacketSize: bulkPacketSize,
                  type: DWC2CoreBits.endpointTypeBulk
              ), configureOutEndpoint(
                  3,
                  maximumPacketSize: bulkPacketSize,
                  type: DWC2CoreBits.endpointTypeBulk
              )
        else {
            return false
        }

        let inMask: UInt32 = 0xf
        let outMask: UInt32 = (1 << 0) | (1 << 2) | (1 << 3)
        write(inMask | outMask << 16, DWC2RegisterLayout.allEndpointInterruptMask)
        state = .configured
        return true
    }

    mutating func deconfigureCompositeEndpoints(
        maximumPollCount: Int = 100_000
    ) -> Bool {
        guard state == .configured, maximumPollCount > 0 else { return false }
        quiesceNonControlEndpoints()
        write(0x0001_0001, DWC2RegisterLayout.allEndpointInterruptMask)
        write(
            DWC2CoreBits.transmitFIFOFlush
                | DWC2CoreBits.allTransmitFIFOs,
            DWC2RegisterLayout.resetControl
        )
        guard waitForClear(
                  offset: DWC2RegisterLayout.resetControl,
                  mask: DWC2CoreBits.transmitFIFOFlush,
                  maximumPollCount: maximumPollCount
              )
        else { return false }
        write(DWC2CoreBits.receiveFIFOFlush, DWC2RegisterLayout.resetControl)
        guard waitForClear(
                  offset: DWC2RegisterLayout.resetControl,
                  mask: DWC2CoreBits.receiveFIFOFlush,
                  maximumPollCount: maximumPollCount
              )
        else { return false }
        var endpoint: UInt8 = 1
        while endpoint < DWC2CompositeFIFOPlan.endpointCount {
            clearEndpointInterrupts(endpoint: endpoint)
            endpoint += 1
        }
        state = .connected
        return true
    }

    mutating func setDeviceAddress(_ address: UInt8) {
        guard address <= 127 else { return }
        var configuration = read(DWC2RegisterLayout.deviceConfiguration)
        configuration &= ~DWC2CoreBits.deviceAddressMask
        configuration |= UInt32(address) << 4
        write(configuration, DWC2RegisterLayout.deviceConfiguration)
    }

    mutating func setEndpointHalt(
        endpointAddress: UInt8,
        halted: Bool
    ) -> Bool {
        guard state == .configured else { return false }
        let endpoint = endpointAddress & 0x0f
        guard endpoint > 0, endpoint < DWC2CompositeFIFOPlan.endpointCount
        else { return false }
        let directionIn = endpointAddress & 0x80 != 0
        let offset = directionIn
            ? DWC2RegisterLayout.inEndpointControl(endpoint)
            : DWC2RegisterLayout.outEndpointControl(endpoint)
        guard let offset else { return false }
        var control = read(offset)
        if halted {
            control |= DWC2CoreBits.endpointStall
        } else {
            control &= ~DWC2CoreBits.endpointStall
            control |= DWC2CoreBits.setData0PID
        }
        write(control, offset)
        return true
    }

    mutating func stallEndpoint0() {
        guard let input = DWC2RegisterLayout.inEndpointControl(0),
              let output = DWC2RegisterLayout.outEndpointControl(0)
        else {
            return
        }
        write(read(input) | DWC2CoreBits.endpointStall, input)
        write(read(output) | DWC2CoreBits.endpointStall, output)
    }

    mutating func pollReceive(
        into destination: UnsafeMutableRawBufferPointer
    ) -> DWC2ReceiveResult {
        let pending = read(DWC2RegisterLayout.interruptStatus)
        guard pending & DWC2CoreBits.receiveFIFOLevelInterrupt != 0 else {
            return .noPacket
        }
        let rawStatus = read(DWC2RegisterLayout.receiveStatusPop)
        let rawByteCount = UInt16((rawStatus >> 4) & 0x7ff)
        let copyCount = destination.count < Int(rawByteCount)
            ? destination.count
            : Int(rawByteCount)
        drainReceiveFIFO(
            byteCount: rawByteCount,
            into: destination,
            copyCount: copyCount
        )
        guard let status = DWC2ReceiveStatus(
                  rawValue: rawStatus,
                  maximumEndpointNumber: maximumEndpointNumber
              )
        else {
            return .malformedStatus(
                rawValue: rawStatus,
                drainedByteCount: rawByteCount
            )
        }
        return .packet(
            status: status,
            copiedByteCount: UInt16(copyCount),
            wasTruncated: copyCount < Int(rawByteCount)
        )
    }

    mutating func queueInTransfer(
        endpoint: UInt8,
        bytes: UnsafeRawBufferPointer
    ) -> DWC2TransferResult {
        guard state == .connected || state == .configured else {
            return .invalidState
        }
        guard endpoint < maximumEndpointNumber + 1,
              let control = DWC2RegisterLayout.inEndpointControl(endpoint),
              let transferSize = DWC2RegisterLayout.inEndpointTransferSize(
                  endpoint
              ), let fifo = DWC2RegisterLayout.fifoData(endpoint)
        else {
            return .invalidEndpoint
        }
        guard bytes.count == 0 || bytes.baseAddress != nil else {
            return .invalidBuffer
        }

        let encodedTransfer: UInt32
        if endpoint == 0 {
            guard bytes.count <= 64,
                  let encoded = DWC2TransferSize.endpoint0In(
                      byteCount: UInt16(bytes.count)
                  )
            else {
                return .invalidTransferSize
            }
            encodedTransfer = encoded
        } else {
            guard bytes.count > 0,
                  bytes.count <= Int(UInt32.max),
                  let encoded = DWC2TransferSize.bulk(
                      byteCount: UInt32(bytes.count),
                      maximumPacketSize: endpoint == 1
                          ? 16
                          : busSpeed.bulkMaximumPacketSize
                  )
            else {
                return .invalidTransferSize
            }
            encodedTransfer = encoded
        }

        let wordCount = (bytes.count + 3) / 4
        if endpoint == 0 {
            let status = DWC2NonPeriodicTransmitStatus(
                rawValue: read(
                    DWC2RegisterLayout.endpoint0TransmitFIFOStatus
                )
            )
            guard status.canQueue(wordCount: wordCount) else {
                return .fifoBusy
            }
        } else {
            guard let fifoStatus = DWC2RegisterLayout.inEndpointFIFOStatus(
                      endpoint
                  ), wordCount <= Int(read(fifoStatus) & 0xffff)
            else { return .fifoBusy }
        }
        write(encodedTransfer, transferSize)
        var endpointControl = read(control)
        endpointControl &= ~DWC2CoreBits.endpointStall
        endpointControl |= DWC2CoreBits.endpointEnable
            | DWC2CoreBits.clearNAK
            | DWC2CoreBits.endpointActive
        write(endpointControl, control)
        writeTransmitFIFO(bytes: bytes, wordCount: wordCount, fifo: fifo)
        return .queued
    }

    mutating func armOutTransfer(
        endpoint: UInt8,
        byteCount: UInt32
    ) -> DWC2TransferResult {
        guard state == .configured else { return .invalidState }
        guard endpoint == 2 || endpoint == 3,
              let control = DWC2RegisterLayout.outEndpointControl(endpoint),
              let transferSize = DWC2RegisterLayout.outEndpointTransferSize(
                  endpoint
              )
        else {
            return .invalidEndpoint
        }
        guard let encoded = DWC2TransferSize.bulk(
                  byteCount: byteCount,
                  maximumPacketSize: busSpeed.bulkMaximumPacketSize
              )
        else {
            return .invalidTransferSize
        }
        write(encoded, transferSize)
        var endpointControl = read(control)
        endpointControl &= ~DWC2CoreBits.endpointStall
        endpointControl |= DWC2CoreBits.endpointEnable
            | DWC2CoreBits.clearNAK
            | DWC2CoreBits.endpointActive
        write(endpointControl, control)
        return .queued
    }

    mutating func endpointInterruptStatus(
        endpoint: UInt8,
        directionIn: Bool
    ) -> UInt32? {
        let offset = directionIn
            ? DWC2RegisterLayout.inEndpointInterrupt(endpoint)
            : DWC2RegisterLayout.outEndpointInterrupt(endpoint)
        guard let offset else { return nil }
        return read(offset)
    }

    mutating func acknowledgeEndpointInterrupts(
        endpoint: UInt8,
        directionIn: Bool,
        mask: UInt32
    ) {
        let offset = directionIn
            ? DWC2RegisterLayout.inEndpointInterrupt(endpoint)
            : DWC2RegisterLayout.outEndpointInterrupt(endpoint)
        guard let offset else { return }
        write(mask, offset)
    }

    private var maximumEndpointNumber: UInt8 {
        guard let count = capabilities?.deviceEndpointCount, count > 0 else {
            return 0
        }
        return count - 1
    }

    private mutating func configureInEndpoint(
        _ endpoint: UInt8,
        maximumPacketSize: UInt16,
        type: UInt32
    ) -> Bool {
        guard endpoint > 0,
              endpoint < 16,
              maximumPacketSize <= 0x7ff,
              let control = DWC2RegisterLayout.inEndpointControl(endpoint),
              let interrupt = DWC2RegisterLayout.inEndpointInterrupt(endpoint)
        else {
            return false
        }
        write(UInt32.max, interrupt)
        let value = DWC2CoreBits.endpointActive
            | DWC2CoreBits.setNAK
            | DWC2CoreBits.setData0PID
            | type
            | UInt32(endpoint) << DWC2CoreBits.endpointFIFOShift
            | UInt32(maximumPacketSize)
        write(value, control)
        return true
    }

    private mutating func configureOutEndpoint(
        _ endpoint: UInt8,
        maximumPacketSize: UInt16,
        type: UInt32
    ) -> Bool {
        guard endpoint > 0,
              endpoint < 16,
              maximumPacketSize <= 0x7ff,
              let control = DWC2RegisterLayout.outEndpointControl(endpoint),
              let interrupt = DWC2RegisterLayout.outEndpointInterrupt(endpoint)
        else {
            return false
        }
        write(UInt32.max, interrupt)
        let value = DWC2CoreBits.endpointActive
            | DWC2CoreBits.setNAK
            | DWC2CoreBits.setData0PID
            | type
            | UInt32(maximumPacketSize)
        write(value, control)
        return true
    }

    private mutating func clearEndpointInterrupts(endpoint: UInt8) {
        guard let input = DWC2RegisterLayout.inEndpointInterrupt(endpoint),
              let output = DWC2RegisterLayout.outEndpointInterrupt(endpoint)
        else {
            return
        }
        write(UInt32.max, input)
        write(UInt32.max, output)
    }

    private mutating func quiesceNonControlEndpoints() {
        var endpoint: UInt8 = 1
        while endpoint < DWC2CompositeFIFOPlan.endpointCount {
            if let input = DWC2RegisterLayout.inEndpointControl(endpoint) {
                var control = read(input) | DWC2CoreBits.setNAK
                if control & DWC2CoreBits.endpointEnable != 0 {
                    control |= DWC2CoreBits.endpointDisable
                }
                write(control, input)
            }
            if endpoint != 1,
               let output = DWC2RegisterLayout.outEndpointControl(endpoint) {
                var control = read(output) | DWC2CoreBits.setNAK
                if control & DWC2CoreBits.endpointEnable != 0 {
                    control |= DWC2CoreBits.endpointDisable
                }
                write(control, output)
            }
            endpoint += 1
        }
    }

    private mutating func drainReceiveFIFO(
        byteCount: UInt16,
        into destination: UnsafeMutableRawBufferPointer,
        copyCount: Int
    ) {
        guard let fifo = DWC2RegisterLayout.fifoData(0) else { return }
        let words = (Int(byteCount) + 3) / 4
        var wordIndex = 0
        while wordIndex < words {
            let word = read(fifo)
            var byteIndex = 0
            while byteIndex < 4 {
                let outputIndex = wordIndex * 4 + byteIndex
                if outputIndex < copyCount {
                    destination[outputIndex] = UInt8(
                        truncatingIfNeeded: word >> UInt32(byteIndex * 8)
                    )
                }
                byteIndex += 1
            }
            wordIndex += 1
        }
    }

    private mutating func writeTransmitFIFO(
        bytes: UnsafeRawBufferPointer,
        wordCount: Int,
        fifo: UInt
    ) {
        var wordIndex = 0
        while wordIndex < wordCount {
            var word: UInt32 = 0
            var byteIndex = 0
            while byteIndex < 4 {
                let inputIndex = wordIndex * 4 + byteIndex
                if inputIndex < bytes.count {
                    word |= UInt32(bytes[inputIndex]) << UInt32(byteIndex * 8)
                }
                byteIndex += 1
            }
            write(word, fifo)
            wordIndex += 1
        }
    }

    private mutating func waitForSet(
        offset: UInt,
        mask: UInt32,
        maximumPollCount: Int
    ) -> Bool {
        var remaining = maximumPollCount
        while remaining > 0 {
            if read(offset) & mask == mask { return true }
            remaining -= 1
        }
        return false
    }

    private mutating func waitForClear(
        offset: UInt,
        mask: UInt32,
        maximumPollCount: Int
    ) -> Bool {
        var remaining = maximumPollCount
        while remaining > 0 {
            if read(offset) & mask == 0 { return true }
            remaining -= 1
        }
        return false
    }

    @inline(__always)
    private mutating func read(_ offset: UInt) -> UInt32 {
        registers.read32(at: offset)
    }

    @inline(__always)
    private mutating func write(_ value: UInt32, _ offset: UInt) {
        registers.write32(value, at: offset)
    }
}
