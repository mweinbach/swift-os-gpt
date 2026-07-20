private final class USBDebugGadgetRegisterBank {
    var words = [UInt32](repeating: 0, count: 0x5_000 / 4)
    var registerReadOffsets = [UInt]()
    var receiveWords = [UInt32]()
    var nextReceiveWord = 0
    var receiveStatuses = [UInt32]()
    var nextReceiveStatus = 0
    var endpointTwoTransmitWords = [UInt32]()

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
        receiveStatuses.append(
            UInt32(endpoint)
                | UInt32(byteCount) << 4
                | UInt32(packetStatus.rawValue) << 17
        )
        injectGlobal(DWC2CoreBits.receiveFIFOLevelInterrupt)
    }

    var pendingReceiveStatusCount: Int {
        receiveStatuses.count - nextReceiveStatus
    }

    func clearReceiveFIFO() {
        receiveStatuses.removeAll(keepingCapacity: true)
        nextReceiveStatus = 0
        loadReceiveData([])
    }

    func injectInCompletion(_ endpoint: UInt8) {
        words[Int(DWC2RegisterLayout.inEndpointInterrupt(endpoint)! / 4)]
            |= DWC2CoreBits.endpointTransferComplete
        words[Int(DWC2RegisterLayout.allEndpointInterrupts / 4)]
            |= 1 << UInt32(endpoint)
        injectGlobal(DWC2CoreBits.inEndpointInterrupt)
    }

    func clearEndpointTwoTransmitCapture() {
        endpointTwoTransmitWords.removeAll(keepingCapacity: true)
    }

    func clearRegisterReadTrace() {
        registerReadOffsets.removeAll(keepingCapacity: true)
    }

    var endpointTwoTransmitBytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(endpointTwoTransmitWords.count * 4)
        for word in endpointTwoTransmitWords {
            bytes.append(UInt8(truncatingIfNeeded: word))
            bytes.append(UInt8(truncatingIfNeeded: word >> 8))
            bytes.append(UInt8(truncatingIfNeeded: word >> 16))
            bytes.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return bytes
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
        bank.registerReadOffsets.append(offset)
        if offset == DWC2RegisterLayout.receiveStatusPop {
            if bank.nextReceiveStatus < bank.receiveStatuses.count {
                let status = bank.receiveStatuses[bank.nextReceiveStatus]
                bank.nextReceiveStatus += 1
                if bank.nextReceiveStatus == bank.receiveStatuses.count {
                    bank.words[Int(DWC2RegisterLayout.interruptStatus / 4)]
                        &= ~DWC2CoreBits.receiveFIFOLevelInterrupt
                }
                return status
            }
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
        if offset == DWC2RegisterLayout.fifoData(2) {
            bank.endpointTwoTransmitWords.append(value)
            return
        }
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
                bank.clearReceiveFIFO()
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
        reportsTypedBringUpFailureAndHardwareSnapshot()
        print("DWC2 USB debug gadget: 2 groups passed")
    }

    private static func enumeratesConfiguresAndStreamsAFrame() {
        let bank = USBDebugGadgetRegisterBank()
        var pixels = Array(UInt8(0)..<UInt8(32))
        var scratch = [UInt8](repeating: 0, count: 4_096)
        var updateStaging = [UInt8](repeating: 0, count: 512)
        updateStaging.withUnsafeMutableBytes { updateBytes in
          pixels.withUnsafeMutableBytes { source in
            scratch.withUnsafeMutableBytes { scratchBytes in
                guard let sourceBase = source.baseAddress,
                      let scratchBase = scratchBytes.baseAddress,
                      let updateBase = updateBytes.baseAddress,
                      let updateRegion = USBKernelUpdateRAMStagingRegion(
                          baseAddress: UInt64(UInt(bitPattern: updateBase)),
                          byteCount: UInt64(updateBytes.count)
                      ),
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
                          kernelDescription: makeKernelDescription(),
                          updateStagingRegion: updateRegion,
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

                boundReceiveFIFOServiceWork(bank: bank, gadget: &gadget)
                acceptLatestSetupFromReceiveBacklog(
                    bank: bank,
                    gadget: &gadget
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
                exerciseCommittedKernelUpdate(
                    bank: bank,
                    gadget: &gadget
                )
                discardMaximumBulkOutPacket(bank: bank, gadget: &gadget)
                let endpointTwoTransferSize = Int(
                    DWC2RegisterLayout.inEndpointTransferSize(2)! / 4
                )
                expect(
                    bank.words[endpointTwoTransferSize]
                        == DWC2TransferSize.bulk(
                            byteCount: UInt32(
                                USBKernelUpdateProtocol.headerByteCount
                                    + USBKernelUpdateProtocol
                                        .statusPayloadByteCount
                            ),
                            maximumPacketSize: 512
                        ),
                    "display replaced SUPD traffic before the tty was opened"
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

                exerciseSDBGStatus(
                    bank: bank,
                    gadget: &gadget
                )

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

                let invalidEndpointZeroReceiveStatus = UInt32(
                    DWC2ReceivePacketStatus.outTransferComplete.rawValue
                ) << 17
                bank.words[Int(DWC2RegisterLayout.receiveStatusPop / 4)]
                    = invalidEndpointZeroReceiveStatus
                bank.injectGlobal(DWC2CoreBits.receiveFIFOLevelInterrupt)
                expect(
                    gadget.service() == .faulted,
                    "invalid idle EP0 OUT completion did not fail closed"
                )
                guard let fault = gadget.lastServiceFault else {
                    fail("terminal service fault lost its bounded snapshot")
                }
                expect(
                    fault.reason == .endpointZero
                        && fault.gadgetState == .attached
                        && fault.controllerState == .connected
                        && fault.globalInterrupts
                            & DWC2CoreBits.receiveFIFOLevelInterrupt != 0
                        && fault.endpointInterrupts == 0
                        && fault.receiveStatus
                            == invalidEndpointZeroReceiveStatus,
                    "EP0 receive-state fault snapshot changed"
                )
            }
          }
        }
    }

    private static func reportsTypedBringUpFailureAndHardwareSnapshot() {
        let bank = USBDebugGadgetRegisterBank()
        bank.words[Int(DWC2RegisterLayout.coreIdentifier / 4)] = 0x1234_5678
        var pixels = Array(UInt8(0)..<UInt8(32))
        var scratch = [UInt8](repeating: 0, count: 4_096)
        pixels.withUnsafeMutableBytes { source in
            scratch.withUnsafeMutableBytes { scratchBytes in
                guard let sourceBase = source.baseAddress,
                      let scratchBase = scratchBytes.baseAddress,
                      let scanout = makeScanout(
                          sourceBase: sourceBase,
                          sourceByteCount: source.count
                      )
                else { fail("typed failure fixture was invalid") }

                let outcome = DWC2USBDebugGadget<
                    USBDebugGadgetTestRegisters
                >.bringUp(
                    registers: USBDebugGadgetTestRegisters(bank: bank),
                    scratchBaseAddress: UInt64(UInt(bitPattern: scratchBase)),
                    scratchByteCount: UInt64(scratchBytes.count),
                    scanout: scanout,
                    viewportScale: 1,
                    kernelDescription: makeKernelDescription(),
                    maximumInitializationPollCount: 4
                )
                guard case .failed(let failure) = outcome else {
                    fail("foreign DWC2 core activated")
                }
                expect(
                    failure.reason == .controller(.unsupportedCore),
                    "controller failure reason was collapsed"
                )
                guard let snapshot = failure.hardwareSnapshot else {
                    fail("controller failure lost hardware snapshot")
                }
                expect(
                    snapshot.coreIdentifier == 0x1234_5678,
                    "core identifier snapshot changed"
                )
                expect(
                    snapshot.hardwareConfiguration2
                        == bank.words[
                            Int(
                                DWC2RegisterLayout.hardwareConfiguration2 / 4
                            )
                        ],
                    "hardware configuration snapshot changed"
                )

                bank.clearRegisterReadTrace()
                let invalidPollLimit = DWC2USBDebugGadget<
                    USBDebugGadgetTestRegisters
                >.bringUp(
                    registers: USBDebugGadgetTestRegisters(bank: bank),
                    scratchBaseAddress: UInt64(UInt(bitPattern: scratchBase)),
                    scratchByteCount: UInt64(scratchBytes.count),
                    scanout: scanout,
                    viewportScale: 1,
                    kernelDescription: makeKernelDescription(),
                    maximumInitializationPollCount: 0
                )
                guard case .failed(let pollFailure) = invalidPollLimit else {
                    fail("zero DWC2 poll limit activated")
                }
                expect(
                    pollFailure.reason == .controller(.invalidPollLimit),
                    "zero poll limit was misclassified"
                )
                expect(
                    pollFailure.hardwareSnapshot == nil,
                    "zero poll limit captured a hardware snapshot"
                )
                expect(
                    bank.registerReadOffsets.isEmpty,
                    "zero poll limit touched DWC2 MMIO"
                )

                bank.clearRegisterReadTrace()
                let invalid = DWC2USBDebugGadget<
                    USBDebugGadgetTestRegisters
                >.bringUp(
                    registers: USBDebugGadgetTestRegisters(bank: bank),
                    scratchBaseAddress: UInt64(UInt(bitPattern: scratchBase)),
                    scratchByteCount: 1,
                    scanout: scanout,
                    viewportScale: 1,
                    kernelDescription: makeKernelDescription(),
                    maximumInitializationPollCount: 4
                )
                guard case .failed(let invalidFailure) = invalid else {
                    fail("invalid scratch activated")
                }
                expect(
                    invalidFailure.reason == .invalidConfiguration,
                    "software validation failure was misclassified"
                )
                expect(
                    invalidFailure.hardwareSnapshot == nil,
                    "software rejection captured a hardware snapshot"
                )
                expect(
                    bank.registerReadOffsets.isEmpty,
                    "software rejection touched DWC2 MMIO"
                )
            }
        }
    }

    private static func exerciseSDBGStatus(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        let identity = makeKernelDescription().bootIdentity
        var payload = [UInt8](
            repeating: 0,
            count: SDBGTypedPayloadProtocol.statusRequestByteCount
        )
        let payloadByteCount = payload.withUnsafeMutableBytes {
            SDBGRequestCodec.encode(.status, into: $0)
        }
        guard let payloadByteCount else { fail("SDBG STATUS payload failed") }
        var request = [UInt8](
            repeating: 0,
            count: SDBGProtocol.headerByteCount + payloadByteCount
        )
        let encoded = request.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes { input in
                SDBGFrameEncoder.encode(
                    envelope: SDBGEnvelope(
                        kind: .request,
                        flags: .none,
                        bootSessionID: SDBGBootSessionID(
                            high: identity.sessionID.high,
                            low: identity.sessionID.low
                        ),
                        requestID: 0x44
                    ),
                    payload: UnsafeRawBufferPointer(
                        start: input.baseAddress,
                        count: payloadByteCount
                    ),
                    into: output
                )
            }
        }
        guard case .encoded(let requestByteCount) = encoded,
              requestByteCount == request.count
        else { fail("SDBG STATUS request failed") }

        bank.clearEndpointTwoTransmitCapture()
        bank.loadReceiveData(request)
        bank.injectReceiveStatus(
            endpoint: 2,
            packetStatus: .outDataReceived,
            byteCount: UInt16(request.count)
        )
        expect(gadget.service() == .none, "SDBG STATUS request faulted")

        let captured = bank.endpointTwoTransmitBytes
        guard captured.count >= SDBGProtocol.headerByteCount else {
            fail("SDBG STATUS response was not queued")
        }
        let payloadLength = UInt32(captured[32])
            | UInt32(captured[33]) << 8
            | UInt32(captured[34]) << 16
            | UInt32(captured[35]) << 24
        let responseByteCount = SDBGProtocol.headerByteCount
            + Int(payloadLength)
        guard responseByteCount <= captured.count else {
            fail("SDBG STATUS response was truncated")
        }
        var decoderStorage = [UInt8](repeating: 0, count: 512)
        decoderStorage.withUnsafeMutableBytes { storage in
            guard var decoder = SDBGStreamDecoder(
                      storageBaseAddress: UInt(bitPattern: storage.baseAddress!),
                      storageByteCount: storage.count,
                      maximumPayloadByteCount: 472
                  )
            else { fail("SDBG response decoder failed") }
            let response = Array(captured[0..<responseByteCount])
            response.withUnsafeBytes {
                expect(decoder.append($0) == .appended,
                       "SDBG response did not append")
            }
            guard case .frame(let frame) = decoder.pump() else {
                fail("SDBG response did not decode")
            }
            expect(frame.envelope.kind == .response,
                   "SDBG response kind changed")
            expect(frame.envelope.requestID == 0x44,
                   "SDBG request correlation changed")
            expect(
                frame.envelope.bootSessionID == SDBGBootSessionID(
                    high: identity.sessionID.high,
                    low: identity.sessionID.low
                ),
                "SDBG response boot identity changed"
            )
            guard case .header(let header)
                    = SDBGResponseCodec.decodeHeader(frame.payload)
            else { fail("SDBG response header did not decode") }
            expect(header.operationRawValue == SDBGOperation.status.rawValue,
                   "SDBG STATUS operation changed")
            expect(header.status == .success,
                   "SDBG STATUS did not succeed")
        }

        bank.loadReceiveData([])
        bank.injectReceiveStatus(
            endpoint: 2,
            packetStatus: .outTransferComplete,
            byteCount: 0
        )
        expect(gadget.service() == .none, "SDBG OUT completion faulted")
        bank.injectInCompletion(2)
        expect(gadget.service() == .none, "SDBG IN completion faulted")
    }

    private static func exerciseCommittedKernelUpdate(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        let image = makePiUpdateImage()
        let transferID: UInt32 = 0x1020_3040
        let digest = updateDigest(image)
        let crc = updateCRC32(image)
        sendUpdatePacket(
            encodedUpdatePacket(
                .begin(
                    USBKernelUpdateBegin(
                        artifactKind: .kernelBootImage,
                        targetMachine: .raspberryPi5,
                        totalLength: UInt64(image.count),
                        chunkByteCount: 64,
                        totalChunkCount: 2,
                        sha256: digest,
                        imageCRC32: crc
                    )
                ),
                transferID: transferID,
                sequence: 0
            ),
            expectsCommittedEvent: false,
            bank: bank,
            gadget: &gadget
        )

        let first = Array(image[0..<64])
        first.withUnsafeBytes { bytes in
            sendUpdatePacket(
                encodedUpdatePacket(
                    .data(USBKernelUpdateData(offset: 0, bytes: bytes)),
                    transferID: transferID,
                    sequence: 1
                ),
                expectsCommittedEvent: false,
                bank: bank,
                gadget: &gadget
            )
        }
        let second = Array(image[64..<128])
        second.withUnsafeBytes { bytes in
            sendUpdatePacket(
                encodedUpdatePacket(
                    .data(USBKernelUpdateData(offset: 64, bytes: bytes)),
                    transferID: transferID,
                    sequence: 2
                ),
                expectsCommittedEvent: false,
                bank: bank,
                gadget: &gadget
            )
        }

        sendUpdatePacket(
            encodedUpdatePacket(
                .commit(
                    USBKernelUpdateCommit(
                        totalLength: UInt64(image.count),
                        sha256: digest
                    )
                ),
                transferID: transferID,
                sequence: 3
            ),
            expectsCommittedEvent: true,
            bank: bank,
            gadget: &gadget
        )
    }

    private static func sendUpdatePacket(
        _ packet: [UInt8],
        expectsCommittedEvent: Bool,
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        bank.loadReceiveData(packet)
        bank.injectReceiveStatus(
            endpoint: 2,
            packetStatus: .outDataReceived,
            byteCount: UInt16(packet.count)
        )
        expect(
            gadget.service() == .none,
            "update became ready before STATUS was transferred"
        )
        let endpointTwoTransferSize = Int(
            DWC2RegisterLayout.inEndpointTransferSize(2)! / 4
        )
        expect(
            bank.words[endpointTwoTransferSize]
                == DWC2TransferSize.bulk(
                    byteCount: UInt32(
                        USBKernelUpdateProtocol.headerByteCount
                            + USBKernelUpdateProtocol.statusPayloadByteCount
                    ),
                    maximumPacketSize: 512
                ),
            "SUPD STATUS did not take endpoint-two IN priority"
        )

        bank.loadReceiveData([])
        bank.injectReceiveStatus(
            endpoint: 2,
            packetStatus: .outTransferComplete,
            byteCount: 0
        )
        expect(
            gadget.service() == .none,
            "update became ready at OUT completion"
        )

        bank.injectInCompletion(2)
        let completion = gadget.service()
        if expectsCommittedEvent {
            guard case .kernelUpdateReady(let artifact) = completion,
                  artifact.descriptor.totalLength == 128,
                  case .raspberryPi5(let metadata) = artifact.imageMetadata,
                  metadata.runtimeImageByteCount == 4_096
            else {
                fail("committed STATUS completion did not emit sealed update")
            }
        } else {
            expect(
                completion == .none,
                "non-committed STATUS emitted an update event"
            )
        }
    }

    private static func encodedUpdatePacket(
        _ message: USBKernelUpdateMessage,
        transferID: UInt32,
        sequence: UInt32
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 512)
        let byteCount = output.withUnsafeMutableBytes { bytes -> Int in
            guard case .encoded(let count) = USBKernelUpdatePacketEncoder.encode(
                      message,
                      transferID: transferID,
                      sequence: sequence,
                      into: bytes
                  )
            else { fail("SUPD fixture encoding failed") }
            return count
        }
        return Array(output[0..<byteCount])
    }

    private static func makePiUpdateImage() -> [UInt8] {
        var image = [UInt8](repeating: 0, count: 128)
        writeUpdateUInt32(0x1400_0010, to: &image, at: 0)
        writeUpdateUInt64(0x0008_0000, to: &image, at: 8)
        writeUpdateUInt64(4_096, to: &image, at: 16)
        writeUpdateUInt64(2, to: &image, at: 24)
        writeUpdateUInt32(0x644d_5241, to: &image, at: 56)
        image[64] = 0xd5
        return image
    }

    private static func updateDigest(
        _ bytes: [UInt8]
    ) -> USBKernelUpdateSHA256Digest {
        var sha = USBKernelUpdateSHA256()
        bytes.withUnsafeBytes { input in
            expect(sha.update(input), "SUPD fixture SHA rejected input")
        }
        return sha.finalizedDigest()
    }

    private static func updateCRC32(_ bytes: [UInt8]) -> UInt32 {
        var crc = USBKernelUpdateCRC32()
        bytes.withUnsafeBytes { crc.update($0) }
        return crc.value
    }

    private static func writeUpdateUInt32(
        _ value: UInt32,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        var index = 0
        while index < 4 {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> UInt32(index * 8)
            )
            index += 1
        }
    }

    private static func writeUpdateUInt64(
        _ value: UInt64,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        var index = 0
        while index < 8 {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> UInt64(index * 8)
            )
            index += 1
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

    private static func boundReceiveFIFOServiceWork(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        for _ in 0..<9 {
            bank.injectReceiveStatus(
                endpoint: 0,
                packetStatus: .globalOutNAK,
                byteCount: 0
            )
        }
        expect(
            gadget.service() == .none,
            "bounded receive FIFO batch faulted gadget"
        )
        expect(
            bank.pendingReceiveStatusCount == 1,
            "receive service pass did not stop after eight FIFO entries"
        )
        expect(
            bank.words[Int(DWC2RegisterLayout.interruptStatus / 4)]
                & DWC2CoreBits.receiveFIFOLevelInterrupt != 0,
            "receive FIFO level dropped while one queued entry remained"
        )
        expect(
            gadget.service() == .none,
            "remaining receive FIFO entry faulted gadget"
        )
        expect(
            bank.pendingReceiveStatusCount == 0,
            "remaining receive FIFO entry was not drained on the next pass"
        )
    }

    private static func acceptLatestSetupFromReceiveBacklog(
        bank: USBDebugGadgetRegisterBank,
        gadget: inout DWC2USBDebugGadget<USBDebugGadgetTestRegisters>
    ) {
        let inputTransferSize = Int(
            DWC2RegisterLayout.inEndpointTransferSize(0)! / 4
        )
        let supersededSetup = [
            UInt8(0x80),
            USBStandardRequest.getDescriptor,
            0,
            USBDescriptorType.device,
            0,
            0,
            18,
            0,
        ]
        let latestSetup = [
            UInt8(0x80),
            USBStandardRequest.getDescriptor,
            0,
            USBDescriptorType.device,
            0,
            0,
            8,
            0,
        ]
        bank.loadReceiveData(supersededSetup + latestSetup)
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .setupDataReceived,
            byteCount: UInt16(USBSetupPacket.byteCount)
        )
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .outTransferComplete,
            byteCount: 0
        )
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .setupDataReceived,
            byteCount: UInt16(USBSetupPacket.byteCount)
        )
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .setupTransactionComplete,
            byteCount: 0
        )

        expect(
            gadget.service() == .none,
            "newer SETUP in receive backlog faulted gadget"
        )
        expect(
            bank.pendingReceiveStatusCount == 0,
            "SETUP receive backlog was not drained in one service pass"
        )
        expect(
            bank.words[inputTransferSize]
                == DWC2TransferSize.endpoint0In(byteCount: 8),
            "superseded SETUP was executed instead of the newest request"
        )

        completeEndpointZero(bank: bank, gadget: &gadget)
        completeEndpointZeroOutStatus(bank: bank, gadget: &gadget)
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
        bank.loadReceiveData([])
        bank.injectReceiveStatus(
            endpoint: 0,
            packetStatus: .outTransferComplete,
            byteCount: 0
        )
        expect(
            gadget.service() != .faulted,
            "physical SETUP OUT completion faulted gadget"
        )
        expect(
            bank.words[inputTransferSize] == transferBeforeSetupCompletion,
            "SETUP OUT completion consumed the staged request too early"
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

    private static func makeKernelDescription() -> USBDebugKernelDescription {
        let build = KernelBuildIdentity(
            buildID: KernelIdentity128(high: 0x5357_4946, low: 0x544f_5301)!,
            sourceRevision: 0x1234,
            imageDigestPrefix: 0x5678,
            flavor: .diagnostic,
            abiRevision: 1
        )
        let boot = KernelBootIdentity(
            sessionID: KernelIdentity128(high: 0x55, low: 0xaa)!,
            build: build,
            bootOrdinal: 0,
            startedAtTicks: 1,
            reason: .unknown
        )
        return USBDebugKernelDescription(
            bootIdentity: boot,
            configuredProcessorCount: 4,
            managedMemoryByteCount: 512 * 1024 * 1024
        )!
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
