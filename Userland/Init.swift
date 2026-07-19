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

private struct FileSystemRequestWords {
    var header: UInt64
    var operation: UInt64
    var argument0: UInt64
    var argument1: UInt64
    var argument2: UInt64
    var argument3: UInt64
    var argument4: UInt64
    var argument5: UInt64

    init(
        operation: UInt16,
        requestedAccess: UInt16 = 0,
        argument0: UInt64 = 0,
        argument1: UInt64 = 0,
        argument2: UInt64 = 0,
        argument3: UInt64 = 0
    ) {
        header = 0x5153_4653 | UInt64(1) << 32 | UInt64(64) << 48
        self.operation = UInt64(operation) | UInt64(requestedAccess) << 32
        self.argument0 = argument0
        self.argument1 = argument1
        self.argument2 = argument2
        self.argument3 = argument3
        self.argument4 = 0
        self.argument5 = 0
    }
}

private struct FileSystemResultWords {
    var word0: UInt64 = 0
    var word1: UInt64 = 0
    var word2: UInt64 = 0
    var value0: UInt64 = 0
    var value1: UInt64 = 0
    var value2: UInt64 = 0
    var value3: UInt64 = 0
    var value4: UInt64 = 0
    var value5: UInt64 = 0
    var value6: UInt64 = 0
    var value7: UInt64 = 0
    var value8: UInt64 = 0
    var value9: UInt64 = 0
    var value10: UInt64 = 0
    var value11: UInt64 = 0
    var value12: UInt64 = 0

    var isSuccessful: Bool {
        word0 == (0x5253_4653 | UInt64(1) << 32 | UInt64(128) << 48)
            && UInt32(truncatingIfNeeded: word1 >> 32) == 0
    }

    var payload: UInt16 {
        UInt16(truncatingIfNeeded: word1 >> 16)
    }
}

private struct FileReadBuffer {
    var word0: UInt64 = 0
    var word1: UInt64 = 0
    var word2: UInt64 = 0
    var word3: UInt64 = 0
    var word4: UInt64 = 0
    var word5: UInt64 = 0
    var word6: UInt64 = 0
    var word7: UInt64 = 0
    var word8: UInt64 = 0
    var word9: UInt64 = 0
    var word10: UInt64 = 0
    var word11: UInt64 = 0
    var word12: UInt64 = 0
    var word13: UInt64 = 0
    var word14: UInt64 = 0
    var word15: UInt64 = 0
}

@inline(never)
private func submitFileSystemRequest(
    _ request: inout FileSystemRequestWords,
    result: inout FileSystemResultWords
) -> UInt64 {
    withUnsafePointer(to: &request) { requestPointer in
        withUnsafeMutablePointer(to: &result) { resultPointer in
            systemCall(
                32,
                UInt64(UInt(bitPattern: UnsafeRawPointer(requestPointer))),
                64,
                UInt64(UInt(bitPattern: UnsafeMutableRawPointer(resultPointer)))
            )
        }
    }
}

@inline(never)
private func provePersistentFileService() -> Bool {
    let path: StaticString = "/Users/Welcome.txt"
    let seededContents: StaticString =
        "Welcome to SwiftOS. This file survived a real block-device reboot.\n"
    let updatedContents: StaticString =
        "Written to SwiftOS. This file survived a real block-device reboot.\n"
    var handle: UInt64 = 0

    let opened = path.withUTF8Buffer { pathBytes -> Bool in
        var request = FileSystemRequestWords(
            operation: 1,
            requestedAccess: 3,
            argument0: UInt64(
                UInt(bitPattern: UnsafeRawPointer(pathBytes.baseAddress!))
            ),
            argument1: UInt64(pathBytes.count)
        )
        var result = FileSystemResultWords()
        guard submitFileSystemRequest(&request, result: &result) == 0,
              result.isSuccessful,
              result.payload == 1
        else { return false }
        handle = result.value0
        return handle != 0
    }
    guard opened else { return false }

    var readBuffer = FileReadBuffer()
    let read = withUnsafeMutableBytes(of: &readBuffer) { bytes -> Bool in
        var request = FileSystemRequestWords(
            operation: 2,
            argument0: handle,
            argument1: 0,
            argument2: UInt64(UInt(bitPattern: bytes.baseAddress!)),
            argument3: UInt64(bytes.count)
        )
        var result = FileSystemResultWords()
        guard submitFileSystemRequest(&request, result: &result) == 0,
              result.isSuccessful,
              result.payload == 2,
              result.value0 <= UInt64(bytes.count)
        else { return false }
        func matches(_ expected: UnsafeBufferPointer<UInt8>) -> Bool {
            guard result.value0 == UInt64(expected.count) else { return false }
            var index = 0
            while index < expected.count {
                if bytes[index] != expected[index] { return false }
                index += 1
            }
            return true
        }
        return seededContents.withUTF8Buffer { seeded in
            if matches(seeded) { return true }
            return updatedContents.withUTF8Buffer { matches($0) }
        }
    }
    guard read else { return false }

    let wrote = updatedContents.withUTF8Buffer { contents -> Bool in
        var request = FileSystemRequestWords(
            operation: 3,
            argument0: handle,
            argument1: 0,
            argument2: UInt64(
                UInt(bitPattern: UnsafeRawPointer(contents.baseAddress!))
            ),
            argument3: UInt64(contents.count)
        )
        var result = FileSystemResultWords()
        return submitFileSystemRequest(&request, result: &result) == 0
            && result.isSuccessful
            && result.payload == 2
            && result.value0 == UInt64(contents.count)
    }
    guard wrote else { return false }

    var closeRequest = FileSystemRequestWords(
        operation: 6,
        argument0: handle
    )
    var closeResult = FileSystemResultWords()
    return submitFileSystemRequest(
        &closeRequest,
        result: &closeResult
    ) == 0 && closeResult.isSuccessful
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

    if threadID == 1,
       systemCall(2, 0, 0, 0) & 1 != 0 {
        _ = provePersistentFileService()
    }

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
