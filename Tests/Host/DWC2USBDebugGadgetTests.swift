private final class USBDebugGadgetRegisterBank {
    var words = [UInt32](repeating: 0, count: 0x5_000 / 4)
    var receiveWords = [UInt32]()
    var nextReceiveWord = 0

    init() {
        words[Int(DWC2RegisterLayout.coreIdentifier / 4)] = 0x4f54_280a
        words[Int(DWC2RegisterLayout.hardwareConfiguration2 / 4)]
            = 2 | (2 << 3) | (1 << 6) | (7 << 10) | (1 << 19)
        words[Int(DWC2RegisterLayout.hardwareConfiguration3 / 4)] = 4_080 << 16
        words[Int(DWC2RegisterLayout.hardwareConfiguration4 / 4)]
            = (7 << 26) | (1 << 25)
        words[Int(DWC2RegisterLayout.resetControl / 4)] = DWC2CoreBits.ahbIdle
        words[Int(DWC2RegisterLayout.deviceControl / 4)]
            = DWC2CoreBits.softDisconnect
        words[Int(DWC2RegisterLayout.endpoint0TransmitFIFOStatus / 4)]
            = 1 << 16 | 64
        words[Int(DWC2RegisterLayout.inEndpointFIFOStatus(2)! / 4)] = 128
    }

    func injectGlobal(_ interrupt: UInt32) {
        words[Int(DWC2RegisterLayout.interruptStatus / 4)] |= interrupt
    }

    func loadReceiveData(_ bytes: [UInt8]) {
        receiveWords.removeAll(keepingCapacity: true)
        var start = 0
        while start < bytes.count {
            receiveWords.append(pack(bytes, start: start))
            start += 4
        }
        nextReceiveWord = 0
    }

    func injectReceiveStatus(
        endpoint: UInt8,
        packetStatus: DWC2ReceivePacketStatus,
        byteCount: UInt16
    ) {
        words[Int(DWC2RegisterLayout.receiveStatusPop / 4)]
            = UInt32(endpoint)
                | UInt32(byteCount) << 4
                | UInt32(packetStatus.rawValue) << 17
        injectGlobal(DWC2CoreBits.receiveFIFOLevelInterrupt)
    }

    func injectInCompletion(_ endpoint: UInt8) {
        words[Int(DWC2RegisterLayout.inEndpointInterrupt(endpoint)! / 4)]
            |= DWC2CoreBits.endpointTransferComplete
        words[Int(DWC2RegisterLayout.allEndpointInterrupts / 4)]
            |= 1 << UInt32(endpoint)
        injectGlobal(DWC2CoreBits.inEndpointInterrupt)
    }

    private func pack(_ bytes: [UInt8], start: Int) -> UInt32 {
        var word: UInt32 = 0
        var index = 0
        while index < 4 && start + index < bytes.count {
            word |= UInt32(bytes[start + index]) << UInt32(index * 8)
            index += 1
        }
        return word
    }
}

private struct USBDebugGadgetTestRegisters: DWC2RegisterAccess {
    let bank: USBDebugGadgetRegisterBank

    mutating func read32(at offset: UInt) -> UInt32 {
        if offset == DWC2RegisterLayout.receiveStatusPop {
            bank.words[Int(DWC2RegisterLayout.interruptStatus / 4)]
                &= ~DWC2CoreBits.receiveFIFOLevelInterrupt
        }
        if offset == DWC2RegisterLayout.fifoData(0),
           bank.nextReceiveWord < bank.receiveWords.count {
            let word = bank.receiveWords[bank.nextReceiveWord]
            bank.nextReceiveWord += 1
            return word
        }
        return bank.words[Int(offset / 4)]
    }

    mutating func write32(_ value: UInt32, at offset: UInt) {
        let index = Int(offset / 4)
        if offset == DWC2RegisterLayout.resetControl,
           value & (
               DWC2CoreBits.coreSoftReset
                   | DWC2CoreBits.transmitFIFOFlush
                   | DWC2CoreBits.receiveFIFOFlush
           ) != 0 {
            bank.words[index] = DWC2CoreBits.ahbIdle
            if value & DWC2CoreBits.receiveFIFOFlush != 0 {
                bank.words[Int(DWC2RegisterLayout.interruptStatus / 4)]
                    &= ~DWC2CoreBits.receiveFIFOLevelInterrupt
                bank.loadReceiveData([])
            }
            return
        }
        if offset == DWC2RegisterLayout.deviceControl {
            bank.words[index] = value & ~DWC2CoreBits.deviceControlCommandMask
            return
        }
        if offset == DWC2RegisterLayout.interruptStatus {
            bank.words[index] &= ~value
            return
        }
        if let endpoint = endpointInterruptNumber(offset) {
            bank.words[index] &= ~value
            if bank.words[index] == 0 {
                let daint = Int(DWC2RegisterLayout.allEndpointInterrupts / 4)
                if offset >= 0xb00 {
                    bank.words[daint] &= ~(1 << UInt32(endpoint + 16))
                } else {
                    bank.words[daint] &= ~(1 << UInt32(endpoint))
                }
            }
            if bank.words[Int(DWC2RegisterLayout.allEndpointInterrupts / 4)] == 0 {
                bank.words[Int(DWC2RegisterLayout.interruptStatus / 4)]
                    &= ~(
                        DWC2CoreBits.inEndpointInterrupt
                            | DWC2CoreBits.outEndpointInterrupt
                    )
            }
            return
        }
        bank.words[index] = value
    }

    private func endpointInterruptNumber(_ offset: UInt) -> UInt8? {
        let block = offset & 0xf00
        guard (block == 0x900 || block == 0xb00), offset & 0x1f == 0x08
        else { return nil }
        return UInt8((offset & 0x0ff) / 0x20)
    }
}

@main
struct DWC2USBDebugGadgetTests {
    static func main() {
        enumeratesConfiguresAndStreamsAFrame()
        print("DWC2 USB debug gadget: 1 group passed")
    }

    private static func enumeratesConfiguresAndStreamsAFrame() {
        let bank = USBDebugGadgetRegisterBank()
        var pixels = Array(UInt8(0)..<UInt8(32))
        var scratch = [UInt8](repeating: 0, count: 2_048)
        pixels.withUnsafeMutableBytes { source in
            scratch.withUnsafeMutableBytes { scratchBytes in
                guard let sourceBase = source.baseAddress,
                      let scratchBase = scratchBytes.baseAddress,
                      let scanout = makeScanout(
                          sourceBase: sourceBase,
                          sourceByteCount: source.count
                      ), var gadget = DWC2USBDebugGadget(
                          registers: USBDebugGadgetTestRegisters(bank: bank),
                          scratchBaseAddress: UInt64(
                              UInt(bitPattern: scratchBase)
                          ),
                          scratchByteCount: UInt64(scratchBytes.count),
                          scanout: scanout,
                          viewportScale: 1,
                          sessionID: 0x55,
                          maximumInitializationPollCount: 4
                      )
                else {
                    fail("gadget fixture failed to activate")
                }

                bank.loadReceiveData(
                    [0x80, USBStandardRequest.getDescriptor, 0,
                     USBDescriptorType.device, 0, 0, 18, 0]
                )
                bank.injectReceiveStatus(
                    endpoint: 0,
                    packetStatus: .setupDataReceived,
                    byteCount: UInt16(USBSetupPacket.byteCount)
                )
                bank.injectGlobal(
                    DWC2CoreBits.usbResetInterrupt
                        | DWC2CoreBits.enumerationDoneInterrupt
                )
                expect(gadget.service() == .busReset, "bus reset not handled")
                expect(
                    gadget.service() == .none,
                    "stale coalesced reset state survived into the next pass"
                )

                bank.words[Int(DWC2RegisterLayout.deviceStatus / 4)] = 0
                bank.injectGlobal(DWC2CoreBits.enumerationDoneInterrupt)
                expect(
                    gadget.service() == .enumerated(.high),
                    "high-speed enumeration not handled"
                )

                requestFullConfigurationDescriptor(
                    bank: bank,
                    gadget: &gadget
                )
                requestFullPacketStringDescriptor(
                    bank: bank,
                    gadget: &gadget
                )

                injectSetup(
                    [0x00, USBStandardRequest.setAddress, 1, 0, 0, 0, 0, 0],
                    bank: bank,
                    gadget: &gadget
                )
                completeEndpointZero(bank: bank, gadget: &gadget)
                expect(
                    bank.words[Int(DWC2RegisterLayout.deviceConfiguration / 4)]
                        & DWC2CoreBits.deviceAddressMask == 1 << 4,
                    "deferred address was not committed"
                )

                injectSetup(
                    [0x00, USBStandardRequest.setConfiguration,
                     USBDebugDeviceIdentity.configurationValue, 0, 0, 0, 0, 0],
                    bank: bank,
                    gadget: &gadget
                )
                bank.injectInCompletion(0)
                expect(
                    gadget.service() == .configured,
                    "configuration did not activate data endpoints"
                )
                expect(gadget.state == .configured, "wrong gadget state")
                setLineCoding(bank: bank, gadget: &gadget)
                discardMaximumBulkOutPacket(bank: bank, gadget: &gadget)
                let endpointTwoTransferSize = Int(
                    DWC2RegisterLayout.inEndpointTransferSize(2)! / 4
                )
                expect(
                    bank.words[endpointTwoTransferSize] == 0,
                    "display streamed before the CDC tty was opened"
                )

                setControlLineState(
                    1,
                    bank: bank,
                    gadget: &gadget
                )
                expect(
                    gadget.isDisplaySessionOpen,
                    "DTR status stage did not open the display session"
                )
                expect(
                    bank.words[Int(
                        DWC2RegisterLayout.inEndpointFIFOStatus(2)! / 4
                    )] == 128,
                    "CDC data IN FIFO capacity disappeared"
                )
                expect(
                    bank.words[endpointTwoTransferSize] != 0,
                    "DTR did not start the display handshake"
                )

                var completedFrame: UInt64 = 0
                var completionCount = 0
                while completedFrame == 0 && completionCount < 16 {
                    bank.injectInCompletion(2)
                    if case .frameCompleted(let frameID) = gadget.service() {
                        completedFrame = frameID
                    }
                    completionCount += 1
                }
                expect(completedFrame == 1, "initial USB frame did not complete")

                setControlLineState(
                    0,
                    bank: bank,
                    gadget: &gadget
                )
                setControlLineState(
                    1,
                    bank: bank,
                    gadget: &gadget
                )
                completedFrame = 0
                completionCount = 0
                while completedFrame == 0 && completionCount < 16 {
                    bank.injectInCompletion(2)
                    if case .frameCompleted(let frameID) = gadget.service() {
                        completedFrame = frameID
                    }
                    completionCount += 1
                }
                expect(
                    completedFrame == 1,
                    "DTR reopen did not restart a full display session"
                )
                expect(gadget.isOperational, "successful stream faulted")

                bank.loadReceiveData(
                    [0x80, USBStandardRequest.getDescriptor, 0,
                     USBDescriptorType.device, 0, 0, 18, 0]
                )
                bank.injectReceiveStatus(
                    endpoint: 0,
                    packetStatus: .setupDataReceived,
                    byteCount: UInt16(USBSetupPacket.byteCount)
                )
                bank.injectInCompletion(2)
                bank.injectGlobal(
                    DWC2CoreBits.usbResetInterrupt
                        | DWC2CoreBits.enumerationDoneInterrupt
                )
                expect(
                    gadget.service() == .busReset,
                    "configured coalesced reset was not terminal"
                )
                expect(
                    gadget.state == .attached && gadget.service() == .none,
                    "stale display completion escaped configured reset cleanup"
                )
            }
        }
    }

    private static func setLineCoding(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        injectSetup(
            [
                0x21,
                USBCDCRequest.setLineCoding,
                0,
                0,
                USBDebugDeviceIdentity.cdcControlInterface,
                0,
                7,
                0,
            ],
            bank: bank,
            gadget: &gadget
        )
        bank.loadReceiveData([0x00, 0xc2, 0x01, 0x00, 0, 0, 8])
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .outDataReceived,
            byteCount: 7
        )
        expect(
            gadget.service() != .faulted,
            "line coding was accepted before OUT completion"
        )
        bank.loadReceiveData([])
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .outTransferComplete,
            byteCount: 0
        )
        expect(
            gadget.service() != .faulted,
            "completed line-coding OUT transfer faulted"
        )
        completeEndpointZero(bank: bank, gadget: &gadget)
    }

    private static func discardMaximumBulkOutPacket(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        bank.loadReceiveData([UInt8](repeating: 0xa5, count: 512))
        bank.injectReceiveStatus(
            endpoint: 2,
            packetStatus: .outDataReceived,
            byteCount: 512
        )
        expect(
            gadget.service() != .faulted,
            "discarded high-speed OUT packet faulted on bounded staging"
        )
        bank.loadReceiveData([])
        bank.injectReceiveStatus(
            endpoint: 2,
            packetStatus: .outTransferComplete,
            byteCount: 0
        )
        expect(
            gadget.service() != .faulted,
            "discarded OUT endpoint was not rearmed on completion"
        )
    }

    private static func setControlLineState(
        _ value: UInt16,
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        injectSetup(
            [
                0x21,
                USBCDCRequest.setControlLineState,
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8),
                USBDebugDeviceIdentity.cdcControlInterface,
                0,
                0,
                0,
            ],
            bank: bank,
            gadget: &gadget
        )
        completeEndpointZero(bank: bank, gadget: &gadget)
    }

    private static func requestFullConfigurationDescriptor(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        let inputTransferSize = Int(
            DWC2RegisterLayout.inEndpointTransferSize(0)! / 4
        )
        let setup = [
            UInt8(0x80),
            USBStandardRequest.getDescriptor,
            0,
            USBDescriptorType.configuration,
            0,
            0,
            UInt8(USBDebugDeviceIdentity.configurationByteCount),
            0,
        ]
        let transferBeforeSetupCompletion = bank.words[inputTransferSize]
        injectSetupData(setup, bank: bank, gadget: &gadget)
        expect(
            bank.words[inputTransferSize] == transferBeforeSetupCompletion,
            "Chapter 9 action ran before SETUP transaction completion"
        )
        completeSetup(bank: bank, gadget: &gadget)
        expect(
            bank.words[inputTransferSize]
                == DWC2TransferSize.endpoint0In(byteCount: 64),
            "configuration descriptor did not queue its first 64 bytes"
        )

        bank.injectInCompletion(0)
        expect(
            gadget.service() != .faulted,
            "first configuration descriptor packet faulted gadget"
        )
        expect(
            bank.words[inputTransferSize]
                == DWC2TransferSize.endpoint0In(byteCount: 34),
            "configuration descriptor did not queue its final 34 bytes"
        )

        bank.injectInCompletion(0)
        expect(
            gadget.service() != .faulted,
            "final configuration descriptor packet faulted gadget"
        )
        let outputTransferSize = Int(
            DWC2RegisterLayout.outEndpointTransferSize(0)! / 4
        )
        expect(
            bank.words[outputTransferSize]
                == DWC2TransferSize.endpoint0Out(byteCount: 0),
            "configuration descriptor did not arm its status OUT stage"
        )

        completeEndpointZeroOutStatus(bank: bank, gadget: &gadget)
        expect(
            bank.words[outputTransferSize]
                == DWC2TransferSize.endpoint0SetupReception,
            "EP0 was not rearmed for SETUP after the descriptor transfer"
        )
    }

    private static func requestFullPacketStringDescriptor(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        injectSetup(
            [
                0x80,
                USBStandardRequest.getDescriptor,
                5,
                USBDescriptorType.string,
                0x09,
                0x04,
                0xff,
                0,
            ],
            bank: bank,
            gadget: &gadget
        )
        let inputTransferSize = Int(
            DWC2RegisterLayout.inEndpointTransferSize(0)! / 4
        )
        expect(
            bank.words[inputTransferSize]
                == DWC2TransferSize.endpoint0In(byteCount: 64),
            "64-byte string descriptor did not queue its data packet"
        )

        bank.injectInCompletion(0)
        expect(
            gadget.service() != .faulted,
            "64-byte string descriptor packet faulted gadget"
        )
        expect(
            bank.words[inputTransferSize]
                == DWC2TransferSize.endpoint0In(byteCount: 0),
            "full-sized short reply did not queue its terminating ZLP"
        )

        bank.injectInCompletion(0)
        expect(
            gadget.service() != .faulted,
            "string descriptor ZLP faulted gadget"
        )
        let outputTransferSize = Int(
            DWC2RegisterLayout.outEndpointTransferSize(0)! / 4
        )
        expect(
            bank.words[outputTransferSize]
                == DWC2TransferSize.endpoint0Out(byteCount: 0),
            "string descriptor did not arm its status OUT stage"
        )

        completeEndpointZeroOutStatus(bank: bank, gadget: &gadget)
        expect(
            bank.words[outputTransferSize]
                == DWC2TransferSize.endpoint0SetupReception,
            "EP0 was not rearmed after the string descriptor transfer"
        )
    }

    private static func injectSetup(
        _ bytes: [UInt8],
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        injectSetupData(bytes, bank: bank, gadget: &gadget)
        completeSetup(bank: bank, gadget: &gadget)
    }

    private static func injectSetupData(
        _ bytes: [UInt8],
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        precondition(bytes.count == USBSetupPacket.byteCount)
        bank.loadReceiveData(bytes)
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .setupDataReceived,
            byteCount: UInt16(USBSetupPacket.byteCount)
        )
        expect(gadget.service() != .faulted, "SETUP data faulted gadget")
    }

    private static func completeSetup(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        bank.loadReceiveData([])
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .setupTransactionComplete,
            byteCount: 0
        )
        expect(gadget.service() != .faulted, "SETUP completion faulted gadget")
    }

    private static func completeEndpointZeroOutStatus(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        bank.loadReceiveData([])
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .outDataReceived,
            byteCount: 0
        )
        expect(
            gadget.service() != .faulted,
            "zero-length status OUT data faulted gadget"
        )
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .outTransferComplete,
            byteCount: 0
        )
        expect(
            gadget.service() != .faulted,
            "status OUT completion faulted gadget"
        )
    }

    private static func completeEndpointZero(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        bank.injectInCompletion(0)
        expect(gadget.service() != .faulted, "EP0 completion faulted gadget")
    }

    private static func makeScanout(
        sourceBase: UnsafeMutableRawPointer,
        sourceByteCount: Int
    ) -> ScanoutBuffer? {
        guard let mode = DisplayMode(
                  widthInPixels: 4,
                  heightInPixels: 2,
                  refreshRateMilliHertz: 60_000,
                  pixelFormat: .b8g8r8x8
              ), let mapping = DMAMapping(
                  cpuPhysicalAddress: UInt64(UInt(bitPattern: sourceBase)),
                  deviceAddress: UInt64(UInt(bitPattern: sourceBase)),
                  byteCount: UInt64(sourceByteCount),
                  deviceAddressWidth: .bits64,
                  coherency: .hardwareCoherent
              )
        else { return nil }
        return ScanoutBuffer(mode: mode, bytesPerRow: 16, mapping: mapping)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("\(message)")
    }
}
