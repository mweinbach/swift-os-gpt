@main
struct USBKernelUpdateProtocolTests {
    static func main() {
        validatesSHA256AndCRCReferenceVectors()
        roundTripsEveryWireMessageAndRecoversFraming()
        stagesAndCommitsOnlyAfterCompleteValidation()
        negotiatesBoundedChunksAndResumesWithoutRewriting()
        rejectsCorruptionAndDiscardsFaultedStaging()
        print("USB kernel update protocol host tests: 5 groups passed")
    }

    private static func validatesSHA256AndCRCReferenceVectors() {
        let empty: [UInt8] = []
        expect(
            digest(empty) == USBKernelUpdateSHA256Digest(
                0xe3b0_c442, 0x98fc_1c14, 0x9afb_f4c8, 0x996f_b924,
                0x27ae_41e4, 0x649b_934c, 0xa495_991b, 0x7852_b855
            ),
            "SHA-256 empty reference vector"
        )

        let abc = Array("abc".utf8)
        var streaming = USBKernelUpdateSHA256()
        Array(abc[0..<1]).withUnsafeBytes {
            expect(streaming.update($0), "SHA first fragment")
        }
        Array(abc[1..<3]).withUnsafeBytes {
            expect(streaming.update($0), "SHA second fragment")
        }
        expect(
            streaming.finalizedDigest() == USBKernelUpdateSHA256Digest(
                0xba78_16bf, 0x8f01_cfea, 0x4141_40de, 0x5dae_2223,
                0xb003_61a3, 0x9617_7a9c, 0xb410_ff61, 0xf200_15ad
            ),
            "SHA-256 abc reference vector"
        )

        let crcVector = Array("123456789".utf8)
        var crc = USBKernelUpdateCRC32()
        crcVector.withUnsafeBytes { crc.update($0) }
        expect(crc.value == 0xcbf4_3926, "CRC-32 IEEE reference vector")
    }

    private static func roundTripsEveryWireMessageAndRecoversFraming() {
        let artifact = makeArtifact(byteCount: 700)
        let begin = makeBegin(artifact, chunkByteCount: 456)
        let beginBytes = encode(
            .begin(begin),
            transferID: artifact.transferID,
            sequence: 0
        )
        expect(beginBytes[0] == 0x53 && beginBytes[1] == 0x55,
               "SUPD magic prefix")
        expect(beginBytes[2] == 0x50 && beginBytes[3] == 0x44,
               "SUPD magic suffix")
        expect(beginBytes[4] == 1 && beginBytes[5] == 1,
               "SUPD version and BEGIN kind")
        expect(readLE32(beginBytes, at: 8) == artifact.transferID,
               "SUPD transfer ID offset")
        expect(readLE32(beginBytes, at: 12) == 0,
               "SUPD sequence offset")
        expect(readLE32(beginBytes, at: 16) == 56,
               "SUPD payload length offset")

        beginBytes.withUnsafeBytes { raw in
            let packet = requireDecoded(raw)
            guard case .begin(let decoded) = packet.message else {
                fatalError("BEGIN decoded as wrong kind")
            }
            expect(decoded == begin, "BEGIN payload round trip")
            expect(packet.encodedByteCount == 80, "BEGIN packet size")
        }

        let firstChunk = Array(artifact.bytes[0..<456])
        firstChunk.withUnsafeBytes { chunkBytes in
            let data = USBKernelUpdateData(offset: 0, bytes: chunkBytes)
            let encoded = encode(
                .data(data),
                transferID: artifact.transferID,
                sequence: 1
            )
            expect(encoded.count == 496, "one HS DATA packet bound")
            encoded.withUnsafeBytes { raw in
                let packet = requireDecoded(raw)
                guard case .data(let decoded) = packet.message else {
                    fatalError("DATA decoded as wrong kind")
                }
                expect(decoded.offset == 0, "DATA offset round trip")
                expect(decoded.bytes.count == 456, "DATA length round trip")
                expect(decoded.bytes[455] == firstChunk[455],
                       "DATA bytes round trip")
            }
        }

        let commit = USBKernelUpdateCommit(
            totalLength: UInt64(artifact.bytes.count),
            sha256: artifact.sha256
        )
        expectKind(
            encode(.commit(commit), transferID: artifact.transferID, sequence: 3),
            .commit
        )
        expectKind(
            encode(
                .abort(USBKernelUpdateAbort(reason: 9)),
                transferID: artifact.transferID,
                sequence: 0
            ),
            .abort
        )
        let status = USBKernelUpdateStatus(
            code: .progress,
            phase: .receiving,
            nextOffset: 456,
            acceptedChunkByteCount: 456,
            detail: 2
        )
        let statusBytes = encode(
            .status(status),
            transferID: artifact.transferID,
            sequence: 0
        )
        statusBytes.withUnsafeBytes { raw in
            let packet = requireDecoded(raw)
            guard case .status(let decoded) = packet.message else {
                fatalError("STATUS decoded as wrong kind")
            }
            expect(decoded == status, "STATUS payload round trip")
        }

        var corrupted = beginBytes
        corrupted[corrupted.count - 1] ^= 0x80
        corrupted.withUnsafeBytes { raw in
            guard case .rejected(.packetChecksumMismatch, _) =
                    USBKernelUpdatePacketDecoder.decodePrefix(raw)
            else { fatalError("corrupted SUPD packet was accepted") }
        }

        let noise = [UInt8](repeating: 0xa5, count: 7) + beginBytes
        noise.withUnsafeBytes { raw in
            guard case .rejected(.invalidMagic, let discard) =
                    USBKernelUpdatePacketDecoder.decodePrefix(raw)
            else { fatalError("SUPD decoder did not report framing noise") }
            expect(discard == 7, "SUPD recovery did not locate next magic")
        }
    }

    private static func stagesAndCommitsOnlyAfterCompleteValidation() {
        let artifact = makeArtifact(byteCount: 700)
        var receiver = requireReceiver()
        var sink = RecordingUpdateSink()
        let begin = makeBegin(artifact, chunkByteCount: 456)

        let beginResult = accept(
            encode(
                .begin(begin),
                transferID: artifact.transferID,
                sequence: 0
            ),
            into: &receiver,
            sink: &sink
        )
        expectAccepted(beginResult, code: .accepted, phase: .receiving)
        expect(sink.beginCount == 1, "staging did not begin once")
        expect(!sink.didPublish, "BEGIN published an unvalidated artifact")

        acceptData(
            Array(artifact.bytes[0..<456]),
            offset: 0,
            sequence: 1,
            artifact: artifact,
            receiver: &receiver,
            sink: &sink
        )
        expect(!sink.didPublish, "partial DATA published an artifact")
        acceptData(
            Array(artifact.bytes[456..<700]),
            offset: 456,
            sequence: 2,
            artifact: artifact,
            receiver: &receiver,
            sink: &sink
        )
        expect(!sink.didPublish, "complete DATA published before COMMIT")

        let result = accept(
            encode(
                .commit(
                    USBKernelUpdateCommit(
                        totalLength: 700,
                        sha256: artifact.sha256
                    )
                ),
                transferID: artifact.transferID,
                sequence: 3
            ),
            into: &receiver,
            sink: &sink
        )
        expectAccepted(result, code: .committed, phase: .committed)
        expect(receiver.phase == .committed, "receiver did not commit")
        expect(sink.didPublish, "validated artifact was not published")
        expect(sink.stagedBytes == artifact.bytes,
               "staged artifact differs from source")
        expect(sink.discardCount == 0, "successful stage was discarded")
    }

    private static func negotiatesBoundedChunksAndResumesWithoutRewriting() {
        let artifact = makeArtifact(byteCount: 1_000)
        let offeredChunk: UInt32 = 4_096
        let begin = makeBegin(artifact, chunkByteCount: offeredChunk)
        var receiver = requireReceiver()
        var sink = RecordingUpdateSink()
        let beginBytes = encode(
            .begin(begin),
            transferID: artifact.transferID,
            sequence: 0
        )

        let accepted = accept(beginBytes, into: &receiver, sink: &sink)
        expectAccepted(accepted, code: .accepted, phase: .receiving)
        expect(receiver.activeDescriptor?.chunkByteCount == 456,
               "receiver did not bound negotiated chunk")
        expect(receiver.activeDescriptor?.totalChunkCount == 3,
               "receiver did not recompute negotiated chunk count")

        let resumed = accept(beginBytes, into: &receiver, sink: &sink)
        expectAccepted(resumed, code: .accepted, phase: .receiving)
        expect(sink.beginCount == 1, "resume rewrote staging metadata")

        acceptData(
            Array(artifact.bytes[0..<456]),
            offset: 0,
            sequence: 1,
            artifact: artifact,
            receiver: &receiver,
            sink: &sink
        )
        acceptData(
            Array(artifact.bytes[0..<456]),
            offset: 0,
            sequence: 1,
            artifact: artifact,
            receiver: &receiver,
            sink: &sink
        )
        expect(sink.writeCount == 1,
               "last accepted DATA replay rewrote staging")
        expect(receiver.nextOffset == 456,
               "last accepted DATA replay advanced the offset")
        let resumedAfterData = accept(beginBytes, into: &receiver, sink: &sink)
        expectAccepted(resumedAfterData, code: .progress, phase: .receiving)
        expect(receiver.status().nextOffset == 456,
               "resume did not preserve next offset")
        expect(sink.writeCount == 1, "resume duplicated a staged chunk")

        let otherArtifact = makeArtifact(byteCount: 128, salt: 77)
        let busy = accept(
            encode(
                .begin(makeBegin(otherArtifact, chunkByteCount: 128)),
                transferID: otherArtifact.transferID,
                sequence: 0
            ),
            into: &receiver,
            sink: &sink
        )
        expectRejected(busy, code: .busy)
        expect(receiver.phase == .receiving,
               "foreign BEGIN destroyed resumable transfer")
        expect(sink.discardCount == 0,
               "foreign BEGIN discarded active staging")
    }

    private static func rejectsCorruptionAndDiscardsFaultedStaging() {
        let artifact = makeArtifact(byteCount: 128)
        var receiver = requireReceiver()
        var sink = RecordingUpdateSink()
        let begin = makeBegin(artifact, chunkByteCount: 128)
        _ = accept(
            encode(
                .begin(begin),
                transferID: artifact.transferID,
                sequence: 0
            ),
            into: &receiver,
            sink: &sink
        )

        let wrongSequenceBytes = Array(artifact.bytes[0..<128])
        wrongSequenceBytes.withUnsafeBytes { raw in
            let result = acceptDecoded(
                .data(USBKernelUpdateData(offset: 0, bytes: raw)),
                transferID: artifact.transferID,
                sequence: 2,
                into: &receiver,
                sink: &sink
            )
            expectRejected(result, code: .invalidOffset)
        }
        expect(receiver.phase == .rejected,
               "sequence fault was not sticky")
        expect(sink.discardCount == 1,
               "sequence fault did not discard staging")
        expect(!sink.didPublish, "faulted transfer was published")

        let blocked = accept(
            encode(
                .begin(begin),
                transferID: artifact.transferID,
                sequence: 0
            ),
            into: &receiver,
            sink: &sink
        )
        expectRejected(blocked, code: .busy)
        let aborted = accept(
            encode(
                .abort(USBKernelUpdateAbort(reason: 42)),
                transferID: artifact.transferID,
                sequence: 0
            ),
            into: &receiver,
            sink: &sink
        )
        expectAccepted(aborted, code: .aborted, phase: .idle)
        expect(receiver.phase == .idle, "ABORT did not recover receiver")

        var digestReceiver = requireReceiver()
        var digestSink = RecordingUpdateSink()
        var damagedDigest = artifact.sha256
        damagedDigest = USBKernelUpdateSHA256Digest(
            damagedDigest.word0 ^ 1,
            damagedDigest.word1,
            damagedDigest.word2,
            damagedDigest.word3,
            damagedDigest.word4,
            damagedDigest.word5,
            damagedDigest.word6,
            damagedDigest.word7
        )
        let falseBegin = USBKernelUpdateBegin(
            artifactKind: .kernelBootImage,
            targetMachine: .raspberryPi5,
            totalLength: 128,
            chunkByteCount: 128,
            totalChunkCount: 1,
            sha256: damagedDigest,
            imageCRC32: artifact.imageCRC32
        )
        _ = accept(
            encode(
                .begin(falseBegin),
                transferID: artifact.transferID,
                sequence: 0
            ),
            into: &digestReceiver,
            sink: &digestSink
        )
        acceptData(
            artifact.bytes,
            offset: 0,
            sequence: 1,
            artifact: artifact,
            receiver: &digestReceiver,
            sink: &digestSink
        )
        let badCommit = accept(
            encode(
                .commit(
                    USBKernelUpdateCommit(
                        totalLength: 128,
                        sha256: damagedDigest
                    )
                ),
                transferID: artifact.transferID,
                sequence: 2
            ),
            into: &digestReceiver,
            sink: &digestSink
        )
        expectRejected(badCommit, code: .checksumMismatch)
        expect(digestSink.discardCount == 1,
               "SHA mismatch did not discard staging")
        expect(!digestSink.didPublish,
               "SHA mismatch published staged bytes")

        var replayReceiver = requireReceiver()
        var replaySink = RecordingUpdateSink()
        _ = accept(
            encode(
                .begin(begin),
                transferID: artifact.transferID,
                sequence: 0
            ),
            into: &replayReceiver,
            sink: &replaySink
        )
        acceptData(
            artifact.bytes,
            offset: 0,
            sequence: 1,
            artifact: artifact,
            receiver: &replayReceiver,
            sink: &replaySink
        )
        var corruptedReplay = artifact.bytes
        corruptedReplay[0] ^= 1
        corruptedReplay.withUnsafeBytes { raw in
            let result = acceptDecoded(
                .data(USBKernelUpdateData(offset: 0, bytes: raw)),
                transferID: artifact.transferID,
                sequence: 1,
                into: &replayReceiver,
                sink: &replaySink
            )
            expectRejected(result, code: .checksumMismatch)
        }
        expect(replaySink.writeCount == 1,
               "corrupt replay reached staging")
        expect(replaySink.discardCount == 1,
               "corrupt replay did not discard staging")

        var targetReceiver = requireReceiver()
        var targetSink = RecordingUpdateSink()
        let wrongTarget = USBKernelUpdateBegin(
            artifactKind: .kernelBootImage,
            targetMachine: .qemuVirtAArch64,
            totalLength: begin.totalLength,
            chunkByteCount: begin.chunkByteCount,
            totalChunkCount: begin.totalChunkCount,
            sha256: begin.sha256,
            imageCRC32: begin.imageCRC32
        )
        let wrongTargetResult = accept(
            encode(
                .begin(wrongTarget),
                transferID: artifact.transferID,
                sequence: 0
            ),
            into: &targetReceiver,
            sink: &targetSink
        )
        expectRejected(wrongTargetResult, code: .unsupportedTarget)
        expect(targetSink.beginCount == 0,
               "wrong-machine image reached storage")
    }

    private struct TestArtifact {
        let bytes: [UInt8]
        let transferID: UInt32
        let sha256: USBKernelUpdateSHA256Digest
        let imageCRC32: UInt32
    }

    private struct RecordingUpdateSink: USBKernelUpdateStagingSink {
        var stagedBytes: [UInt8] = []
        var beginCount = 0
        var writeCount = 0
        var discardCount = 0
        var didPublish = false
        var activeTransferID: UInt32 = 0

        mutating func beginStaging(
            _ descriptor: USBKernelUpdateDescriptor
        ) -> Bool {
            beginCount += 1
            activeTransferID = descriptor.transferID
            stagedBytes = [UInt8](
                repeating: 0,
                count: Int(descriptor.totalLength)
            )
            didPublish = false
            return true
        }

        mutating func writeStagedBytes(
            _ bytes: UnsafeRawBufferPointer,
            transferID: UInt32,
            at offset: UInt64
        ) -> Bool {
            guard transferID == activeTransferID,
                  offset <= UInt64(Int.max),
                  Int(offset) <= stagedBytes.count,
                  bytes.count <= stagedBytes.count - Int(offset)
            else { return false }
            writeCount += 1
            var index = 0
            while index < bytes.count {
                stagedBytes[Int(offset) + index] = bytes[index]
                index += 1
            }
            return true
        }

        mutating func publishValidated(
            _ descriptor: USBKernelUpdateDescriptor
        ) -> Bool {
            guard descriptor.transferID == activeTransferID else {
                return false
            }
            didPublish = true
            return true
        }

        mutating func discardStaging(transferID: UInt32) {
            if transferID == activeTransferID {
                discardCount += 1
                activeTransferID = 0
            }
        }
    }

    private static func makeArtifact(
        byteCount: Int,
        salt: UInt8 = 11
    ) -> TestArtifact {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var index = 0
        while index < byteCount {
            bytes[index] = UInt8(truncatingIfNeeded: index &* 29) ^ salt
            index += 1
        }
        let sha256 = digest(bytes)
        var crc = USBKernelUpdateCRC32()
        bytes.withUnsafeBytes { crc.update($0) }
        return TestArtifact(
            bytes: bytes,
            transferID: sha256.word0 ^ UInt32(byteCount),
            sha256: sha256,
            imageCRC32: crc.value
        )
    }

    private static func makeBegin(
        _ artifact: TestArtifact,
        chunkByteCount: UInt32
    ) -> USBKernelUpdateBegin {
        let length = UInt64(artifact.bytes.count)
        let chunk = UInt64(chunkByteCount)
        let count = length / chunk + (length % chunk == 0 ? 0 : 1)
        return USBKernelUpdateBegin(
            artifactKind: .kernelBootImage,
            targetMachine: .raspberryPi5,
            totalLength: length,
            chunkByteCount: chunkByteCount,
            totalChunkCount: UInt32(count),
            sha256: artifact.sha256,
            imageCRC32: artifact.imageCRC32
        )
    }

    private static func requireReceiver() -> USBKernelUpdateReceiver {
        guard let receiver = USBKernelUpdateReceiver(
                  targetMachine: .raspberryPi5
              )
        else { fatalError("valid update receiver rejected") }
        return receiver
    }

    private static func digest(_ bytes: [UInt8])
        -> USBKernelUpdateSHA256Digest
    {
        var sha = USBKernelUpdateSHA256()
        bytes.withUnsafeBytes {
            expect(sha.update($0), "bounded SHA update rejected")
        }
        return sha.finalizedDigest()
    }

    private static func encode(
        _ message: USBKernelUpdateMessage,
        transferID: UInt32,
        sequence: UInt32
    ) -> [UInt8] {
        var bytes = [UInt8](
            repeating: 0,
            count: USBKernelUpdateProtocol.maximumPacketByteCount
        )
        let byteCount = bytes.withUnsafeMutableBytes { raw -> Int in
            switch USBKernelUpdatePacketEncoder.encode(
                message,
                transferID: transferID,
                sequence: sequence,
                into: raw
            ) {
            case .encoded(let byteCount): return byteCount
            case .rejected(let rejection):
                fatalError("SUPD encode rejected: \(rejection)")
            }
        }
        bytes.removeLast(bytes.count - byteCount)
        return bytes
    }

    private static func accept(
        _ bytes: [UInt8],
        into receiver: inout USBKernelUpdateReceiver,
        sink: inout RecordingUpdateSink
    ) -> USBKernelUpdateReceiverResult {
        bytes.withUnsafeBytes { raw in
            let packet = requireDecoded(raw)
            return receiver.accept(packet, sink: &sink)
        }
    }

    private static func acceptDecoded(
        _ message: USBKernelUpdateMessage,
        transferID: UInt32,
        sequence: UInt32,
        into receiver: inout USBKernelUpdateReceiver,
        sink: inout RecordingUpdateSink
    ) -> USBKernelUpdateReceiverResult {
        receiver.accept(
            USBKernelUpdateDecodedPacket(
                transferID: transferID,
                sequence: sequence,
                message: message,
                encodedByteCount: 0
            ),
            sink: &sink
        )
    }

    private static func acceptData(
        _ bytes: [UInt8],
        offset: UInt64,
        sequence: UInt32,
        artifact: TestArtifact,
        receiver: inout USBKernelUpdateReceiver,
        sink: inout RecordingUpdateSink
    ) {
        bytes.withUnsafeBytes { raw in
            let result = acceptDecoded(
                .data(USBKernelUpdateData(offset: offset, bytes: raw)),
                transferID: artifact.transferID,
                sequence: sequence,
                into: &receiver,
                sink: &sink
            )
            expectAccepted(result, code: .progress, phase: .receiving)
        }
    }

    private static func requireDecoded(
        _ bytes: UnsafeRawBufferPointer
    ) -> USBKernelUpdateDecodedPacket {
        switch USBKernelUpdatePacketDecoder.decodePrefix(bytes) {
        case .decoded(let packet): return packet
        case .needMoreBytes(let required):
            fatalError("SUPD decoder needs \(required) bytes")
        case .rejected(let rejection, _):
            fatalError("SUPD decoder rejected: \(rejection)")
        }
    }

    private static func expectKind(
        _ bytes: [UInt8],
        _ expected: USBKernelUpdateMessageKind
    ) {
        bytes.withUnsafeBytes { raw in
            expect(requireDecoded(raw).message.kind == expected,
                   "SUPD message kind round trip")
        }
    }

    private static func expectAccepted(
        _ result: USBKernelUpdateReceiverResult,
        code: USBKernelUpdateStatusCode,
        phase: USBKernelUpdateStatusPhase
    ) {
        guard case .accepted(_, let status) = result else {
            fatalError("expected accepted update result: \(result)")
        }
        expect(status.code == code, "unexpected accepted status code")
        expect(status.phase == phase, "unexpected accepted status phase")
    }

    private static func expectRejected(
        _ result: USBKernelUpdateReceiverResult,
        code: USBKernelUpdateStatusCode
    ) {
        guard case .rejected(_, let status) = result else {
            fatalError("expected rejected update result: \(result)")
        }
        expect(status.code == code, "unexpected rejected status code")
    }

    private static func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
