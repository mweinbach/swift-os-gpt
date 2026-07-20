@main
struct PreemptiveEL0SchedulerTests {
    static func main() {
        synthesizesEL0tContextsAndRotatesFullRegisterImages()
        attributesReportsToProcessorOwnershipAndRejectsSpoofing()
        migratesCompleteContextsAcrossFourProcessors()
        rejectsInvalidCapacitiesAndOverlappingContexts()
        print("preemptive EL0 scheduler host tests: 4 passed")
    }

    private static func
    synthesizesEL0tContextsAndRotatesFullRegisterImages() {
        withScheduler(processorCount: 1, threadCount: 2) {
            scheduler, liveFrames in
            let liveFrame = frame(at: 0, in: liveFrames)
            expect(
                scheduler.installInitialContext(on: 0, in: liveFrame),
                "initial context was not installed"
            )
            let registers = liveFrame.assumingMemoryBound(
                to: AArch64ExceptionFrame.self
            )
            expect(
                scheduler.activeThreadIdentifier(on: 0) == 11,
                "thread 11 start"
            )
            expect(registers.pointee.x0 == 11, "thread identifier argument")
            expect(registers.pointee.exceptionLink == 0x4000, "EL0 entry")
            expect(registers.pointee.savedProgramStatus == 0, "EL0t SPSR")
            expect(registers.pointee.stackPointerEL0 == 0x8000, "thread 11 SP")
            expect(
                registers.pointee.threadPointerEL0 == 0x1000,
                "thread 11 TPIDR"
            )

            registers.pointee.q0 = AArch64SIMDRegister(
                low: 0x1111_0000_0000_0001,
                high: 0x1111_0000_0000_0002
            )
            registers.pointee.q31 = AArch64SIMDRegister(
                low: 0x1111_0000_0000_0031,
                high: 0x1111_0000_0000_0032
            )
            registers.pointee.floatingPointControl = 0x101
            registers.pointee.floatingPointStatus = 0x202
            registers.pointee.x19 = 0x1919
            registers.pointee.x30 = 0x3030
            registers.pointee.stackPointerEL0 = 0x7f00
            registers.pointee.threadPointerEL0 = 0x11aa

            expect(
                scheduler.handleTimerInterrupt(on: 0, frame: liveFrame),
                "first timer preemption"
            )
            expect(
                scheduler.activeThreadIdentifier(on: 0) == 22,
                "thread 22 active"
            )
            expect(registers.pointee.x0 == 22, "thread 22 identifier")
            expect(registers.pointee.q0.low == 0, "thread 22 SIMD not clean")
            expect(registers.pointee.stackPointerEL0 == 0xa000, "thread 22 SP")
            expect(
                registers.pointee.threadPointerEL0 == 0x2000,
                "thread 22 TPIDR"
            )

            registers.pointee.q0 = AArch64SIMDRegister(
                low: 0x2222_0000_0000_0001,
                high: 0x2222_0000_0000_0002
            )
            registers.pointee.q31 = AArch64SIMDRegister(
                low: 0x2222_0000_0000_0031,
                high: 0x2222_0000_0000_0032
            )
            registers.pointee.floatingPointControl = 0x303
            registers.pointee.floatingPointStatus = 0x404
            registers.pointee.x19 = 0x2929
            registers.pointee.x30 = 0x4040
            registers.pointee.stackPointerEL0 = 0x9e00
            registers.pointee.threadPointerEL0 = 0x22bb

            expect(
                scheduler.handleTimerInterrupt(on: 0, frame: liveFrame),
                "second timer preemption"
            )
            expect(
                scheduler.activeThreadIdentifier(on: 0) == 11,
                "round robin wrap"
            )
            expect(registers.pointee.q0.low == 0x1111_0000_0000_0001, "q0 low")
            expect(
                registers.pointee.q0.high == 0x1111_0000_0000_0002,
                "q0 high"
            )
            expect(
                registers.pointee.q31.low == 0x1111_0000_0000_0031,
                "q31 low"
            )
            expect(
                registers.pointee.q31.high == 0x1111_0000_0000_0032,
                "q31 high"
            )
            expect(registers.pointee.floatingPointControl == 0x101, "FPCR")
            expect(registers.pointee.floatingPointStatus == 0x202, "FPSR")
            expect(registers.pointee.x19 == 0x1919, "callee-saved register")
            expect(registers.pointee.x30 == 0x3030, "link register")
            expect(registers.pointee.stackPointerEL0 == 0x7f00, "isolated SP")
            expect(
                registers.pointee.threadPointerEL0 == 0x11aa,
                "isolated TPIDR"
            )

            let evidence = scheduler.evidence
            expect(evidence.timerInterruptCount == 2, "timer count")
            expect(evidence.involuntarySwitchCount == 2, "switch count")
            expect(!evidence.demonstratesCrossProcessorMigration, "false migration")
        }
    }

    private static func
    attributesReportsToProcessorOwnershipAndRejectsSpoofing() {
        withScheduler(processorCount: 2, threadCount: 3) {
            scheduler, liveFrames in
            let cpu0 = frame(at: 0, in: liveFrames)
            let cpu1 = frame(at: 1, in: liveFrames)
            expect(scheduler.installInitialContext(on: 0, in: cpu0), "CPU0 begin")
            expect(scheduler.installInitialContext(on: 1, in: cpu1), "CPU1 begin")
            expect(scheduler.activeThreadIdentifier(on: 0) == 11, "CPU0 owner")
            expect(scheduler.activeThreadIdentifier(on: 1) == 22, "CPU1 owner")

            setReport(cpu0, threadIdentifier: 11, sequence: 1, checksum: 0xaaaa)
            expect(
                scheduler.handleReportSystemCall(on: 0, frame: cpu0)
                    == .reportAccepted,
                "CPU0 report"
            )

            setReport(cpu1, threadIdentifier: 11, sequence: 1, checksum: 0xffff)
            expect(
                scheduler.handleReportSystemCall(on: 1, frame: cpu1)
                    == .rejectedReport,
                "spoofed CPU1 report"
            )
            expect(
                scheduler.reportSnapshot(threadIdentifier: 11)?.reportCount == 1,
                "spoof changed report state"
            )

            setReport(cpu1, threadIdentifier: 22, sequence: 1, checksum: 0xbbbb)
            expect(
                scheduler.handleReportSystemCall(on: 1, frame: cpu1)
                    == .reportAccepted,
                "CPU1 owner report"
            )
            expect(scheduler.handleTimerInterrupt(on: 0, frame: cpu0), "CPU0 preempt")
            expect(scheduler.activeThreadIdentifier(on: 0) == 33, "CPU0 next")
            expect(scheduler.handleTimerInterrupt(on: 1, frame: cpu1), "CPU1 preempt")
            expect(
                scheduler.activeThreadIdentifier(on: 1) == 11,
                "thread 11 was not pulled by CPU1"
            )

            setReport(cpu1, threadIdentifier: 11, sequence: 2, checksum: 0xaaab)
            expect(
                scheduler.handleReportSystemCall(on: 1, frame: cpu1)
                    == .reportAccepted,
                "migrated report"
            )
            let snapshot = scheduler.reportSnapshot(threadIdentifier: 11)
            expect(snapshot?.reportCount == 2, "migrated report count")
            expect(snapshot?.processorMask == 0b11, "migrated processor mask")
            expect(snapshot?.migrationCount == 1, "migration transition count")
            expect(
                snapshot?.observedMultipleProcessors == true,
                "execution migration not proven"
            )

            let cpu1Registers = cpu1.assumingMemoryBound(
                to: AArch64ExceptionFrame.self
            )
            cpu1Registers.pointee.q5 = AArch64SIMDRegister(
                low: 0x5050_0000_0000_0001,
                high: 0x5050_0000_0000_0002
            )
            cpu1Registers.pointee.x24 = 0x2424
            expect(
                scheduler.relinquishProcessor(on: 1, frame: cpu1),
                "CPU1 shutdown relinquish"
            )
            expect(
                scheduler.activeThreadIdentifier(on: 1) == nil,
                "relinquished CPU1 retained ownership"
            )
            expect(
                scheduler.installInitialContext(on: 1, in: cpu1),
                "CPU1 failed to rejoin after returned shutdown"
            )
            expect(
                scheduler.activeThreadIdentifier(on: 1) == 11,
                "CPU1 did not restore relinquished context"
            )
            expect(
                cpu1Registers.pointee.q5.low == 0x5050_0000_0000_0001
                    && cpu1Registers.pointee.q5.high
                        == 0x5050_0000_0000_0002
                    && cpu1Registers.pointee.x24 == 0x2424,
                "shutdown handoff lost the complete context"
            )

            setReport(cpu0, threadIdentifier: 33, sequence: 1, checksum: 0xcccc)
            expect(
                scheduler.handleReportSystemCall(on: 0, frame: cpu0)
                    == .reportAccepted,
                "third thread report"
            )
            let evidence = scheduler.evidence
            expect(evidence.allThreadsReported, "not all threads reported")
            expect(evidence.reportingProcessorMask == 0b11, "reporting CPUs")
            expect(evidence.migratedThreadCount == 1, "migrated thread count")
            expect(
                evidence.demonstratesCrossProcessorMigration,
                "aggregate migration evidence"
            )
            expect(
                evidence.demonstratesPreemptiveMultithreading,
                "preemption evidence"
            )
        }
    }

    private static func migratesCompleteContextsAcrossFourProcessors() {
        withScheduler(processorCount: 4, threadCount: 5) {
            scheduler, liveFrames in
            var processor = 0
            while processor < 4 {
                expect(
                    scheduler.installInitialContext(
                        on: processor,
                        in: frame(at: processor, in: liveFrames)
                    ),
                    "four-CPU initial lease"
                )
                expect(
                    scheduler.activeThreadIdentifier(on: processor)
                        == UInt32((processor + 1) * 11),
                    "wrong initial processor owner"
                )
                processor += 1
            }

            let cpu0 = frame(at: 0, in: liveFrames)
            let cpu1 = frame(at: 1, in: liveFrames)
            setReport(cpu0, threadIdentifier: 11, sequence: 1, checksum: 0x1111)
            expect(
                scheduler.handleReportSystemCall(on: 0, frame: cpu0)
                    == .reportAccepted,
                "thread 11 initial execution"
            )
            let outgoing = cpu0.assumingMemoryBound(to: AArch64ExceptionFrame.self)
            outgoing.pointee.q17 = AArch64SIMDRegister(
                low: 0x1717_0000_0000_0001,
                high: 0x1717_0000_0000_0002
            )
            outgoing.pointee.x27 = 0x2727
            outgoing.pointee.stackPointerEL0 = 0x7e00
            outgoing.pointee.threadPointerEL0 = 0x11cc

            expect(scheduler.handleTimerInterrupt(on: 0, frame: cpu0), "CPU0 rotate")
            expect(scheduler.activeThreadIdentifier(on: 0) == 55, "fifth ready")
            expect(scheduler.handleTimerInterrupt(on: 1, frame: cpu1), "CPU1 rotate")
            expect(scheduler.activeThreadIdentifier(on: 1) == 11, "cross-core pull")

            let incoming = cpu1.assumingMemoryBound(to: AArch64ExceptionFrame.self)
            expect(
                incoming.pointee.q17.low == 0x1717_0000_0000_0001,
                "migrated SIMD low"
            )
            expect(
                incoming.pointee.q17.high == 0x1717_0000_0000_0002,
                "migrated SIMD high"
            )
            expect(incoming.pointee.x27 == 0x2727, "migrated GPR")
            expect(incoming.pointee.stackPointerEL0 == 0x7e00, "migrated SP")
            expect(incoming.pointee.threadPointerEL0 == 0x11cc, "migrated TPIDR")

            setReport(cpu1, threadIdentifier: 11, sequence: 2, checksum: 0x1112)
            expect(
                scheduler.handleReportSystemCall(on: 1, frame: cpu1)
                    == .reportAccepted,
                "thread 11 migrated execution"
            )
            expect(
                scheduler.evidence.demonstratesCrossProcessorMigration,
                "four-CPU migration evidence"
            )

            processor = 0
            while processor < 4 {
                guard let identifier = scheduler.activeThreadIdentifier(
                    on: processor
                ) else {
                    fatalError("processor lost current thread")
                }
                var other = processor + 1
                while other < 4 {
                    expect(
                        scheduler.activeThreadIdentifier(on: other)
                            != identifier,
                        "one thread is running on two processors"
                    )
                    other += 1
                }
                processor += 1
            }
        }
    }

    private static func rejectsInvalidCapacitiesAndOverlappingContexts() {
        let contextBytes = AArch64ExceptionFrame.byteCount * 2
        let contexts = UnsafeMutableRawPointer.allocate(
            byteCount: contextBytes,
            alignment: 16
        )
        let bootstraps = UnsafeMutableBufferPointer<EL0ThreadBootstrap>
            .allocate(capacity: 2)
        let scheduled = UnsafeMutableBufferPointer<ScheduledThread>
            .allocate(capacity: 2)
        let processors = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 2)
        let reports = UnsafeMutableBufferPointer<EL0ThreadReportRecord>
            .allocate(capacity: 2)
        defer {
            contexts.deallocate()
            bootstraps.deallocate()
            scheduled.deallocate()
            processors.deallocate()
            reports.deallocate()
        }

        let base = UInt64(UInt(bitPattern: contexts))
        bootstraps[0] = EL0ThreadBootstrap(
            identifier: 1,
            contextAddress: base,
            userStackTop: 0x8000,
            threadPointer: 0x1000
        )
        bootstraps[1] = EL0ThreadBootstrap(
            identifier: 2,
            contextAddress: base + 16,
            userStackTop: 0xa000,
            threadPointer: 0x2000
        )
        let immutable = UnsafeBufferPointer(bootstraps)
        expect(
            PreemptiveEL0Scheduler(
                threadStorage: scheduled,
                currentIndexStorage: processors,
                reportStorage: reports,
                processorCount: 2,
                processIdentifier: 1,
                userEntryAddress: 0x4000,
                threads: immutable
            ) == nil,
            "overlapping context frames were accepted"
        )

        bootstraps[1] = EL0ThreadBootstrap(
            identifier: 2,
            contextAddress: base + UInt64(AArch64ExceptionFrame.byteCount),
            userStackTop: 0xa000,
            threadPointer: 0x2000
        )
        expect(
            PreemptiveEL0Scheduler(
                threadStorage: scheduled,
                currentIndexStorage: processors,
                reportStorage: reports,
                processorCount: 0,
                processIdentifier: 1,
                userEntryAddress: 0x4000,
                threads: immutable
            ) == nil,
            "zero processors were accepted"
        )
        expect(
            PreemptiveEL0Scheduler(
                threadStorage: scheduled,
                currentIndexStorage: processors,
                reportStorage: reports,
                processorCount: 3,
                processIdentifier: 1,
                userEntryAddress: 0x4000,
                threads: immutable
            ) == nil,
            "fewer threads than processors were accepted"
        )
    }

    private static func setReport(
        _ rawFrame: UnsafeMutableRawPointer,
        threadIdentifier: UInt64,
        sequence: UInt64,
        checksum: UInt64
    ) {
        let frame = rawFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
        frame.pointee.vectorSlot = 8
        frame.pointee.syndrome = 0x15 << 26
        frame.pointee.x8 = PreemptiveEL0Scheduler.reportSystemCallNumber
        frame.pointee.x0 = threadIdentifier
        frame.pointee.x1 = sequence
        frame.pointee.x2 = checksum
    }
}

private func withScheduler(
    processorCount: Int,
    threadCount: Int,
    body: (
        inout PreemptiveEL0Scheduler,
        UnsafeMutableRawPointer
    ) -> Void
) {
    let contextBytes = threadCount * AArch64ExceptionFrame.byteCount
    let liveBytes = processorCount * AArch64ExceptionFrame.byteCount
    let contexts = UnsafeMutableRawPointer.allocate(
        byteCount: contextBytes,
        alignment: 16
    )
    let liveFrames = UnsafeMutableRawPointer.allocate(
        byteCount: liveBytes,
        alignment: 16
    )
    let bootstraps = UnsafeMutableBufferPointer<EL0ThreadBootstrap>
        .allocate(capacity: threadCount)
    let scheduled = UnsafeMutableBufferPointer<ScheduledThread>
        .allocate(capacity: threadCount)
    let processors = UnsafeMutableBufferPointer<Int32>
        .allocate(capacity: processorCount)
    let reports = UnsafeMutableBufferPointer<EL0ThreadReportRecord>
        .allocate(capacity: threadCount)
    defer {
        contexts.deallocate()
        liveFrames.deallocate()
        bootstraps.deallocate()
        scheduled.deallocate()
        processors.deallocate()
        reports.deallocate()
    }

    var index = 0
    while index < threadCount {
        bootstraps[index] = EL0ThreadBootstrap(
            identifier: UInt32((index + 1) * 11),
            contextAddress: UInt64(UInt(bitPattern: contexts.advanced(
                by: index * AArch64ExceptionFrame.byteCount
            ))),
            userStackTop: 0x8000 + UInt64(index) * 0x2000,
            threadPointer: 0x1000 + UInt64(index) * 0x1000
        )
        index += 1
    }
    var scheduler = PreemptiveEL0Scheduler(
        threadStorage: scheduled,
        currentIndexStorage: processors,
        reportStorage: reports,
        processorCount: processorCount,
        processIdentifier: 7,
        userEntryAddress: 0x4000,
        threads: UnsafeBufferPointer(bootstraps)
    )!
    body(&scheduler, liveFrames)
}

private func frame(
    at processor: Int,
    in storage: UnsafeMutableRawPointer
) -> UnsafeMutableRawPointer {
    storage.advanced(by: processor * AArch64ExceptionFrame.byteCount)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
