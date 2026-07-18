@main
struct PreemptiveEL0SchedulerTests {
    static func main() {
        synthesizesEL0tContextsAndRotatesFullRegisterImages()
        keepsReportSyscallsSeparateFromTimerPreemption()
        rejectsAliasedOrMalformedThreadStorage()
        print("preemptive EL0 scheduler host tests: 3 passed")
    }

    private static func synthesizesEL0tContextsAndRotatesFullRegisterImages() {
        withScheduler { scheduler, liveFrame in
            expect(
                scheduler.installInitialContext(in: liveFrame),
                "initial context was not installed"
            )
            let frame = liveFrame.assumingMemoryBound(
                to: AArch64ExceptionFrame.self
            )
            expect(scheduler.activeThreadIdentifier == 11, "thread 11 start")
            expect(frame.pointee.x0 == 11, "thread identifier argument")
            expect(frame.pointee.exceptionLink == 0x4000, "EL0 entry")
            expect(frame.pointee.savedProgramStatus == 0, "EL0t SPSR")
            expect(frame.pointee.stackPointerEL0 == 0x8000, "thread 11 SP")
            expect(frame.pointee.threadPointerEL0 == 0x1111, "thread 11 TPIDR")

            frame.pointee.q0 = AArch64SIMDRegister(
                low: 0x1111_0000_0000_0001,
                high: 0x1111_0000_0000_0002
            )
            frame.pointee.q31 = AArch64SIMDRegister(
                low: 0x1111_0000_0000_0031,
                high: 0x1111_0000_0000_0032
            )
            frame.pointee.floatingPointControl = 0x101
            frame.pointee.floatingPointStatus = 0x202
            frame.pointee.x19 = 0x1919
            frame.pointee.x30 = 0x3030
            frame.pointee.stackPointerEL0 = 0x7f00
            frame.pointee.threadPointerEL0 = 0x11aa

            expect(
                scheduler.handleTimerInterrupt(frame: liveFrame),
                "first timer preemption"
            )
            expect(scheduler.activeThreadIdentifier == 22, "thread 22 active")
            expect(frame.pointee.x0 == 22, "thread 22 identifier")
            expect(frame.pointee.q0.low == 0, "thread 22 SIMD was not clean")
            expect(frame.pointee.stackPointerEL0 == 0xa000, "thread 22 SP")
            expect(frame.pointee.threadPointerEL0 == 0x2222, "thread 22 TPIDR")

            frame.pointee.q0 = AArch64SIMDRegister(
                low: 0x2222_0000_0000_0001,
                high: 0x2222_0000_0000_0002
            )
            frame.pointee.q31 = AArch64SIMDRegister(
                low: 0x2222_0000_0000_0031,
                high: 0x2222_0000_0000_0032
            )
            frame.pointee.floatingPointControl = 0x303
            frame.pointee.floatingPointStatus = 0x404
            frame.pointee.x19 = 0x2929
            frame.pointee.x30 = 0x4040
            frame.pointee.stackPointerEL0 = 0x9e00
            frame.pointee.threadPointerEL0 = 0x22bb

            expect(
                scheduler.handleTimerInterrupt(frame: liveFrame),
                "second timer preemption"
            )
            expect(scheduler.activeThreadIdentifier == 11, "round robin wrap")
            expect(frame.pointee.q0.low == 0x1111_0000_0000_0001, "q0 low")
            expect(frame.pointee.q0.high == 0x1111_0000_0000_0002, "q0 high")
            expect(frame.pointee.q31.low == 0x1111_0000_0000_0031, "q31 low")
            expect(frame.pointee.q31.high == 0x1111_0000_0000_0032, "q31 high")
            expect(frame.pointee.floatingPointControl == 0x101, "FPCR")
            expect(frame.pointee.floatingPointStatus == 0x202, "FPSR")
            expect(frame.pointee.x19 == 0x1919, "callee-saved register")
            expect(frame.pointee.x30 == 0x3030, "link register")
            expect(frame.pointee.stackPointerEL0 == 0x7f00, "isolated SP_EL0")
            expect(frame.pointee.threadPointerEL0 == 0x11aa, "isolated TPIDR_EL0")

            expect(
                scheduler.handleTimerInterrupt(frame: liveFrame),
                "third timer preemption"
            )
            expect(frame.pointee.q0.low == 0x2222_0000_0000_0001, "thread 22 q0")
            expect(frame.pointee.q31.high == 0x2222_0000_0000_0032, "thread 22 q31")
            expect(frame.pointee.stackPointerEL0 == 0x9e00, "thread 22 saved SP")
            expect(frame.pointee.threadPointerEL0 == 0x22bb, "thread 22 saved TPIDR")
        }
    }

    private static func keepsReportSyscallsSeparateFromTimerPreemption() {
        withScheduler { scheduler, liveFrame in
            expect(scheduler.installInitialContext(in: liveFrame), "start")
            let frame = liveFrame.assumingMemoryBound(
                to: AArch64ExceptionFrame.self
            )

            setReport(
                frame,
                threadIdentifier: 11,
                sequence: 1,
                checksum: 0xaaaa
            )
            expect(
                scheduler.handleReportSystemCall(frame: liveFrame)
                    == .reportAccepted,
                "thread 11 report"
            )
            expect(frame.pointee.x0 == 0, "syscall success result")
            expect(
                scheduler.evidence.involuntarySwitchCount == 0,
                "report syscall performed a context switch"
            )

            expect(scheduler.handleTimerInterrupt(frame: liveFrame), "switch 1")
            setReport(
                frame,
                threadIdentifier: 22,
                sequence: 1,
                checksum: 0xbbbb
            )
            expect(
                scheduler.handleReportSystemCall(frame: liveFrame)
                    == .reportAccepted,
                "thread 22 report"
            )
            expect(scheduler.evidence.bothThreadsReported, "both reports")
            expect(
                !scheduler.evidence.demonstratesPreemptiveMultithreading,
                "one switch was incorrectly sufficient evidence"
            )

            frame.pointee.x8 = 99
            expect(
                scheduler.handleReportSystemCall(frame: liveFrame)
                    == .unsupported,
                "unsupported syscall was accepted"
            )
            expect(scheduler.handleTimerInterrupt(frame: liveFrame), "switch 2")

            let evidence = scheduler.evidence
            expect(evidence.timerInterruptCount == 2, "timer count")
            expect(evidence.involuntarySwitchCount == 2, "switch count")
            expect(evidence.firstThread.reportCount == 1, "thread 11 reports")
            expect(evidence.firstThread.lastSequence == 1, "thread 11 sequence")
            expect(evidence.firstThread.lastChecksum == 0xaaaa, "thread 11 checksum")
            expect(evidence.secondThread.reportCount == 1, "thread 22 reports")
            expect(evidence.secondThread.lastChecksum == 0xbbbb, "thread 22 checksum")
            expect(
                evidence.demonstratesPreemptiveMultithreading,
                "two-thread preemption evidence"
            )
        }
    }

    private static func rejectsAliasedOrMalformedThreadStorage() {
        let context = UnsafeMutableRawPointer.allocate(
            byteCount: AArch64ExceptionFrame.byteCount,
            alignment: 16
        )
        let threads = UnsafeMutableBufferPointer<ScheduledThread>.allocate(
            capacity: 2
        )
        let processors = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 1)
        defer {
            context.deallocate()
            threads.deallocate()
            processors.deallocate()
        }

        let address = UInt64(UInt(bitPattern: context))
        let first = EL0ThreadBootstrap(
            identifier: 1,
            contextAddress: address,
            userStackTop: 0x8000,
            threadPointer: 0x1000
        )
        let aliased = EL0ThreadBootstrap(
            identifier: 2,
            contextAddress: address,
            userStackTop: 0xa000,
            threadPointer: 0x2000
        )
        expect(
            PreemptiveEL0Scheduler(
                threadStorage: threads,
                currentIndexStorage: processors,
                processIdentifier: 1,
                userEntryAddress: 0x4000,
                firstThread: first,
                secondThread: aliased
            ) == nil,
            "aliased context storage was accepted"
        )
    }

    private static func setReport(
        _ frame: UnsafeMutablePointer<AArch64ExceptionFrame>,
        threadIdentifier: UInt64,
        sequence: UInt64,
        checksum: UInt64
    ) {
        frame.pointee.vectorSlot = 8
        frame.pointee.syndrome = 0x15 << 26
        frame.pointee.x8 = PreemptiveEL0Scheduler.reportSystemCallNumber
        frame.pointee.x0 = threadIdentifier
        frame.pointee.x1 = sequence
        frame.pointee.x2 = checksum
    }
}

private func withScheduler(
    body: (
        inout PreemptiveEL0Scheduler,
        UnsafeMutableRawPointer
    ) -> Void
) {
    let firstContext = UnsafeMutableRawPointer.allocate(
        byteCount: AArch64ExceptionFrame.byteCount,
        alignment: 16
    )
    let secondContext = UnsafeMutableRawPointer.allocate(
        byteCount: AArch64ExceptionFrame.byteCount,
        alignment: 16
    )
    let liveFrame = UnsafeMutableRawPointer.allocate(
        byteCount: AArch64ExceptionFrame.byteCount,
        alignment: 16
    )
    let threads = UnsafeMutableBufferPointer<ScheduledThread>.allocate(capacity: 2)
    let processors = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 1)
    defer {
        firstContext.deallocate()
        secondContext.deallocate()
        liveFrame.deallocate()
        threads.deallocate()
        processors.deallocate()
    }

    var scheduler = PreemptiveEL0Scheduler(
        threadStorage: threads,
        currentIndexStorage: processors,
        processIdentifier: 7,
        userEntryAddress: 0x4000,
        firstThread: EL0ThreadBootstrap(
            identifier: 11,
            contextAddress: UInt64(UInt(bitPattern: firstContext)),
            userStackTop: 0x8000,
            threadPointer: 0x1111
        ),
        secondThread: EL0ThreadBootstrap(
            identifier: 22,
            contextAddress: UInt64(UInt(bitPattern: secondContext)),
            userStackTop: 0xa000,
            threadPointer: 0x2222
        )
    )!
    body(&scheduler, liveFrame)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}
