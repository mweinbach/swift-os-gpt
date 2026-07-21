@main
struct BootUpdateControlTests {
    static func main() {
        drivesReleaseTrialRollbackAndReplication()
        journalsAcrossRedundantDataSuperblocks()
        reestablishesUncertainJournalDurability()
        repairsOneTornJournalReplica()
        rejectsNonzeroJournalGarbage()
        rejectsAmbiguousJournalMediaIdentity()
        copiesDisjointSlotChunksDurably()
        defersBootabilityUntilPayloadCopyCompletes()
        rejectsUnsafeFAT32MetadataActivationPolicies()
        preflightsFAT32ActivationMetadataBeforeInvalidation()
        relocatesFAT32SlotMetadataDuringConvergence()
        print("boot update control host tests: 11 groups passed")
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

    private static func rejectsAmbiguousJournalMediaIdentity() {
        let initial = BootControlRecord.initial(
            confirmedSlot: .a,
            generation: 1,
            digest: oldDigest,
            slotBlockCount: 8,
            mediaLayoutFingerprint: 0x5357_4142_0000_0003
        )!
        let writing = take(initial.beginCandidateWrite(
            to: .b,
            generation: 2,
            digest: newDigest,
            blockCount: 8,
            trialToken: 8
        ))

        var proposedMismatchDevice = formattedDataDevice()
        withScratch(byteCount: 512) { scratch in
            _ = BootControlJournal.commit(
                initial,
                to: &proposedMismatchDevice,
                scratch: scratch
            )
            let mismatchedProposal = withMediaIdentity(
                writing,
                slotBlockCount: 8,
                mediaLayoutFingerprint: 0x5357_4142_0000_0002
            )
            expect(
                BootControlJournal.commit(
                    mismatchedProposal,
                    to: &proposedMismatchDevice,
                    scratch: scratch
                ) == .failure(.mediaIdentityMismatch),
                "journal commit changed immutable media identity"
            )
        }

        for mismatch in ["fingerprint", "slot-count"] {
            var device = formattedDataDevice()
            withScratch(byteCount: 512) { scratch in
                _ = BootControlJournal.commit(
                    initial,
                    to: &device,
                    scratch: scratch
                )
                _ = BootControlJournal.commit(
                    writing,
                    to: &device,
                    scratch: scratch
                )
                let recordBase = 512 + BootControlJournal.recordOffset
                if mismatch == "fingerprint" {
                    writeLE64(
                        0x5357_4142_0000_0002,
                        into: &device.bytes,
                        at: recordBase + 136
                    )
                } else {
                    writeLE64(
                        9,
                        into: &device.bytes,
                        at: recordBase + 64
                    )
                }
                refreshJournalCRC(in: &device.bytes, block: 1)

                expect(
                    BootControlJournal.open(&device, scratch: scratch)
                        == .failure(.conflictingMediaIdentity),
                    "journal open accepted conflicting media identity"
                )
                let progressed = take(
                    writing.recordCandidateProgress(nextBlock: 4)
                )
                expect(
                    BootControlJournal.commit(
                        progressed,
                        to: &device,
                        scratch: scratch
                    ) == .failure(
                        .existingJournal(.conflictingMediaIdentity)
                    ),
                    "journal commit accepted conflicting replicas"
                )
            }
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

    private static func rejectsUnsafeFAT32MetadataActivationPolicies() {
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
        let metadata = BootSlotMetadataPolicy.fat32HiddenSectors(
            primaryBootBlock: 0,
            backupBootBlock: 6
        )
        expect(
            VerifiedSlotCopyPlan(
                source: source,
                destination: destination,
                writePolicy: .direct,
                metadataPolicy: metadata
            ) == nil,
            "direct writes accepted FAT32 location metadata"
        )
        expect(
            VerifiedSlotCopyPlan(
                source: source,
                destination: destination,
                writePolicy: .deferredActivation(
                    firstCommitBlock: 0,
                    lastCommitBlock: 6
                ),
                metadataPolicy: metadata
            ) == nil,
            "primary-first FAT32 activation was accepted"
        )
        expect(
            VerifiedSlotCopyPlan(
                source: source,
                destination: destination,
                writePolicy: .deferredActivation(
                    firstCommitBlock: 5,
                    lastCommitBlock: 0
                ),
                metadataPolicy: metadata
            ) == nil,
            "mismatched FAT32 backup activation was accepted"
        )
        expect(
            VerifiedSlotCopyPlan(
                source: source,
                destination: destination,
                writePolicy: .deferredActivation(
                    firstCommitBlock: 6,
                    lastCommitBlock: 1
                ),
                metadataPolicy: metadata
            ) == nil,
            "mismatched FAT32 primary activation was accepted"
        )
        expect(
            VerifiedSlotCopyPlan(
                source: source,
                destination: destination,
                writePolicy: .deferredActivation(
                    firstCommitBlock: 6,
                    lastCommitBlock: 0
                ),
                metadataPolicy: metadata
            ) != nil,
            "backup-first FAT32 activation was rejected"
        )
        expect(
            VerifiedSlotCopyPlan(
                source: source,
                destination: destination
            ) != nil,
            "metadata-free direct copy was rejected"
        )
    }

    private static func preflightsFAT32ActivationMetadataBeforeInvalidation() {
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
        let plan = VerifiedSlotCopyPlan(
            source: source,
            destination: destination,
            writePolicy: .deferredActivation(
                firstCommitBlock: 6,
                lastCommitBlock: 0
            ),
            metadataPolicy: .fat32HiddenSectors(
                primaryBootBlock: 0,
                backupBootBlock: 6
            )
        )!

        for corruptRelativeBlock: UInt64 in [6, 0] {
            var device = metadataPreflightDevice()
            writeLE32(
                0,
                into: &device.bytes,
                at: Int(source.startBlock + corruptRelativeBlock) * 512 + 28
            )
            let before = device.bytes
            withScratch(byteCount: 1_024) { scratch in
                expect(
                    VerifiedSlotCopier.copyNextChunk(
                        on: &device,
                        plan: plan,
                        nextBlock: 0,
                        maximumBlockCount: 8,
                        scratch: scratch
                    ) == .failure(.sourceMetadataMismatch(
                        block: source.startBlock + corruptRelativeBlock
                    )),
                    "invalid source activation metadata was not precise"
                )
            }
            expect(
                device.bytes == before,
                "metadata preflight failure changed the destination"
            )
        }

        var unreadable = metadataPreflightDevice()
        let beforeUnreadable = unreadable.bytes
        unreadable.failReads = true
        withScratch(byteCount: 1_024) { scratch in
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &unreadable,
                    plan: plan,
                    nextBlock: 0,
                    maximumBlockCount: 8,
                    scratch: scratch
                ) == .failure(.readSource(
                    block: source.startBlock + 6,
                    result: .transportFailure
                )),
                "unreadable source activation metadata was not preflighted"
            )
        }
        expect(
            unreadable.bytes == beforeUnreadable,
            "source preflight read failure changed the destination"
        )
    }

    private static func metadataPreflightDevice() -> MemoryBlockDevice {
        let device = MemoryBlockDevice(blockCount: 40)
        var index = 0
        while index < device.bytes.count {
            device.bytes[index] = UInt8(truncatingIfNeeded: index &* 29 &+ 7)
            index += 1
        }
        writeLE32(2, into: &device.bytes, at: 2 * 512 + 28)
        writeLE32(2, into: &device.bytes, at: 8 * 512 + 28)
        return device
    }

    private static func relocatesFAT32SlotMetadataDuringConvergence() {
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
        let plan = VerifiedSlotCopyPlan(
            source: source,
            destination: destination,
            writePolicy: .deferredActivation(
                firstCommitBlock: 6,
                lastCommitBlock: 0
            ),
            metadataPolicy: .fat32HiddenSectors(
                primaryBootBlock: 0,
                backupBootBlock: 6
            )
        )!
        var relative = 0
        while relative < 10 {
            let sourceOffset = (2 + relative) * 512
            var byte = 0
            while byte < 512 {
                device.bytes[sourceOffset + byte] = UInt8(
                    truncatingIfNeeded: relative &* 19 &+ byte
                )
                byte += 1
            }
            relative += 1
        }
        writeLE32(2, into: &device.bytes, at: 2 * 512 + 28)
        writeLE32(2, into: &device.bytes, at: 8 * 512 + 28)

        withScratch(byteCount: 1_024) { scratch in
            var progress: UInt64 = 0
            while progress < plan.blockCount {
                let count = plan.writePolicy.boundedOperationCount(
                    atProgress: progress,
                    blockCount: plan.blockCount,
                    requested: plan.blockCount
                )!
                guard case .advanced(let nextBlock, _) =
                        VerifiedSlotCopier.copyNextChunk(
                            on: &device,
                            plan: plan,
                            nextBlock: progress,
                            maximumBlockCount: count,
                            scratch: scratch
                        )
                else { fail("FAT32 metadata-aware slot copy") }
                progress = nextBlock
            }
            expect(
                readLE32(device.bytes, at: 20 * 512 + 28) == 20,
                "primary BPB_HiddSec did not name the destination slot"
            )
            expect(
                readLE32(device.bytes, at: 26 * 512 + 28) == 20,
                "backup BPB_HiddSec did not name the destination slot"
            )

            writeLE32(0, into: &device.bytes, at: 2 * 512 + 28)
            expect(
                VerifiedSlotCopier.copyNextChunk(
                    on: &device,
                    plan: plan,
                    nextBlock: 9,
                    maximumBlockCount: 1,
                    scratch: scratch
                ) == .failure(.sourceMetadataMismatch(block: 2)),
                "copy accepted a source BPB that named the wrong partition"
            )
        }

        relative = 0
        while relative < 10 {
            var byte = 0
            while byte < 512 {
                let isHiddenSectorByte = (relative == 0 || relative == 6)
                    && byte >= 28 && byte < 32
                if !isHiddenSectorByte {
                    expect(
                        device.bytes[(20 + relative) * 512 + byte]
                            == device.bytes[(2 + relative) * 512 + byte],
                        "location-neutral FAT32 payload bytes diverged"
                    )
                }
                byte += 1
            }
            relative += 1
        }
    }

    private static func writeLE32(
        _ value: UInt32,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func writeLE64(
        _ value: UInt64,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        writeLE32(UInt32(truncatingIfNeeded: value), into: &bytes, at: offset)
        writeLE32(
            UInt32(truncatingIfNeeded: value >> 32),
            into: &bytes,
            at: offset + 4
        )
    }

    private static func refreshJournalCRC(
        in bytes: inout [UInt8],
        block: Int
    ) {
        let base = block * 512 + BootControlJournal.recordOffset
        let checksum = bytes.withUnsafeBytes { rawBytes in
            StorageCRC32.checksum(UnsafeRawBufferPointer(
                start: rawBytes.baseAddress!.advanced(by: base),
                count: 156
            ))
        }
        writeLE32(checksum, into: &bytes, at: base + 156)
    }

    private static func withMediaIdentity(
        _ record: BootControlRecord,
        slotBlockCount: UInt64,
        mediaLayoutFingerprint: UInt64
    ) -> BootControlRecord {
        BootControlRecord(
            sequence: record.sequence,
            phase: record.phase,
            confirmedSlot: record.confirmedSlot,
            confirmedGeneration: record.confirmedGeneration,
            confirmedDigest: record.confirmedDigest,
            candidateSlot: record.candidateSlot,
            candidateGeneration: record.candidateGeneration,
            candidateDigest: record.candidateDigest,
            updateKind: record.updateKind,
            trialToken: record.trialToken,
            slotBlockCount: slotBlockCount,
            nextCandidateBlock: record.nextCandidateBlock,
            failedTrialCount: record.failedTrialCount,
            mediaLayoutFingerprint: mediaLayoutFingerprint
        )
    }

    private static func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
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
