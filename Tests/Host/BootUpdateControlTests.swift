@main
struct BootUpdateControlTests {
    static func main() {
        drivesReleaseTrialRollbackAndReplication()
        journalsAcrossRedundantDataSuperblocks()
        reestablishesUncertainJournalDurability()
        repairsOneTornJournalReplica()
        rejectsNonzeroJournalGarbage()
        copiesDisjointSlotChunksDurably()
        defersBootabilityUntilPayloadCopyCompletes()
        print("boot update control host tests: 7 groups passed")
    }

    private static let oldDigest = BootImageDigest(
        word0: 1,
        word1: 2,
        word2: 3,
        word3: 4
    )
    private static let newDigest = BootImageDigest(
        word0: 5,
        word1: 6,
        word2: 7,
        word3: 8
    )

    private static func drivesReleaseTrialRollbackAndReplication() {
        let initial = BootControlRecord.initial(
            confirmedSlot: .a,
            generation: 7,
            digest: oldDigest,
            slotBlockCount: 8,
            mediaLayoutFingerprint: 0xaabb_ccdd
        )!
        expect(
            initial.beginCandidateWrite(
                to: .b,
                generation: 7,
                digest: newDigest,
                blockCount: 8,
                trialToken: 99
            ) == .rejected(.invalidGeneration),
            "release accepted a non-advancing generation"
        )
        var update = take(initial.beginCandidateWrite(
            to: .b,
            generation: 8,
            digest: newDigest,
            blockCount: 8,
            trialToken: 99
        ))
        update = take(update.recordCandidateProgress(nextBlock: 4))
        expect(
            update.sealCandidate() == .rejected(.invalidCursor),
            "partial candidate was sealed"
        )
        update = take(update.recordCandidateProgress(nextBlock: 8))
        update = take(update.sealCandidate())

        let rollback = take(update.observeBoot(slot: .a, wasTryBoot: false))
        expect(rollback.phase == .stable, "failed trial did not roll back")
        expect(rollback.confirmedSlot == .a, "rollback changed confirmed slot")
        expect(rollback.failedTrialCount == 1, "rollback count did not advance")

        update = take(update.observeBoot(slot: .b, wasTryBoot: true))
        expect(
            update.confirmCandidateHealth(
                slot: .b,
                generation: 8,
                digest: newDigest,
                trialToken: 100
            ) == .rejected(.invalidCandidate),
            "health accepted the wrong trial token"
        )
        update = take(update.confirmCandidateHealth(
            slot: .b,
            generation: 8,
            digest: newDigest,
            trialToken: 99
        ))
        expect(update.phase == .selectorCommitPending, "health phase")

        // A reboot after the selector write but before the journal commit is
        // recovered from the firmware-proven normal boot of B.
        update = take(update.observeBoot(slot: .b, wasTryBoot: false))
        expect(update.phase == .stable, "selector commit recovery")
        expect(update.confirmedSlot == .b, "candidate was not confirmed")
        expect(update.confirmedGeneration == 8, "generation did not commit")

        var replication = take(update.beginPeerReplication(
            to: .a,
            blockCount: 8
        ))
        expect(replication.phase == .replicatingPeer, "replication phase")
        replication = take(replication.recordCandidateProgress(nextBlock: 8))
        replication = take(replication.sealCandidate())
        expect(replication.phase == .stable, "replication did not converge")
        expect(
            replication.confirmedSlot == .b,
            "replication moved the default selector back to A"
        )
    }

    private static func journalsAcrossRedundantDataSuperblocks() {
        var device = formattedDataDevice()
        withScratch(byteCount: 512) { scratch in
            expect(
                BootControlJournal.open(&device, scratch: scratch) == .empty,
                "fresh v1 data volume did not expose an empty extension"
            )
            let initial = BootControlRecord.initial(
                confirmedSlot: .a,
                generation: 1,
                digest: oldDigest,
                slotBlockCount: 8,
                mediaLayoutFingerprint: 0x1122
            )!
            expect(
                BootControlJournal.commit(
                    initial,
                    to: &device,
                    scratch: scratch
                ) == .committed(block: 0, sequence: 1),
                "initial journal commit"
            )
            let writing = take(initial.beginCandidateWrite(
                to: .b,
                generation: 2,
                digest: newDigest,
                blockCount: 8,
                trialToken: 5
            ))
            expect(
                BootControlJournal.commit(
                    writing,
                    to: &device,
                    scratch: scratch
                ) == .committed(block: 1, sequence: 2),
                "second journal replica commit"
            )
            expect(
                BootControlJournal.open(&device, scratch: scratch)
                    == .record(writing, .twoValidReplicas),
                "journal did not choose the newest replica"
            )
            switch SwiftOSDataVolume.open(&device, scratch: scratch) {
            case .volume:
                break
            case .failure:
                fail("journal bytes invalidated the data superblock")
            }
        }
    }

    private static func repairsOneTornJournalReplica() {
        var device = formattedDataDevice()
        withScratch(byteCount: 512) { scratch in
            let initial = BootControlRecord.initial(
                confirmedSlot: .a,
                generation: 1,
                digest: oldDigest,
                slotBlockCount: 8,
                mediaLayoutFingerprint: 0x3344
            )!
            _ = BootControlJournal.commit(initial, to: &device, scratch: scratch)
            let writing = take(initial.beginCandidateWrite(
                to: .b,
                generation: 2,
                digest: newDigest,
                blockCount: 8,
                trialToken: 6
            ))
            _ = BootControlJournal.commit(writing, to: &device, scratch: scratch)

            // Simulate a torn older record with a still-valid outer superblock.
            device.bytes[BootControlJournal.recordOffset + 10] ^= 0xff
            expect(
                BootControlJournal.open(&device, scratch: scratch)
                    == .record(writing, .oneValidReplica),
                "valid peer did not survive a torn journal replica"
            )
            let progressed = take(writing.recordCandidateProgress(nextBlock: 4))
            expect(
                BootControlJournal.commit(
                    progressed,
                    to: &device,
                    scratch: scratch
                ) == .committed(block: 0, sequence: 3),
                "next commit did not repair the torn replica"
            )
            expect(
                BootControlJournal.open(&device, scratch: scratch)
                    == .record(progressed, .twoValidReplicas),
                "repaired journal was not redundant"
            )

            // Lose one outer superblock; the valid peer still selects state and
            // the next commit reconstructs the damaged duplicate before use.
            device.bytes[0] = 0
            expect(
                BootControlJournal.open(&device, scratch: scratch)
                    == .record(writing, .oneValidReplica),
                "degraded outer superblock hid its valid peer"
            )
            let progressedAgain = take(writing.recordCandidateProgress(
                nextBlock: 8
            ))
            expect(
                BootControlJournal.commit(
                    progressedAgain,
                    to: &device,
                    scratch: scratch
                ) == .committed(block: 0, sequence: 3),
                "journal did not repair the degraded outer superblock"
            )
            switch SwiftOSDataVolume.open(&device, scratch: scratch) {
            case .volume:
                break
            case .failure:
                fail("outer superblock repair failed")
            }
        }
    }

    private static func reestablishesUncertainJournalDurability() {
        var device = formattedDataDevice()
        withScratch(byteCount: 512) { scratch in
            let initial = BootControlRecord.initial(
                confirmedSlot: .a,
                generation: 1,
                digest: oldDigest,
                slotBlockCount: 8,
                mediaLayoutFingerprint: 0x2233
            )!
            expect(
                BootControlJournal.commit(
                    initial,
                    to: &device,
                    scratch: scratch
                ) == .committed(block: 0, sequence: 1),
                "uncertain durability initial commit"
            )
            let writing = take(initial.beginCandidateWrite(
                to: .b,
                generation: 2,
                digest: newDigest,
                blockCount: 8,
                trialToken: 7
            ))
            device.failSynchronization = true
            expect(
                BootControlJournal.commit(
                    writing,
                    to: &device,
                    scratch: scratch
                ) == .failure(.synchronizeFailed(.transportFailure)),
                "failed journal barrier was not reported"
            )
            device.failSynchronization = false
            expect(
                BootControlJournal.commit(
                    writing,
                    to: &device,
                    scratch: scratch
                ) == .committed(block: 1, sequence: 2),
                "exact journal retry did not establish a fresh barrier"
            )
            expect(
                BootControlJournal.open(&device, scratch: scratch)
                    == .record(writing, .twoValidReplicas),
                "durability retry changed the newest journal record"
            )
        }
    }

    private static func rejectsNonzeroJournalGarbage() {
        var device = formattedDataDevice()
        device.bytes[BootControlJournal.recordOffset + 3] = 0x7f
        device.bytes[512 + BootControlJournal.recordOffset + 4] = 0x55
        withScratch(byteCount: 512) { scratch in
            expect(
                BootControlJournal.open(&device, scratch: scratch)
                    == .failure(.corruptRecord),
                "nonzero record garbage was treated as an empty journal"
            )
        }
    }

    private static func copiesDisjointSlotChunksDurably() {
        var device = MemoryBlockDevice(blockCount: 32)
        let source = BlockDeviceRange(
            startBlock: 2,
            blockCount: 4,
            within: 32
        )!
        let destination = BlockDeviceRange(
            startBlock: 12,
            blockCount: 4,
            within: 32
        )!
        let plan = VerifiedSlotCopyPlan(
            source: source,
            destination: destination
        )!
        var block = 0
        while block < 4 {
            device.bytes[(2 + block) * 512] = UInt8(0x40 + block)
            block += 1
        }
        device.bytes[11 * 512] = 0xaa
        device.bytes[16 * 512] = 0xbb
        withScratch(byteCount: 1_024) { scratch in
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 0,
                    maximumBlockCount: 2,
                    scratch: scratch
                ) == .advanced(nextBlock: 2, isComplete: false),
                "first copy chunk"
            )
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 2,
                    maximumBlockCount: 2,
                    scratch: scratch
                ) == .advanced(nextBlock: 4, isComplete: true),
                "final copy chunk"
            )
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 0,
                    maximumBlockCount:
                        VerifiedSlotCopier.maximumBlocksPerChunk + 1,
                    scratch: scratch
                ) == .failure(.invalidChunkLimit),
                "unbounded copy chunk was accepted"
            )
        }
        block = 0
        while block < 4 {
            expect(
                device.bytes[(12 + block) * 512]
                    == device.bytes[(2 + block) * 512],
                "copied slot byte mismatch"
            )
            block += 1
        }
        expect(
            device.bytes[11 * 512] == 0xaa
                && device.bytes[16 * 512] == 0xbb,
            "copy escaped the destination slot"
        )
    }

    private static func defersBootabilityUntilPayloadCopyCompletes() {
        var device = MemoryBlockDevice(blockCount: 40)
        let source = BlockDeviceRange(
            startBlock: 2,
            blockCount: 10,
            within: 40
        )!
        let destination = BlockDeviceRange(
            startBlock: 20,
            blockCount: 10,
            within: 40
        )!
        let policy = BootSlotWritePolicy.deferredActivation(
            firstCommitBlock: 6,
            lastCommitBlock: 0
        )
        let plan = VerifiedSlotCopyPlan(
            source: source,
            destination: destination,
            writePolicy: policy
        )!
        var relative = 0
        while relative < 10 {
            device.bytes[(2 + relative) * 512] = UInt8(0x40 + relative)
            device.bytes[(20 + relative) * 512] = 0xee
            relative += 1
        }
        withScratch(byteCount: 1_024) { scratch in
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 0,
                    maximumBlockCount: 8,
                    scratch: scratch
                ) == .advanced(nextBlock: 8, isComplete: false),
                "payload stage did not stop before activation blocks"
            )
            expect(
                device.bytes[20 * 512] == 0
                    && device.bytes[26 * 512] == 0,
                "partial destination remained firmware-bootable"
            )
            relative = 1
            while relative < 10 {
                if relative != 6 {
                    expect(
                        device.bytes[(20 + relative) * 512]
                            == device.bytes[(2 + relative) * 512],
                        "deferred payload block mapping changed"
                    )
                }
                relative += 1
            }

            device.bytes[20 * 512] = 0xaa
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 8,
                    maximumBlockCount: 8,
                    scratch: scratch
                ) == .failure(.activationStateMismatch(block: 20)),
                "unexpected boot-sector restoration was ignored"
            )
            device.bytes[20 * 512] = 0
            device.bytes[26 * 512] = 0x7a

            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 8,
                    maximumBlockCount: 8,
                    scratch: scratch
                ) == .advanced(nextBlock: 9, isComplete: false),
                "backup boot sector was not its own durable commit"
            )
            expect(
                device.bytes[26 * 512] == device.bytes[8 * 512]
                    && device.bytes[20 * 512] == 0,
                "torn backup was not repaired before primary activation"
            )
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 8,
                    maximumBlockCount: 8,
                    scratch: scratch
                ) == .advanced(nextBlock: 9, isComplete: false),
                "backup activation replay dead-ended before cursor commit"
            )
            device.bytes[20 * 512] = 0x7b
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 9,
                    maximumBlockCount: 8,
                    scratch: scratch
                ) == .advanced(nextBlock: 10, isComplete: true),
                "torn primary boot-sector commit did not recover"
            )
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 9,
                    maximumBlockCount: 8,
                    scratch: scratch
                ) == .advanced(nextBlock: 10, isComplete: true),
                "primary activation replay dead-ended before cursor commit"
            )
        }
        relative = 0
        while relative < 10 {
            expect(
                device.bytes[(20 + relative) * 512]
                    == device.bytes[(2 + relative) * 512],
                "activation-last copy did not converge byte-for-byte"
            )
            relative += 1
        }
    }

    private static func formattedDataDevice() -> MemoryBlockDevice {
        var device = MemoryBlockDevice(blockCount: 32)
        withScratch(byteCount: 512) { scratch in
            guard case .formatted = SwiftOSDataVolume.initializeEmpty(
                &device,
                kernelLogBlockCount: 2,
                scratch: scratch
            ) else { fail("data fixture format") }
        }
        return device
    }

    private static func take(
        _ result: BootControlTransitionResult
    ) -> BootControlRecord {
        guard case .record(let record) = result else {
            fail("state transition was rejected")
        }
        return record
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
