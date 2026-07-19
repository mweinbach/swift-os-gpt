private final class USBDebugGadgetRegisterBank {
    var words = [UInt32](repeating: 0, count: 0x5_000 / 4)
    var receiveWords = [UInt32]()
    var nextReceiveWord = 0

    init() {
        words[Int(DWC2RegisterLayout.coreIdentifier / 4)] = 0x4f54_280a
        words[Int(DWC2RegisterLayout.hardwareConfiguration2 / 4)]
            = 2 | (2 << 3) | (7 << 10) | (1 << 19)
        words[Int(DWC2RegisterLayout.hardwareConfiguration3 / 4)] = 4_080 << 16
        words[Int(DWC2RegisterLayout.hardwareConfiguration4 / 4)]
            = (7 << 26) | (1 << 25)
        words[Int(DWC2RegisterLayout.resetControl / 4)] = DWC2CoreBits.ahbIdle
        words[Int(DWC2RegisterLayout.deviceControl / 4)]
            = DWC2CoreBits.softDisconnect
        words[Int(DWC2RegisterLayout.inEndpointFIFOStatus(0)! / 4)] = 64
        words[Int(DWC2RegisterLayout.inEndpointFIFOStatus(2)! / 4)] = 128
    }

    func injectGlobal(_ interrupt: UInt32) {
        words[Int(DWC2RegisterLayout.interruptStatus / 4)] |= interrupt
    }

    func injectSetup(_ bytes: [UInt8]) {
        precondition(bytes.count == 8)
        receiveWords = [pack(bytes, start: 0), pack(bytes, start: 4)]
        nextReceiveWord = 0
        words[Int(DWC2RegisterLayout.receiveStatusPop / 4)]
            = 8 << 4 | 6 << 17
        injectGlobal(DWC2CoreBits.receiveFIFOLevelInterrupt)
    }

    func injectInCompletion(_ endpoint: UInt8) {
        words[Int(DWC2RegisterLayout.inEndpointInterrupt(endpoint)! / 4)]
            |= DWC2CoreBits.endpointTransferComplete
        words[Int(DWC2RegisterLayout.allEndpointInterrupts / 4)]
            |= 1 << UInt32(endpoint)
        injectGlobal(DWC2CoreBits.inEndpointInterrupt)
    }

    func injectOutCompletion(_ endpoint: UInt8) {
        words[Int(DWC2RegisterLayout.outEndpointInterrupt(endpoint)! / 4)]
            |= DWC2CoreBits.endpointTransferComplete
        words[Int(DWC2RegisterLayout.allEndpointInterrupts / 4)]
            |= 1 << UInt32(endpoint + 16)
        injectGlobal(DWC2CoreBits.outEndpointInterrupt)
    }

    private func pack(_ bytes: [UInt8], start: Int) -> UInt32 {
        UInt32(bytes[start])
            | UInt32(bytes[start + 1]) << 8
            | UInt32(bytes[start + 2]) << 16
            | UInt32(bytes[start + 3]) << 24
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

                bank.injectGlobal(DWC2CoreBits.usbResetInterrupt)
                expect(gadget.service() == .busReset, "bus reset not handled")

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
                expect(gadget.isOperational, "successful stream faulted")
            }
        }
    }

    private static func requestFullConfigurationDescriptor(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        injectSetup(
            [
                0x80,
                USBStandardRequest.getDescriptor,
                0,
                USBDescriptorType.configuration,
                0,
                0,
                UInt8(USBDebugDeviceIdentity.configurationByteCount),
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

        bank.injectOutCompletion(0)
        expect(
            gadget.service() != .faulted,
            "configuration descriptor status stage faulted gadget"
        )
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

        bank.injectOutCompletion(0)
        expect(
            gadget.service() != .faulted,
            "string descriptor status stage faulted gadget"
        )
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
        bank.injectSetup(bytes)
        expect(gadget.service() != .faulted, "SETUP request faulted gadget")
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
