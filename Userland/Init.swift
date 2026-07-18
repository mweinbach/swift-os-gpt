// The first userspace workload. This file is compiled as its own freestanding
// Embedded Swift object and is never part of the SwiftOSKernel module.

@_silgen_name("swiftos_user_svc")
private func systemCall(
    _ number: UInt64,
    _ argument0: UInt64,
    _ argument1: UInt64,
    _ argument2: UInt64
) -> UInt64

private struct InitThreadState {
    var iterations: UInt64
    var reports: UInt64
    var checksum: UInt64

    init(threadID: UInt64) {
        iterations = 0
        reports = 0
        checksum = threadID ^ 0x5357_4946_544F_5300
    }
}

// Keeping the mutation behind an inout boundary makes the automatic state an
// explicit per-invocation object. Two kernel threads may therefore enter the
// same code with distinct stacks without sharing mutable userspace storage.
@inline(never)
private func advance(_ state: inout InitThreadState, threadID: UInt64) -> Bool {
    state.iterations &+= 1
    state.checksum = (state.checksum &* 6_364_136_223_846_793_005)
        &+ state.iterations
        &+ (threadID &* 1_442_695_040_888_963_407)

    // Report every 262,144 iterations. The workload deliberately remains CPU
    // bound between reports so timer preemption is observable.
    if state.iterations & 0x3_FFFF == 0 {
        state.reports &+= 1
        return true
    }
    return false
}

// C ABI contract: x0 is the kernel-assigned thread identifier. This function
// intentionally never returns, although Void keeps the exported ABI ordinary.
@_cdecl("swiftos_user_init")
func swiftOSUserInit(_ threadID: UInt64) {
    var localState = InitThreadState(threadID: threadID)

    while true {
        if advance(&localState, threadID: threadID) {
            _ = systemCall(
                1,
                threadID,
                localState.reports,
                localState.checksum
            )
        }
    }
}
