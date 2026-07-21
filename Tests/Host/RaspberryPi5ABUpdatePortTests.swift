#if BOOT_UPDATE_ORCHESTRATOR_STANDALONE_TEST
struct PlatformBootObservation: Equatable {
    let slot: BootSlot
    let wasTryBoot: Bool
    let trialCapability: PlatformTrialBootCapability
}
#endif

@main
struct RaspberryPi5ABUpdatePortTests {
    private static let totalBlockCount: UInt64 = 2_096
    private static let slotBlockCount: UInt64 = 8

    static func main() {
        borrowsOneDeviceForJournalHashAndMirrorWork()
        failsClosedWithoutAFullSlotReleaseSource()
        rejectsIncompatibleGeometryAndScratch()
        print("Raspberry Pi 5 A/B update port: 3 groups passed")
    }

    private static func borrowsOneDeviceForJournalHashAndMirrorWork() {
        var device = MemoryBlockDevice(blockCount: totalBlockCount)
        let media = makeMedia()
        fillSlotA(on: device, media: media)
        let digest = digestOfSlotA(on: device, media: media)

        withScratch(byteCount: 1_024) { scratch in
            withUnsafeMutablePointer(to: &device) { pointer in
                formatAndSeedJournal(
                    on: pointer,
                    media: media,
                    digest: digest,
                    scratch: scratch
                )
                guard var port = RaspberryPi5ABUpdatePort(
                          borrowing: pointer,
                          media: media,
                          scratch: scratch
                      )
                else { fail("valid A/B media did not create a port") }

                expect(port.acquireExclusiveMediaLease(), "first lease")
                expect(!port.acquireExclusiveMediaLease(), "nested lease")
                let initial = initialRecord(digest: digest)
                expect(
                    port.loadBootControlRecord() == .record(initial),
                    "seeded journal was not opened through the data view"
                )
                expect(
                    port.commitBootControlRecord(initial),
                    "exact journal replay did not establish durability"
                )

                let descriptor = BootReleaseDescriptor(
                    generation: 1,
                    digest: digest,
                    blockCount: slotBlockCount,
                    trialToken: 1
                )!
                let verification = BootCandidateVerificationAction(
                    slot: .a,
                    descriptor: descriptor
                )
                expect(
                    port.verifyCandidate(verification) == .inProgress,
                    "full-slot hash did not yield cooperatively"
                )
                expect(
                    port.verifyCandidate(verification)
                        == .verified(descriptor),
                    "full-slot hash did not verify the expected digest"
                )

                guard let plan = port.layout.copyPlan(from: .a, to: .b) else {
                    fail("Pi activation-last mirror plan")
                }
                let beforeMalformedAction = pointer.pointee.bytes
                expect(
                    !port.mirrorPeer(BootPeerMirrorAction(
                        sourceSlot: .a,
                        destinationSlot: .b,
                        plan: plan,
                        nextBlock: slotBlockCount - 2,
                        blockCount: 2
                    )),
                    "malformed activation action was accepted"
                )
                expect(
                    pointer.pointee.bytes == beforeMalformedAction,
                    "rejected activation action mutated the destination"
                )
                var progress: UInt64 = 0
                while progress < slotBlockCount {
                    guard let count = plan.writePolicy.boundedOperationCount(
                              atProgress: progress,
                              blockCount: slotBlockCount,
                              requested: slotBlockCount
                          )
                    else { fail("bounded mirror operation") }
                    let action = BootPeerMirrorAction(
                        sourceSlot: .a,
                        destinationSlot: .b,
                        plan: plan,
                        nextBlock: progress,
                        blockCount: count
                    )
                    expect(port.mirrorPeer(action), "verified mirror chunk")
                    progress += count
                }
                expectSlotsEqual(on: pointer.pointee, media: media)

                let mirrorVerification = BootPeerMirrorVerificationAction(
                    sourceSlot: .a,
                    destinationSlot: .b,
                    expectedGeneration: 1,
                    expectedDigest: digest,
                    blockCount: slotBlockCount
                )
                expect(
                    port.verifyMirror(mirrorVerification) == .inProgress,
                    "mirror verification did not yield cooperatively"
                )
                expect(
                    port.verifyMirror(mirrorVerification)
                        == .verified(BootPeerMirrorVerificationEvidence(
                            destinationSlot: .b,
                            generation: 1,
                            digest: digest,
                            blockCount: slotBlockCount
                        )),
                    "mirrored slot identity was not independently verified"
                )

                port.releaseExclusiveMediaLease()
                expect(
                    port.loadBootControlRecord() == .unavailable,
                    "journal I/O escaped the exclusive media lease"
                )
            }
        }
    }

    private static func failsClosedWithoutAFullSlotReleaseSource() {
        var device = MemoryBlockDevice(blockCount: totalBlockCount)
        let media = makeMedia()
        withScratch(byteCount: 1_024) { scratch in
            withUnsafeMutablePointer(to: &device) { pointer in
                guard var port = RaspberryPi5ABUpdatePort(
                          borrowing: pointer,
                          media: media,
                          scratch: scratch
                      )
                else { fail("valid port fixture") }
                expect(port.acquireExclusiveMediaLease(), "release-source lease")
                let action = BootCandidateStageAction(
                    slot: .b,
                    destination: media.slotB.range,
                    generation: 2,
                    digest: BootImageDigest(
                        word0: 1,
                        word1: 2,
                        word2: 3,
                        word3: 4
                    ),
                    trialToken: 9,
                    writePolicy: RaspberryPiABUpdateLayout.writePolicy,
                    nextBlock: 0,
                    blockCount: 1
                )
                expect(
                    !port.stageCandidate(action),
                    "metadata alone gained inactive-slot write authority"
                )
                let beforeSelector = pointer.pointee.bytes
                expect(
                    !port.commitSelector(BootSelectorCommitAction(
                        defaultSlot: .b
                    )),
                    "malformed selector media gained write authority"
                )
                expect(
                    pointer.pointee.bytes == beforeSelector,
                    "failed selector validation mutated media"
                )
                port.releaseExclusiveMediaLease()
            }
        }
    }

    private static func rejectsIncompatibleGeometryAndScratch() {
        var sectorDevice = MemoryBlockDevice(blockCount: totalBlockCount)
        let sectorMedia = makeMedia()
        withScratch(byteCount: 512) { scratch in
            withUnsafeMutablePointer(to: &sectorDevice) { pointer in
                expect(
                    RaspberryPi5ABUpdatePort(
                        borrowing: pointer,
                        media: sectorMedia,
                        scratch: scratch
                    ) == nil,
                    "undersized scratch created a physical update port"
                )
            }
        }

        var fourKDevice = MemoryBlockDevice(
            blockCount: totalBlockCount,
            blockByteCount: 4_096
        )
        let fourKMedia = makeMedia()
        withScratch(byteCount: 8_192) { scratch in
            withUnsafeMutablePointer(to: &fourKDevice) { pointer in
                expect(
                    RaspberryPi5ABUpdatePort(
                        borrowing: pointer,
                        media: fourKMedia,
                        scratch: scratch
                    ) == nil,
                    "4 KiB blocks reused 512-byte Pi activation offsets"
                )
            }
        }
    }

    private static func makeMedia() -> SwiftOSABMediaPartitions {
        return SwiftOSABMediaPartitions(
            selector: MBRPartition(
                index: 0,
                type: .fat12,
                isBootable: true,
                range: BlockDeviceRange(
                    startBlock: 1,
                    blockCount: RaspberryPiABSelector.partitionBlockCount,
                    within: totalBlockCount
                )!
            ),
            slotA: MBRPartition(
                index: 1,
                type: .fat32LBA,
                isBootable: false,
                range: BlockDeviceRange(
                    startBlock: 2_048,
                    blockCount: slotBlockCount,
                    within: totalBlockCount
                )!
            ),
            slotB: MBRPartition(
                index: 2,
                type: .fat32LBA,
                isBootable: false,
                range: BlockDeviceRange(
                    startBlock: 2_056,
                    blockCount: slotBlockCount,
                    within: totalBlockCount
                )!
            ),
            data: MBRPartition(
                index: 3,
                type: .swiftOSData,
                isBootable: false,
                range: BlockDeviceRange(
                    startBlock: 2_064,
                    blockCount: 32,
                    within: totalBlockCount
                )!
            )
        )
    }

    private static func formatAndSeedJournal(
        on pointer: UnsafeMutablePointer<MemoryBlockDevice>,
        media: SwiftOSABMediaPartitions,
        digest: BootImageDigest,
        scratch: UnsafeMutableRawBufferPointer
    ) {
        guard var data = BorrowedBlockDeviceRegion(
                  borrowing: pointer,
                  partitionRange: media.data.range
              )
        else { fail("data partition view") }
        guard case .formatted = SwiftOSDataVolume.initializeEmpty(
                  &data,
                  kernelLogBlockCount: 2,
                  scratch: scratch
              )
        else { fail("data partition format") }
        let initial = initialRecord(digest: digest)
        guard case .committed(_, let sequence) = BootControlJournal.commit(
                  initial,
                  to: &data,
                  scratch: scratch
              ), sequence == initial.sequence
        else { fail("seed boot-control journal") }
    }

    private static func initialRecord(
        digest: BootImageDigest
    ) -> BootControlRecord {
        BootControlRecord.initial(
            confirmedSlot: .a,
            generation: 1,
            digest: digest,
            slotBlockCount: slotBlockCount,
            mediaLayoutFingerprint:
                RaspberryPiABUpdateLayout.mediaLayoutFingerprint
        )!
    }

    private static func fillSlotA(
        on device: MemoryBlockDevice,
        media: SwiftOSABMediaPartitions
    ) {
        let start = Int(media.slotA.range.startBlock) * 512
        let count = Int(media.slotA.range.blockCount) * 512
        var index = 0
        while index < count {
            device.bytes[start + index] = UInt8(
                truncatingIfNeeded: index &* 37 &+ 11
            )
            index += 1
        }
    }

    private static func digestOfSlotA(
        on device: MemoryBlockDevice,
        media: SwiftOSABMediaPartitions
    ) -> BootImageDigest {
        let start = Int(media.slotA.range.startBlock) * 512
        let count = Int(media.slotA.range.blockCount) * 512
        var hash = USBKernelUpdateSHA256()
        let updated = device.bytes.withUnsafeBytes { bytes in
            hash.update(UnsafeRawBufferPointer(
                start: bytes.baseAddress!.advanced(by: start),
                count: count
            ))
        }
        expect(updated, "slot digest input")
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: 32,
            alignment: 8
        )
        defer { pointer.deallocate() }
        let bytes = UnsafeMutableRawBufferPointer(start: pointer, count: 32)
        expect(
            hash.finalizedDigest().write(to: bytes),
            "slot digest encoding"
        )
        return BootImageDigest(bytes: UnsafeRawBufferPointer(bytes))!
    }

    private static func expectSlotsEqual(
        on device: MemoryBlockDevice,
        media: SwiftOSABMediaPartitions
    ) {
        let a = Int(media.slotA.range.startBlock) * 512
        let b = Int(media.slotB.range.startBlock) * 512
        let count = Int(media.slotA.range.blockCount) * 512
        var index = 0
        while index < count {
            expect(
                device.bytes[a + index] == device.bytes[b + index],
                "activation-last mirror did not converge"
            )
            index += 1
        }
    }

    private static func withScratch(
        byteCount: Int,
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: 8
        )
        defer { pointer.deallocate() }
        body(UnsafeMutableRawBufferPointer(start: pointer, count: byteCount))
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("FAIL: \(message)")
    }
}
