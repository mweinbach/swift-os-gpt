@main
struct USBKernelUpdateStreamReceiverTests {
    static func main() {
        reassemblesFullSpeedPacketsAndResumesAfterReset()
        resynchronizesCoalescedGarbage()
        drainsTwoCoalescedFramesWithoutAnotherAppend()
        rejectsStructurallyInvalidPiImage()
        print("USB kernel update stream receiver: 4 groups passed")
    }

    private static func reassemblesFullSpeedPacketsAndResumesAfterReset() {
        var staging = [UInt8](repeating: 0, count: 512)
        var streamStorage = [UInt8](repeating: 0, count: 1_024)
        let image = makePiImage(isStructurallyValid: true)
        staging.withUnsafeMutableBytes { stagingBytes in
            streamStorage.withUnsafeMutableBytes { storageBytes in
                guard let stagingBase = stagingBytes.baseAddress,
                      let storageBase = storageBytes.baseAddress,
                      let region = USBKernelUpdateRAMStagingRegion(
                          baseAddress: UInt64(UInt(bitPattern: stagingBase)),
                          byteCount: UInt64(stagingBytes.count)
                      ), var receiver = USBKernelUpdateStreamReceiver(
                          storageBaseAddress: UInt64(
                              UInt(bitPattern: storageBase)
                          ),
                          storageByteCount: UInt64(storageBytes.count),
                          targetMachine: .raspberryPi5,
                          stagingRegion: region
                      )
                else { fail("stream receiver fixture failed") }

                let begin = beginPacket(image: image, transferID: 0x55)
                expect(
                    feedSplit(begin, splitAt: 64, receiver: &receiver)
                        .status.code == .accepted,
                    "split BEGIN was not accepted"
                )

                let first = dataPacket(
                    Array(image[0..<64]),
                    transferID: 0x55,
                    sequence: 1,
                    offset: 0
                )
                let firstResponse = feedSplit(
                    first,
                    splitAt: 64,
                    receiver: &receiver
                )
                expect(
                    firstResponse.status.code == .progress
                        && firstResponse.status.nextOffset == 64,
                    "first split DATA did not advance staging"
                )

                receiver.resetTransport()
                let resume = feed(begin, receiver: &receiver)
                expect(
                    resume.status.code == .progress
                        && resume.status.nextOffset == 64,
                    "identical BEGIN did not resume after transport reset"
                )

                let second = dataPacket(
                    Array(image[64..<128]),
                    transferID: 0x55,
                    sequence: 2,
                    offset: 64
                )
                expect(
                    feedSplit(second, splitAt: 64, receiver: &receiver)
                        .status.nextOffset == 128,
                    "second split DATA did not complete staging"
                )

                let commit = commitPacket(image: image, transferID: 0x55)
                let committed = feedSplit(
                    commit,
                    splitAt: 32,
                    receiver: &receiver
                )
                expect(
                    committed.status.code == .committed,
                    "valid Pi image did not commit"
                )
                guard let artifact = committed.committedArtifact,
                      case .raspberryPi5(let metadata) =
                        artifact.imageMetadata
                else { fail("committed Pi metadata was not sealed") }
                expect(
                    metadata.rawImageByteCount == 128
                        && metadata.runtimeImageByteCount == 4_096
                        && metadata.entryOffset == 64,
                    "sealed Pi metadata was incorrect"
                )
                var byteIndex = 0
                while byteIndex < image.count {
                    expect(
                        stagingBytes[byteIndex] == image[byteIndex],
                        "staged image bytes changed"
                    )
                    byteIndex += 1
                }
            }
        }
    }

    private static func resynchronizesCoalescedGarbage() {
        withReceiver { receiver in
            let image = makePiImage(isStructurallyValid: true)
            let begin = beginPacket(image: image, transferID: 0x66)
            var coalesced: [UInt8] = [0xde, 0xad, 0x53]
            coalesced.append(contentsOf: begin)
            let response = feed(coalesced, receiver: &receiver)
            expect(
                response.status.code == .accepted,
                "stream did not resynchronize to coalesced SUPD magic"
            )
        }
    }

    private static func drainsTwoCoalescedFramesWithoutAnotherAppend() {
        withReceiver { receiver in
            let image = makePiImage(isStructurallyValid: true)
            var coalesced = beginPacket(image: image, transferID: 0x67)
            coalesced.append(
                contentsOf: dataPacket(
                    Array(image[0..<64]),
                    transferID: 0x67,
                    sequence: 1,
                    offset: 0
                )
            )
            coalesced.withUnsafeBytes { input in
                expect(
                    receiver.append(input) == .appended,
                    "coalesced frame append failed"
                )
            }
            guard case .response(let beginResponse) = receiver.pump()
            else { fail("first coalesced frame produced no response") }
            expect(
                beginResponse.status.code == .accepted,
                "first coalesced frame was not BEGIN"
            )
            guard case .response(let dataResponse) = receiver.pump()
            else { fail("second coalesced frame required another append") }
            expect(
                dataResponse.status.code == .progress
                    && dataResponse.status.nextOffset == 64,
                "second coalesced frame did not stage DATA"
            )
            guard case .needsMoreBytes = receiver.pump() else {
                fail("coalesced stream retained a phantom frame")
            }
        }
    }

    private static func rejectsStructurallyInvalidPiImage() {
        withReceiver { receiver in
            let image = makePiImage(isStructurallyValid: false)
            _ = feed(
                beginPacket(image: image, transferID: 0x77),
                receiver: &receiver
            )
            _ = feed(
                dataPacket(
                    Array(image[0..<64]),
                    transferID: 0x77,
                    sequence: 1,
                    offset: 0
                ),
                receiver: &receiver
            )
            _ = feed(
                dataPacket(
                    Array(image[64..<128]),
                    transferID: 0x77,
                    sequence: 2,
                    offset: 64
                ),
                receiver: &receiver
            )
            let response = feed(
                commitPacket(image: image, transferID: 0x77),
                receiver: &receiver
            )
            expect(
                response.status.code == .storageFailure
                    && response.status.phase == .rejected
                    && response.committedArtifact == nil,
                "malformed Pi Image escaped the structural seal gate"
            )
        }
    }

    private static func withReceiver(
        _ body: (inout USBKernelUpdateStreamReceiver) -> Void
    ) {
        var staging = [UInt8](repeating: 0, count: 512)
        var streamStorage = [UInt8](repeating: 0, count: 1_024)
        staging.withUnsafeMutableBytes { stagingBytes in
            streamStorage.withUnsafeMutableBytes { storageBytes in
                guard let stagingBase = stagingBytes.baseAddress,
                      let storageBase = storageBytes.baseAddress,
                      let region = USBKernelUpdateRAMStagingRegion(
                          baseAddress: UInt64(UInt(bitPattern: stagingBase)),
                          byteCount: UInt64(stagingBytes.count)
                      ), var receiver = USBKernelUpdateStreamReceiver(
                          storageBaseAddress: UInt64(
                              UInt(bitPattern: storageBase)
                          ),
                          storageByteCount: UInt64(storageBytes.count),
                          targetMachine: .raspberryPi5,
                          stagingRegion: region
                      )
                else { fail("stream receiver fixture failed") }
                body(&receiver)
            }
        }
    }

    private static func feedSplit(
        _ bytes: [UInt8],
        splitAt: Int,
        receiver: inout USBKernelUpdateStreamReceiver
    ) -> USBKernelUpdateTransportResponse {
        let first = Array(bytes[0..<splitAt])
        first.withUnsafeBytes { input in
            expect(receiver.append(input) == .appended, "split append failed")
        }
        guard case .needsMoreBytes = receiver.pump() else {
            fail("incomplete split produced a response")
        }
        return feed(Array(bytes[splitAt..<bytes.count]), receiver: &receiver)
    }

    private static func feed(
        _ bytes: [UInt8],
        receiver: inout USBKernelUpdateStreamReceiver
    ) -> USBKernelUpdateTransportResponse {
        bytes.withUnsafeBytes { input in
            expect(receiver.append(input) == .appended, "stream append failed")
        }
        guard case .response(let response) = receiver.pump() else {
            fail("complete SUPD frame produced no response")
        }
        return response
    }

    private static func beginPacket(
        image: [UInt8],
        transferID: UInt32
    ) -> [UInt8] {
        encoded(
            .begin(
                USBKernelUpdateBegin(
                    artifactKind: .kernelBootImage,
                    targetMachine: .raspberryPi5,
                    totalLength: UInt64(image.count),
                    chunkByteCount: 64,
                    totalChunkCount: 2,
                    sha256: digest(image),
                    imageCRC32: crc32(image)
                )
            ),
            transferID: transferID,
            sequence: 0
        )
    }

    private static func dataPacket(
        _ bytes: [UInt8],
        transferID: UInt32,
        sequence: UInt32,
        offset: UInt64
    ) -> [UInt8] {
        bytes.withUnsafeBytes { input in
            encoded(
                .data(USBKernelUpdateData(offset: offset, bytes: input)),
                transferID: transferID,
                sequence: sequence
            )
        }
    }

    private static func commitPacket(
        image: [UInt8],
        transferID: UInt32
    ) -> [UInt8] {
        encoded(
            .commit(
                USBKernelUpdateCommit(
                    totalLength: UInt64(image.count),
                    sha256: digest(image)
                )
            ),
            transferID: transferID,
            sequence: 3
        )
    }

    private static func encoded(
        _ message: USBKernelUpdateMessage,
        transferID: UInt32,
        sequence: UInt32
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 512)
        let byteCount = output.withUnsafeMutableBytes { buffer -> Int in
            guard case .encoded(let count) = USBKernelUpdatePacketEncoder.encode(
                      message,
                      transferID: transferID,
                      sequence: sequence,
                      into: buffer
                  )
            else { fail("packet encoding failed") }
            return count
        }
        return Array(output[0..<byteCount])
    }

    private static func makePiImage(
        isStructurallyValid: Bool
    ) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: 128)
        write32(0x1400_0010, to: &image, at: 0)
        write64(0x0008_0000, to: &image, at: 8)
        write64(4_096, to: &image, at: 16)
        write64(2, to: &image, at: 24)
        write32(
            isStructurallyValid ? 0x644d_5241 : 0,
            to: &image,
            at: 56
        )
        image[64] = 0xd5
        return image
    }

    private static func digest(_ bytes: [UInt8])
        -> USBKernelUpdateSHA256Digest {
        var sha = USBKernelUpdateSHA256()
        bytes.withUnsafeBytes { input in
            expect(sha.update(input), "SHA input rejected")
        }
        return sha.finalizedDigest()
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc = USBKernelUpdateCRC32()
        bytes.withUnsafeBytes { crc.update($0) }
        return crc.value
    }

    private static func write32(
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

    private static func write64(
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
