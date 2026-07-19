@main
struct USBUpdateHostTests {
    static func main() {
        verifiesPublishedChecksums()
        framesAndResynchronizesWithinBounds()
        validatesPiImagesAndPlansExactChunks()
        honorsNegotiatedResumeAndStatusContract()
        rejectsUnsafeImagesAndStatuses()
        print("USB update host pipeline: 5 groups passed")
    }

    private static func verifiesPublishedChecksums() {
        expect(
            USBUpdateCRC32.checksum(Array("123456789".utf8)) == 0xcbf43926,
            "CRC32 does not match the IEEE check value"
        )
        expect(
            hex(USBUpdateSHA256.hash([]))
                == "e3b0c44298fc1c149afbf4c8996fb924"
                    + "27ae41e4649b934ca495991b7852b855",
            "SHA-256 empty vector changed"
        )
        expect(
            hex(USBUpdateSHA256.hash(Array("abc".utf8)))
                == "ba7816bf8f01cfea414140de5dae2223"
                    + "b00361a396177a9cb410ff61f20015ad",
            "SHA-256 abc vector changed"
        )
    }

    private static func framesAndResynchronizesWithinBounds() {
        let frame = USBUpdateFrame(
            kind: .data,
            transferID: 0x78563412,
            sequence: 7,
            payload: [1, 2, 3, 4, 5]
        )
        let encoded = frame.encoded()
        expect(Array(encoded[0..<4]) == Array("SUPD".utf8),
               "wire magic changed")
        expect(encoded[4] == 1 && encoded[5] == 2,
               "version or kind changed")
        expect(read32(encoded, at: 8) == 0x78563412,
               "transfer ID is not little endian")
        expect(read32(encoded, at: 12) == 7,
               "sequence is not little endian")
        expect(read32(encoded, at: 16) == 5,
               "payload count changed")
        expect(
            read32(encoded, at: 20)
                == USBUpdateCRC32.checksum(
                    parts: [Array(encoded[0..<20]), frame.payload]
                ),
            "wire CRC does not cover header prefix and payload"
        )

        let decoder = USBUpdateStreamDecoder()
        decoder.append([0xaa, 0xbb, 0x53])
        expect(decoder.next() == .needMoreBytes,
               "partial magic was not preserved")
        decoder.append(Array(encoded.dropFirst()))
        expect(decoder.next() == .frame(frame),
               "fragmented frame did not reassemble")

        var corrupted = encoded
        corrupted[corrupted.count - 1] ^= 0xff
        decoder.append(corrupted + encoded)
        switch decoder.next() {
        case .rejected(.checksumMismatch):
            break
        default:
            fail("corrupted frame was not rejected")
        }
        expect(decoder.next() == .frame(frame),
               "decoder did not recover after a bad CRC")

        decoder.append(
            [UInt8](
                repeating: 0xcc,
                count: USBUpdateLimits.maximumBufferedByteCount * 2
            )
        )
        _ = decoder.next()
        expect(
            decoder.bufferedByteCount
                <= USBUpdateLimits.maximumBufferedByteCount,
            "unrelated CDC traffic escaped the stream bound"
        )
    }

    private static func validatesPiImagesAndPlansExactChunks() {
        let bytes = validImage(byteCount: 1_000, declaredSize: 4_096)
        let artifact: USBUpdateArtifact
        do {
            artifact = try USBUpdateArtifact(
                validatingRaspberryPi5Image: bytes
            )
        } catch {
            fail("valid Pi image was rejected: \(error)")
        }
        expect(artifact.chunkByteCount == 456,
               "default packet-fitting chunk size changed")
        expect(artifact.totalChunkCount == 3,
               "requested chunk count rounded incorrectly")
        expect(artifact.sha256 == USBUpdateSHA256.hash(bytes),
               "artifact SHA-256 changed")
        expect(artifact.imageCRC32 == USBUpdateCRC32.checksum(bytes),
               "artifact CRC32 changed")
        expect(artifact.transferID != 0,
               "artifact used the reserved zero transfer ID")

        let begin = artifact.beginFrame()
        expect(begin.kind == .begin && begin.sequence == 0,
               "BEGIN sequence contract changed")
        expect(begin.payload.count == USBUpdateBegin.payloadByteCount,
               "BEGIN payload size changed")
        expect(read16(begin.payload, at: 0) == 1,
               "BEGIN artifact kind changed")
        expect(read16(begin.payload, at: 2) == 1,
               "BEGIN target machine changed")
        expect(read64(begin.payload, at: 4) == 1_000,
               "BEGIN artifact length changed")
        expect(read32(begin.payload, at: 12) == 456,
               "BEGIN requested chunk size changed")
        expect(read32(begin.payload, at: 16) == 3,
               "BEGIN total chunk count changed")
        expect(Array(begin.payload[20..<52]) == artifact.sha256,
               "BEGIN SHA-256 changed")
        expect(read32(begin.payload, at: 52) == artifact.imageCRC32,
               "BEGIN image CRC32 changed")

        guard let first = artifact.dataFrame(at: 0),
              let last = artifact.dataFrame(at: 912)
        else { fail("default DATA frames could not be planned") }
        expect(first.sequence == 1 && first.payload.count == 16 + 456,
               "first DATA frame changed")
        expect(read64(first.payload, at: 0) == 0,
               "first DATA offset changed")
        expect(read32(first.payload, at: 8) == 456,
               "first DATA byte count changed")
        expect(last.sequence == 3 && read32(last.payload, at: 8) == 88,
               "tail DATA frame changed")
        expect(
            artifact.commitFrame().sequence == 4,
            "COMMIT sequence is not totalChunks + 1"
        )
    }

    private static func honorsNegotiatedResumeAndStatusContract() {
        let artifact = requireArtifact(
            validImage(byteCount: 1_000, declaredSize: 4_096)
        )
        let beginStatus = statusFrame(
            artifact: artifact,
            code: .progress,
            phase: .receiving,
            nextOffset: 456,
            acceptedChunkByteCount: 228
        )
        let parsed: USBUpdateStatus
        do {
            parsed = try artifact.validateStatus(beginStatus)
        } catch {
            fail("valid negotiated resume was rejected: \(error)")
        }
        expect(parsed.nextOffset == 456,
               "resume offset changed")
        expect(parsed.acceptedChunkByteCount == 228,
               "negotiated chunk size changed")

        guard let resumed = artifact.dataFrame(
            at: parsed.nextOffset,
            chunkByteCount: 228
        ) else { fail("negotiated resume DATA frame was not planned") }
        expect(resumed.sequence == 3,
               "resumed DATA sequence is not offset/chunk + 1")
        expect(read32(resumed.payload, at: 8) == 228,
               "negotiated DATA size changed")
        let progress = statusFrame(
            artifact: artifact,
            code: .progress,
            phase: .receiving,
            nextOffset: 684,
            acceptedChunkByteCount: 228
        )
        do {
            _ = try artifact.validateStatus(
                progress,
                expectedNextOffset: 684,
                effectiveChunkByteCount: 228
            )
        } catch {
            fail("exact DATA acknowledgement was rejected: \(error)")
        }
        expect(
            artifact.commitFrame(chunkByteCount: 228).sequence == 6,
            "negotiated COMMIT sequence changed"
        )

        let committed = statusFrame(
            artifact: artifact,
            code: .committed,
            phase: .committed,
            nextOffset: 1_000,
            acceptedChunkByteCount: 228
        )
        do {
            _ = try artifact.validateStatus(
                committed,
                expectedNextOffset: 1_000,
                effectiveChunkByteCount: 228,
                commit: true
            )
        } catch {
            fail("commit acknowledgement was rejected: \(error)")
        }
    }

    private static func rejectsUnsafeImagesAndStatuses() {
        expectThrows("short image accepted") {
            _ = try USBUpdateArtifact(
                validatingRaspberryPi5Image: [UInt8](repeating: 0, count: 63)
            )
        }
        var badMagic = validImage(byteCount: 128, declaredSize: 256)
        badMagic[56] = 0
        expectThrows("bad ARM64 Image magic accepted") {
            _ = try USBUpdateArtifact(
                validatingRaspberryPi5Image: badMagic
            )
        }
        var badSize = validImage(byteCount: 128, declaredSize: 127)
        expectThrows("undersized declaration accepted") {
            _ = try USBUpdateArtifact(
                validatingRaspberryPi5Image: badSize
            )
        }
        badSize = validImage(byteCount: 128, declaredSize: 256)
        write64(1, into: &badSize, at: 24)
        expectThrows("unsupported image flags accepted") {
            _ = try USBUpdateArtifact(
                validatingRaspberryPi5Image: badSize
            )
        }

        let artifact = requireArtifact(
            validImage(byteCount: 1_000, declaredSize: 4_096)
        )
        let gap = statusFrame(
            artifact: artifact,
            code: .progress,
            phase: .receiving,
            nextOffset: 100,
            acceptedChunkByteCount: 228
        )
        expectThrows("misaligned resume offset accepted") {
            _ = try artifact.validateStatus(gap)
        }
        let oversizedNegotiation = statusFrame(
            artifact: artifact,
            code: .accepted,
            phase: .receiving,
            nextOffset: 0,
            acceptedChunkByteCount: 512
        )
        expectThrows("oversized negotiated chunk accepted") {
            _ = try artifact.validateStatus(oversizedNegotiation)
        }
        let rejection = statusFrame(
            artifact: artifact,
            code: .checksumMismatch,
            phase: .rejected,
            nextOffset: 1_000,
            acceptedChunkByteCount: 456,
            detail: 7
        )
        expectThrows("remote checksum rejection accepted") {
            _ = try artifact.validateStatus(rejection)
        }
        let nonzeroStatusSequence = USBUpdateFrame(
            kind: .status,
            transferID: artifact.transferID,
            sequence: 1,
            payload: USBUpdateStatus(
                code: .accepted,
                phase: .receiving,
                flags: 0,
                nextOffset: 0,
                acceptedChunkByteCount: 456,
                detail: 0
            ).payload()
        )
        expectThrows("in-band STATUS sequence accepted") {
            _ = try artifact.validateStatus(nonzeroStatusSequence)
        }
    }

    private static func validImage(
        byteCount: Int,
        declaredSize: UInt64
    ) -> [UInt8] {
        var bytes = (0..<byteCount).map { UInt8(truncatingIfNeeded: $0) }
        write64(0x80000, into: &bytes, at: 8)
        write64(declaredSize, into: &bytes, at: 16)
        write64(0x02, into: &bytes, at: 24)
        bytes[56] = 0x41
        bytes[57] = 0x52
        bytes[58] = 0x4d
        bytes[59] = 0x64
        return bytes
    }

    private static func requireArtifact(_ bytes: [UInt8])
        -> USBUpdateArtifact
    {
        do {
            return try USBUpdateArtifact(
                validatingRaspberryPi5Image: bytes
            )
        } catch {
            fail("test artifact failed validation: \(error)")
        }
    }

    private static func statusFrame(
        artifact: USBUpdateArtifact,
        code: USBUpdateStatusCode,
        phase: USBUpdateStatusPhase,
        nextOffset: UInt64,
        acceptedChunkByteCount: UInt32,
        detail: UInt32 = 0
    ) -> USBUpdateFrame {
        USBUpdateFrame(
            kind: .status,
            transferID: artifact.transferID,
            sequence: 0,
            payload: USBUpdateStatus(
                code: code,
                phase: phase,
                flags: 0,
                nextOffset: nextOffset,
                acceptedChunkByteCount: acceptedChunkByteCount,
                detail: detail
            ).payload()
        )
    }

    private static func read16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func read64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(read32(bytes, at: offset))
            | UInt64(read32(bytes, at: offset + 4)) << 32
    }

    private static func write64(
        _ value: UInt64,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> UInt64(index * 8)
            )
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func expectThrows(
        _ message: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            fail(message)
        } catch {
            // Expected.
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("USB update host test failed: \(message)")
    }
}
