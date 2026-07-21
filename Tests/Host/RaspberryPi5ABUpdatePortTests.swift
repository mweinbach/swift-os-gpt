#if BOOT_UPDATE_ORCHESTRATOR_STANDALONE_TEST
struct PlatformBootObservation: Equatable {
    let slot: BootSlot
    let wasTryBoot: Bool
    let trialCapability: PlatformTrialBootCapability
}
#endif

@main
struct RaspberryPi5ABUpdatePortTests {
    private static let totalBlockCount: UInt64 = 2_592
    private static let slotBlockCount: UInt64 = 256

    static func main() {
        borrowsOneDeviceForJournalHashAndMirrorWork()
        failsClosedWithoutAFullSlotReleaseSource()
        suspendsBeforeWritingAnInvalidImmutableRescue()
        rejectsIncompatibleGeometryAndScratch()
        classifiesBootFailuresBeforePublishingStorageAliases()
        print("Raspberry Pi 5 A/B update port: 5 groups passed")
    }

    private static func classifiesBootFailuresBeforePublishingStorageAliases() {
        let normal = BootUpdateRuntimeBootContext.payload(
            PlatformBootObservation(
                slot: .a,
                wasTryBoot: false,
                trialCapability: .oneShotAlternateSlot
            )
        )
        let trial = BootUpdateRuntimeBootContext.payload(
            PlatformBootObservation(
                slot: .b,
                wasTryBoot: true,
                trialCapability: .oneShotAlternateSlot
            )
        )
        expect(
            RaspberryPi5ABBootPolicy.disposition(
                for: .mediaLeaseUnavailable,
                context: normal
            ) == .retry,
            "transient owner conflict disabled A/B recovery"
        )
        expect(
            RaspberryPi5ABBootPolicy.disposition(
                for: .candidateStageFailed,
                context: normal
            ) == .suspendAndContinue,
            "missing persistent release source quarantined confirmed media"
        )
        expect(
            RaspberryPi5ABBootPolicy.disposition(
                for: .journalCommitFailed,
                context: normal
            ) == .quarantineAndReset,
            "uncertain journal durability allowed ordinary SD aliases"
        )
        expect(
            RaspberryPi5ABBootPolicy.disposition(
                for: .selectorCommitRejectedBeforeWrite,
                context: normal
            ) == .suspendAndContinue,
            "pre-write selector rejection forced a confirmed-slot reset loop"
        )
        expect(
            RaspberryPi5ABBootPolicy.disposition(
                for: .selectorCommitDurabilityUncertain,
                context: normal
            ) == .quarantineAndReset,
            "possibly written selector was allowed to publish SD aliases"
        )
        expect(
            RaspberryPi5ABBootPolicy.disposition(
                for: .orchestrator(.unexpectedBoot(
                    slot: .b,
                    wasTryBoot: true
                )),
                context: trial
            ) == .quarantineAndReset,
            "contradictory tryboot identity continued as healthy"
        )
        expect(
            RaspberryPi5ABBootPolicy.disposition(
                for: .orchestrator(.recoveryNotAuthorized),
                context: .recovery
            ) == .disableAndContinue,
            "diagnostic rescue boot was forced into a reset loop"
        )
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
                expectSlotsSemanticallyEqual(
                    on: pointer.pointee,
                    media: media
                )

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
                    metadataPolicy: RaspberryPiABUpdateLayout.metadataPolicy,
                    nextBlock: 0,
                    blockCount: 1
                )
                expect(
                    !port.stageCandidate(action),
                    "metadata alone gained inactive-slot write authority"
                )
                let beforeSelector = pointer.pointee.bytes
                expect(
                    port.commitSelector(BootSelectorCommitAction(
                        defaultSlot: .b
                    )) == .rejectedBeforeWrite,
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

    private static func suspendsBeforeWritingAnInvalidImmutableRescue() {
        var device = MemoryBlockDevice(blockCount: totalBlockCount)
        let media = makeMedia()
        fillSlotA(on: device, media: media)
        installSelectorBootSectorWithInvalidRescue(
            on: device,
            media: media
        )
        let digest = digestOfSlotA(on: device, media: media)
        let journal = selectorCommitPendingHistory(digest: digest)

        withScratch(byteCount: 1_024) { scratch in
            withUnsafeMutablePointer(to: &device) { pointer in
                formatAndSeedJournal(
                    on: pointer,
                    media: media,
                    digest: digest,
                    scratch: scratch,
                    records: journal
                )
                let selectorBefore = selectorBytes(
                    on: pointer.pointee,
                    media: media
                )
                guard var port = RaspberryPi5ABUpdatePort(
                          borrowing: pointer,
                          media: media,
                          scratch: scratch
                      )
                else { fail("invalid rescue fixture did not create a port") }
                var executor = BootUpdateRuntimeExecutor()
                guard case .recovered(let recovered) =
                        executor.recoverCurrentBoot(
                            through: &port,
                            observation: PlatformBootObservation(
                                slot: .a,
                                wasTryBoot: false,
                                trialCapability: .oneShotAlternateSlot
                            ),
                            layout: port.layout
                        )
                else { fail("selector-pending fixture did not recover") }
                expect(
                    recovered.phase == .selectorCommitPending,
                    "boot recovery discarded post-health selector intent"
                )
                expect(
                    executor.serviceOnce(
                        through: &port,
                        observation: PlatformBootObservation(
                            slot: .a,
                            wasTryBoot: false,
                            trialCapability: .oneShotAlternateSlot
                        ),
                        layout: port.layout,
                        maximumBlockCount: 128
                    ) == .failure(.selectorCommitRejectedBeforeWrite),
                    "immutable rescue rejection lost its no-write effect"
                )
                expect(
                    selectorBytes(on: pointer.pointee, media: media)
                        == selectorBefore,
                    "immutable rescue rejection modified the selector"
                )
                expect(
                    RaspberryPi5ABBootPolicy.disposition(
                        for: .selectorCommitRejectedBeforeWrite,
                        context: .payload(PlatformBootObservation(
                            slot: .a,
                            wasTryBoot: false,
                            trialCapability: .oneShotAlternateSlot
                        ))
                    ) == .suspendAndContinue,
                    "physical pre-write rejection still entered a reset loop"
                )
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
                    startBlock: 2_304,
                    blockCount: slotBlockCount,
                    within: totalBlockCount
                )!
            ),
            data: MBRPartition(
                index: 3,
                type: .swiftOSData,
                isBootable: false,
                range: BlockDeviceRange(
                    startBlock: 2_560,
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
        scratch: UnsafeMutableRawBufferPointer,
        records: [BootControlRecord]? = nil
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
        let history = records ?? [initialRecord(digest: digest)]
        var index = 0
        while index < history.count {
            let record = history[index]
            guard case .committed(_, let sequence) = BootControlJournal.commit(
                      record,
                      to: &data,
                      scratch: scratch
                  ), sequence == record.sequence
            else { fail("seed boot-control journal") }
            index += 1
        }
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

    private static func selectorCommitPendingHistory(
        digest: BootImageDigest
    ) -> [BootControlRecord] {
        let initial = initialRecord(digest: digest)
        let writing = transitioned(initial.beginCandidateWrite(
            to: .b,
            generation: 2,
            digest: digest,
            blockCount: slotBlockCount,
            trialToken: 9
        ))
        let written = transitioned(writing.recordCandidateProgress(
            nextBlock: slotBlockCount
        ))
        let trialPending = transitioned(written.sealCandidate())
        let trialBooting = transitioned(trialPending.observeBoot(
            slot: .b,
            wasTryBoot: true
        ))
        let selectorPending = transitioned(trialBooting.confirmCandidateHealth(
            slot: .b,
            generation: 2,
            digest: digest,
            trialToken: 9
        ))
        return [
            initial,
            writing,
            written,
            trialPending,
            trialBooting,
            selectorPending,
        ]
    }

    private static func transitioned(
        _ result: BootControlTransitionResult
    ) -> BootControlRecord {
        guard case .record(let record) = result else {
            fail("boot-control fixture transition")
        }
        return record
    }

    private static func installSelectorBootSectorWithInvalidRescue(
        on device: MemoryBlockDevice,
        media: SwiftOSABMediaPartitions
    ) {
        let base = Int(media.selector.range.startBlock) * 512
        device.bytes[base] = 0xeb
        device.bytes[base + 1] = 0x3c
        device.bytes[base + 2] = 0x90
        writeASCII("SWIFTOS ", on: device, at: base + 3)
        writeLE16(512, on: device, at: base + 11)
        device.bytes[base + 13] = 1
        writeLE16(1, on: device, at: base + 14)
        device.bytes[base + 16] = 2
        writeLE16(32, on: device, at: base + 17)
        writeLE16(2_047, on: device, at: base + 19)
        device.bytes[base + 21] = 0xf8
        writeLE16(6, on: device, at: base + 22)
        writeLE16(63, on: device, at: base + 24)
        writeLE16(255, on: device, at: base + 26)
        writeLE32(1, on: device, at: base + 28)
        device.bytes[base + 36] = 0x80
        device.bytes[base + 38] = 0x29
        writeLE32(0x4354_4c31, on: device, at: base + 39)
        writeASCII("SWIFTOS-CTL", on: device, at: base + 43)
        writeASCII("FAT12   ", on: device, at: base + 54)
        device.bytes[base + 510] = 0x55
        device.bytes[base + 511] = 0xaa
        // Bytes 64...191 intentionally remain zero. The boot sector is valid,
        // but the immutable rescue manifest is not, so commit must reject
        // before touching autoboot.txt's sector.
    }

    private static func selectorBytes(
        on device: MemoryBlockDevice,
        media: SwiftOSABMediaPartitions
    ) -> [UInt8] {
        let start = Int(media.selector.range.startBlock) * 512
        let count = Int(media.selector.range.blockCount) * 512
        return Array(device.bytes[start..<start + count])
    }

    private static func writeASCII(
        _ value: StaticString,
        on device: MemoryBlockDevice,
        at offset: Int
    ) {
        value.withUTF8Buffer { bytes in
            var index = 0
            while index < bytes.count {
                device.bytes[offset + index] = bytes[index]
                index += 1
            }
        }
    }

    private static func writeLE16(
        _ value: UInt16,
        on device: MemoryBlockDevice,
        at offset: Int
    ) {
        device.bytes[offset] = UInt8(truncatingIfNeeded: value)
        device.bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func writeLE32(
        _ value: UInt32,
        on device: MemoryBlockDevice,
        at offset: Int
    ) {
        writeLE16(UInt16(truncatingIfNeeded: value), on: device, at: offset)
        writeLE16(
            UInt16(truncatingIfNeeded: value >> 16),
            on: device,
            at: offset + 2
        )
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
        for relativeBlock: UInt64 in [0, 6] {
            writeLE32(
                UInt32(media.slotA.range.startBlock),
                on: device,
                at: start + Int(relativeBlock) * 512 + 28
            )
        }
    }

    private static func digestOfSlotA(
        on device: MemoryBlockDevice,
        media: SwiftOSABMediaPartitions
    ) -> BootImageDigest {
        let start = Int(media.slotA.range.startBlock) * 512
        var hash = USBKernelUpdateSHA256()
        var relativeBlock: UInt64 = 0
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: 512,
            alignment: 8
        )
        defer { pointer.deallocate() }
        let block = UnsafeMutableRawBufferPointer(start: pointer, count: 512)
        var updated = true
        while relativeBlock < slotBlockCount && updated {
            var byte = 0
            let source = start + Int(relativeBlock) * 512
            while byte < 512 {
                block[byte] = device.bytes[source + byte]
                byte += 1
            }
            updated = RaspberryPiABUpdateLayout.metadataPolicy
                .normalizeForContentDigest(
                    relativeBlock: relativeBlock,
                    slotStartBlock: media.slotA.range.startBlock,
                    bytes: block
                ) && hash.update(UnsafeRawBufferPointer(block))
            relativeBlock += 1
        }
        expect(updated, "slot digest input")
        let digestPointer = UnsafeMutableRawPointer.allocate(
            byteCount: 32,
            alignment: 8
        )
        defer { digestPointer.deallocate() }
        let bytes = UnsafeMutableRawBufferPointer(
            start: digestPointer,
            count: 32
        )
        expect(
            hash.finalizedDigest().write(to: bytes),
            "slot digest encoding"
        )
        return BootImageDigest(bytes: UnsafeRawBufferPointer(bytes))!
    }

    private static func expectSlotsSemanticallyEqual(
        on device: MemoryBlockDevice,
        media: SwiftOSABMediaPartitions
    ) {
        let a = Int(media.slotA.range.startBlock) * 512
        let b = Int(media.slotB.range.startBlock) * 512
        let count = Int(media.slotA.range.blockCount) * 512
        var index = 0
        while index < count {
            let relativeBlock = index / 512
            let byteInBlock = index % 512
            let isHiddenSectorByte = (relativeBlock == 0 || relativeBlock == 6)
                && byteInBlock >= 28
                && byteInBlock < 32
            if isHiddenSectorByte {
                index += 1
                continue
            }
            expect(
                device.bytes[a + index] == device.bytes[b + index],
                "activation-last mirror did not semantically converge"
            )
            index += 1
        }
        for relativeBlock in [0, 6] {
            expect(
                readLE32(device.bytes, at: a + relativeBlock * 512 + 28)
                    == UInt32(media.slotA.range.startBlock),
                "source FAT32 hidden sectors do not name slot A"
            )
            expect(
                readLE32(device.bytes, at: b + relativeBlock * 512 + 28)
                    == UInt32(media.slotB.range.startBlock),
                "destination FAT32 hidden sectors do not name slot B"
            )
        }
    }

    private static func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
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
