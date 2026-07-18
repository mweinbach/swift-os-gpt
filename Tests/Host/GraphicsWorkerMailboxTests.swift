private nonisolated(unsafe) var acquireLoadCount: UInt64 = 0
private nonisolated(unsafe) var releaseStoreCount: UInt64 = 0

@_cdecl("swiftos_test_graphics_mailbox_load_acquire")
private func testLoadAcquire(_ address: UnsafePointer<UInt64>) -> UInt64 {
    acquireLoadCount &+= 1
    return address.pointee
}

@_cdecl("swiftos_test_graphics_mailbox_store_release")
private func testStoreRelease(
    _ address: UnsafeMutablePointer<UInt64>,
    _ value: UInt64
) {
    releaseStoreCount &+= 1
    address.pointee = value
}

@main
struct GraphicsWorkerMailboxTests {
    static func main() {
        validatesStorageAndScalarTransactions()
        transitionsWorkerLifecycle()
        appliesBoundedBackpressureAndFIFOOrdering()
        wrapsRingCursorsWithoutLosingCapacity()
        coalescesFrameRequestsAndPublishesCompletion()
        wrapsFrameSequencesAndWorksWithoutWakeEvents()
        verifiesInjectedPublicationOperationsAreUsed()
        print("Graphics worker mailbox host tests: 7 groups passed")
    }

    private static func validatesStorageAndScalarTransactions() {
        expect(
            GraphicsSceneTransaction(
                transactionID: 0,
                sceneRevision: 1,
                opcode: .commitScene
            ) == nil,
            "zero transaction identifier accepted"
        )
        expect(
            GraphicsSceneTransaction(
                transactionID: 1,
                sceneRevision: 0,
                opcode: .commitScene
            ) == nil,
            "zero scene revision accepted"
        )

        var nonPowerOfTwo = Array(repeating: transaction(99), count: 3)
        var controls = Array(
            repeating: UInt64(0),
            count: GraphicsWorkerMailbox.requiredControlWordCount
        )
        nonPowerOfTwo.withUnsafeMutableBufferPointer { transactions in
            controls.withUnsafeMutableBufferPointer { control in
                expect(
                    GraphicsWorkerMailbox(
                        transactionStorage: transactions,
                        controlStorage: control,
                        atomicAccess: atomicAccess()
                    ) == nil,
                    "non-power-of-two ring accepted"
                )
            }
        }

        var transactions = Array(repeating: transaction(99), count: 4)
        var shortControls = Array(
            repeating: UInt64(0),
            count: GraphicsWorkerMailbox.requiredControlWordCount - 1
        )
        transactions.withUnsafeMutableBufferPointer { transactionBuffer in
            shortControls.withUnsafeMutableBufferPointer { controlBuffer in
                expect(
                    GraphicsWorkerMailbox(
                        transactionStorage: transactionBuffer,
                        controlStorage: controlBuffer,
                        atomicAccess: atomicAccess()
                    ) == nil,
                    "undersized control block accepted"
                )
            }
        }

        let payload = GraphicsSceneTransactionPayload(
            word0: 11,
            word1: 22,
            word2: 33,
            word3: 44,
            word4: 55,
            word5: 66
        )
        let value = requireTransaction(
            GraphicsSceneTransaction(
                transactionID: 7,
                sceneRevision: 9,
                opcode: .upsertLayer,
                flags: 3,
                objectID: 41,
                payload: payload
            )
        )
        expect(value.payload.word5 == 66, "scalar payload lost")
        expect(
            MemoryLayout<GraphicsSceneTransaction>.size
                == MemoryLayout<GraphicsSceneTransaction>.stride,
            "transaction has trailing storage"
        )
    }

    private static func transitionsWorkerLifecycle() {
        withMailbox { mailbox in
            expect(mailbox.producer.workerStatus == .unconfigured, "initial phase")
            expect(
                mailbox.producer.configureWorker(configurationSequence: 0)
                    == .invalidSequence,
                "zero configuration sequence accepted"
            )
            expect(
                mailbox.worker.markReady(configurationSequence: 7)
                    == .rejected(currentStatus: .unconfigured),
                "worker became ready before configuration"
            )
            expect(
                mailbox.producer.configureWorker(configurationSequence: 7)
                    == .configured,
                "configuration was not published"
            )
            expect(
                mailbox.worker.workerStatus
                    == .configured(configurationSequence: 7),
                "worker did not acquire configuration"
            )
            expect(
                mailbox.producer.configureWorker(configurationSequence: 8)
                    == .rejected(
                        currentStatus: .configured(configurationSequence: 7)
                    ),
                "mailbox was reconfigured concurrently"
            )
            expect(
                mailbox.worker.markReady(configurationSequence: 8)
                    == .rejected(
                        currentStatus: .configured(configurationSequence: 7)
                    ),
                "wrong configuration became ready"
            )
            expect(
                mailbox.worker.markReady(configurationSequence: 7)
                    == .transitioned,
                "ready transition failed"
            )
            expect(
                mailbox.producer.workerStatus
                    == .ready(configurationSequence: 7),
                "producer did not acquire ready phase"
            )
            expect(
                mailbox.worker.markFailed(configurationSequence: 7, code: 0)
                    == .invalidFailureCode,
                "zero failure code accepted"
            )
            expect(
                mailbox.worker.markFailed(configurationSequence: 8, code: 19)
                    == .rejected(
                        currentStatus: .ready(configurationSequence: 7)
                    ),
                "wrong configuration published failure"
            )
            expect(
                mailbox.worker.markFailed(configurationSequence: 7, code: 19)
                    == .transitioned,
                "failure transition failed"
            )
            expect(
                mailbox.producer.workerStatus
                    == .failed(configurationSequence: 7, code: 19),
                "failure details were not acquired"
            )
            expect(
                mailbox.producer.enqueue(transaction(1))
                    == .workerFailed(code: 19),
                "producer queued work for failed worker"
            )
        }
    }

    private static func appliesBoundedBackpressureAndFIFOOrdering() {
        withMailbox(capacity: 4) { mailbox in
            for identifier in UInt64(1)...UInt64(4) {
                expectEnqueued(
                    mailbox.producer.enqueue(transaction(identifier)),
                    "enqueue \(identifier)"
                )
            }
            expect(mailbox.producer.pendingTransactionCount == 4, "pending count")
            expect(
                mailbox.producer.enqueue(transaction(5))
                    == .full(pendingCount: 4),
                "full ring did not apply bounded backpressure"
            )

            for identifier in UInt64(1)...UInt64(4) {
                let dequeued = requireDequeued(mailbox.worker.dequeue())
                expect(
                    dequeued.transactionID == identifier,
                    "FIFO order changed"
                )
            }
            expect(mailbox.worker.dequeue() == .empty, "empty ring produced a value")
            expect(mailbox.worker.pendingTransactionCount == 0, "ring not reclaimed")

            expectEnqueued(
                mailbox.producer.enqueue(transaction(6)),
                "reused reclaimed slot"
            )
            expect(
                requireDequeued(mailbox.worker.dequeue()).transactionID == 6,
                "reclaimed slot payload"
            )
        }
    }

    private static func wrapsRingCursorsWithoutLosingCapacity() {
        withMailbox(
            capacity: 4,
            initialRingCursor: UInt64.max - 1
        ) { mailbox in
            let expectedPublished = [
                UInt64.max,
                UInt64(0),
                UInt64(1),
                UInt64(2),
            ]
            for index in 0..<4 {
                expect(
                    mailbox.producer.enqueue(transaction(UInt64(index + 1)))
                        == .enqueued(publishedCursor: expectedPublished[index]),
                    "wrapped producer cursor \(index)"
                )
            }
            expect(
                mailbox.producer.enqueue(transaction(5))
                    == .full(pendingCount: 4),
                "wrapped full distance"
            )

            let expectedReclaimed = expectedPublished
            for index in 0..<4 {
                switch mailbox.worker.dequeue() {
                case .dequeued(let value, let reclaimed):
                    expect(value.transactionID == UInt64(index + 1), "wrapped FIFO")
                    expect(reclaimed == expectedReclaimed[index], "wrapped reclaim")
                default:
                    fatalError("wrapped dequeue \(index) failed")
                }
            }
            expect(mailbox.worker.dequeue() == .empty, "wrapped ring not empty")
        }
    }

    private static func coalescesFrameRequestsAndPublishesCompletion() {
        withMailbox { mailbox in
            let first = mailbox.producer.requestFrame()
            expect(first.sequence == 1, "first frame sequence")
            expect(!first.coalescedPendingRequest, "first request coalesced")

            let second = mailbox.producer.requestFrame()
            expect(second.sequence == 2, "second frame sequence")
            expect(second.coalescedPendingRequest, "pending request not coalesced")
            expect(
                mailbox.worker.latestFrameRequest(after: 0) == 2,
                "worker observed stale coalesced request"
            )
            expect(
                mailbox.worker.completeFrame(sequence: 2) == .completed,
                "coalesced request completion"
            )
            expect(
                mailbox.producer.frameSequences
                    == GraphicsFrameSequenceSnapshot(requested: 2, completed: 2),
                "completion was not published"
            )
            expect(
                mailbox.worker.completeFrame(sequence: 2) == .duplicate,
                "duplicate completion advanced"
            )

            let third = mailbox.producer.requestFrame()
            expect(third.sequence == 3, "third frame sequence")
            expect(!third.coalescedPendingRequest, "completed request stayed pending")
            let fourth = mailbox.producer.requestFrame()
            expect(fourth.sequence == 4, "fourth frame sequence")
            expect(
                mailbox.worker.completeFrame(sequence: 3) == .completed,
                "older observed request could not complete"
            )
            expect(mailbox.producer.frameSequences.hasPendingRequest, "newer frame lost")
            expect(
                mailbox.worker.completeFrame(sequence: 4) == .completed,
                "newest request completion"
            )
        }
    }

    private static func wrapsFrameSequencesAndWorksWithoutWakeEvents() {
        withMailbox(initialFrameSequence: UInt64.max - 1) { mailbox in
            let beforeWrap = mailbox.producer.requestFrame()
            let afterWrap = mailbox.producer.requestFrame()
            expect(beforeWrap.sequence == UInt64.max, "pre-wrap sequence")
            expect(afterWrap.sequence == 0, "wrapped sequence")

            // No event or wait primitive is invoked between publication and
            // polling: acquire/release state alone carries correctness.
            expect(
                mailbox.worker.latestFrameRequest(after: UInt64.max - 1) == 0,
                "polling missed wrapped coalesced request"
            )
            expect(
                mailbox.worker.completeFrame(sequence: 0) == .completed,
                "wrapped completion rejected"
            )
            expect(!mailbox.producer.frameSequences.hasPendingRequest, "wrap pending")
            expect(
                mailbox.worker.completeFrame(sequence: UInt64.max) == .outOfOrder,
                "stale pre-wrap completion accepted"
            )
        }
    }

    private static func verifiesInjectedPublicationOperationsAreUsed() {
        acquireLoadCount = 0
        releaseStoreCount = 0
        withMailbox { mailbox in
            expect(
                mailbox.producer.configureWorker(configurationSequence: 1)
                    == .configured,
                "publication probe configure"
            )
            expect(
                mailbox.worker.markReady(configurationSequence: 1)
                    == .transitioned,
                "publication probe ready"
            )
            expectEnqueued(
                mailbox.producer.enqueue(transaction(1)),
                "publication probe enqueue"
            )
            _ = mailbox.worker.dequeue()
            _ = mailbox.producer.requestFrame()
            _ = mailbox.worker.completeFrame(sequence: 1)
        }
        expect(acquireLoadCount >= 10, "injected acquire loads were bypassed")
        expect(releaseStoreCount >= 8, "injected release stores were bypassed")
    }

    private static func withMailbox(
        capacity: Int = 4,
        initialRingCursor: UInt64 = 0,
        initialFrameSequence: UInt64 = 0,
        _ body: (GraphicsWorkerMailbox) -> Void
    ) {
        var transactions = Array(repeating: transaction(99), count: capacity)
        var controls = Array(
            repeating: UInt64(0),
            count: GraphicsWorkerMailbox.requiredControlWordCount
        )
        transactions.withUnsafeMutableBufferPointer { transactionBuffer in
            controls.withUnsafeMutableBufferPointer { controlBuffer in
                guard let mailbox = GraphicsWorkerMailbox(
                    transactionStorage: transactionBuffer,
                    controlStorage: controlBuffer,
                    atomicAccess: atomicAccess(),
                    initialRingCursor: initialRingCursor,
                    initialFrameSequence: initialFrameSequence
                ) else {
                    fatalError("valid mailbox rejected")
                }
                body(mailbox)
            }
        }
    }

    private static func atomicAccess() -> GraphicsMailboxAtomicAccess {
        GraphicsMailboxAtomicAccess(
            loadAcquire: testLoadAcquire,
            storeRelease: testStoreRelease
        )
    }

    private static func transaction(_ identifier: UInt64) -> GraphicsSceneTransaction {
        requireTransaction(
            GraphicsSceneTransaction(
                transactionID: identifier,
                sceneRevision: identifier,
                opcode: .upsertLayer,
                objectID: identifier,
                payload: GraphicsSceneTransactionPayload(word0: identifier)
            )
        )
    }

    private static func requireTransaction(
        _ transaction: GraphicsSceneTransaction?
    ) -> GraphicsSceneTransaction {
        guard let transaction else { fatalError("valid transaction rejected") }
        return transaction
    }

    private static func requireDequeued(
        _ result: GraphicsSceneDequeueResult
    ) -> GraphicsSceneTransaction {
        guard case .dequeued(let transaction, _) = result else {
            fatalError("expected transaction, got \(result)")
        }
        return transaction
    }

    private static func expectEnqueued(
        _ result: GraphicsSceneEnqueueResult,
        _ context: String
    ) {
        guard case .enqueued = result else {
            fatalError("\(context): expected enqueue, got \(result)")
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
