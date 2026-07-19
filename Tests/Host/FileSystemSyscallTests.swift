@main
struct FileSystemSyscallTests {
    static func main() {
        preservesTheVersionedLittleEndianABI()
        validatesWholeUserRangesBeforeCopying()
        crossesOpenPartialIOStatDirectoryAndClose()
        enforcesHandleRightsAndDeviceCapabilities()
        rejectsInvalidPointersBeforeProviderMutation()
        boundsPerProcessHandlesAndRejectsStaleTokens()
        rejectsMalformedRequestsAndBackendResults()
        classifiesAArch64SVCFramesWithoutHijackingOtherCalls()
        print("filesystem syscall host tests: 8 groups passed")
    }

    private static func preservesTheVersionedLittleEndianABI() {
        var bytes = [UInt8](
            repeating: 0xa5,
            count: FileSystemSyscallABI.requestByteCount
        )
        let request = makeRequest(
            .write,
            access: 0x1234,
            arguments: (
                0x0102_0304_0506_0708,
                0x1112_1314_1516_1718,
                0x2122_2324_2526_2728,
                0x3132_3334_3536_3738,
                0x4142_4344_4546_4748,
                0x5152_5354_5556_5758
            )
        )
        bytes.withUnsafeMutableBytes { output in
            expect(
                FileSystemSyscallCodec.encodeRequest(request, into: output),
                "request encode failed"
            )
        }
        expect(Array(bytes[0..<4]) == Array("SFSQ".utf8), "request magic")
        expect(bytes[4] == 1 && bytes[5] == 0, "request version endian")
        expect(bytes[6] == 64 && bytes[7] == 0, "request size endian")
        expect(bytes[8] == 3 && bytes[9] == 0, "operation number")
        expect(bytes[16] == 0x08 && bytes[23] == 0x01, "argument endian")
        bytes.withUnsafeBytes { input in
            guard case .request(let decoded) =
                    FileSystemSyscallCodec.decodeRequest(input)
            else { fail("request decode failed") }
            expect(decoded == request, "request round trip")
        }

        var result = FileSystemResult()
        result.operationRaw = FileSystemOperation.stat.rawValue
        result.payload = .metadata
        result.status = .accessDenied
        result.detail = 0x1122_3344
        result.value0 = 0x0102_0304_0506_0708
        var resultBytes = [UInt8](
            repeating: 0xa5,
            count: FileSystemSyscallABI.resultByteCount
        )
        resultBytes.withUnsafeMutableBytes { output in
            expect(
                FileSystemSyscallCodec.encodeResult(result, into: output),
                "result encode failed"
            )
        }
        expect(Array(resultBytes[0..<4]) == Array("SFSR".utf8), "result magic")
        expect(resultBytes[6] == 128 && resultBytes[7] == 0, "result size")
        expect(resultBytes[20] == 0 && resultBytes[23] == 0, "reserved bytes")
        resultBytes.withUnsafeBytes { input in
            expect(
                FileSystemSyscallCodec.readEncodedResultStatus(input)
                    == .accessDenied,
                "result status"
            )
            expect(
                FileSystemSyscallCodec.readEncodedResultPayload(input)
                    == .metadata,
                "result payload"
            )
            expect(
                FileSystemSyscallCodec.readEncodedResultValue(input, at: 0)
                    == 0x0102_0304_0506_0708,
                "result value"
            )
        }
    }

    private static func validatesWholeUserRangesBeforeCopying() {
        let firstBacking = UnsafeMutableRawPointer.allocate(
            byteCount: 16,
            alignment: 8
        )
        let secondBacking = UnsafeMutableRawPointer.allocate(
            byteCount: 16,
            alignment: 8
        )
        let regions = UnsafeMutableBufferPointer<EL0UserMemoryRegion>.allocate(
            capacity: 2
        )
        defer {
            firstBacking.deallocate()
            secondBacking.deallocate()
            regions.deallocate()
        }
        fill(firstBacking, count: 16, value: 0x11)
        fill(secondBacking, count: 16, value: 0x22)
        regions[0] = EL0UserMemoryRegion(
            virtualBaseAddress: 0x1_0000,
            byteCount: 16,
            permissions: .readWrite,
            kernelMappedBaseAddress: firstBacking
        )!
        regions[1] = EL0UserMemoryRegion(
            virtualBaseAddress: 0x1_0010,
            byteCount: 16,
            permissions: .readWrite,
            kernelMappedBaseAddress: secondBacking
        )!
        let map = EL0UserMemoryMap(
            regions: UnsafeBufferPointer(regions)
        )!
        expect(
            map.validate(
                virtualAddress: 0x1_0008,
                byteCount: 20,
                access: .read
            ),
            "contiguous multi-region range rejected"
        )
        var copied = [UInt8](repeating: 0, count: 20)
        copied.withUnsafeMutableBytes { output in
            expect(map.copyIn(from: 0x1_0008, into: output), "cross-region copy")
        }
        expect(copied[0] == 0x11 && copied[8] == 0x22, "cross-region bytes")
        expect(
            !map.validate(
                virtualAddress: UInt64.max - 3,
                byteCount: 8,
                access: .read
            ),
            "overflowing range accepted"
        )
        expect(
            !map.validate(
                virtualAddress: 0x1_0018,
                byteCount: 16,
                access: .read
            ),
            "range beyond final mapping accepted"
        )

        let readOnlyRegion = UnsafeMutableBufferPointer<EL0UserMemoryRegion>
            .allocate(capacity: 1)
        defer { readOnlyRegion.deallocate() }
        readOnlyRegion[0] = EL0UserMemoryRegion(
            virtualBaseAddress: 0x2_0000,
            byteCount: 16,
            permissions: .read,
            kernelMappedBaseAddress: firstBacking
        )!
        let readOnlyMap = EL0UserMemoryMap(
            regions: UnsafeBufferPointer(readOnlyRegion)
        )!
        let source = [UInt8](repeating: 0xee, count: 8)
        source.withUnsafeBytes { input in
            expect(
                !readOnlyMap.copyOut(input, to: 0x2_0000),
                "write through read-only user mapping"
            )
        }
        expect(loadByte(firstBacking, at: 0) == 0x11, "failed copy mutated memory")

        let overlapping = UnsafeMutableBufferPointer<EL0UserMemoryRegion>
            .allocate(capacity: 2)
        defer { overlapping.deallocate() }
        overlapping[0] = regions[0]
        overlapping[1] = EL0UserMemoryRegion(
            virtualBaseAddress: 0x1_0008,
            byteCount: 8,
            permissions: .read,
            kernelMappedBaseAddress: secondBacking
        )!
        expect(
            EL0UserMemoryMap(regions: UnsafeBufferPointer(overlapping)) == nil,
            "overlapping user regions accepted"
        )
    }

    private static func crossesOpenPartialIOStatDirectoryAndClose() {
        withHarness { service, memory, userBacking in
            let fileRights = VFSAccessRights.readData
                .union(.writeData).union(.readMetadata)
            let fileHandle = open(
                path: "/Users/alice/file.txt",
                access: fileRights,
                service: &service,
                memory: memory,
                userBacking: userBacking
            )
            expect(service.openHandleCount == 1, "file handle count")

            fill(userBacking.advanced(by: dataOffset), count: 8, value: 0xcc)
            let readRequest = makeRequest(
                .read,
                arguments: (fileHandle, 7, dataAddress, 8, 0, 0)
            )
            expect(
                perform(
                    readRequest,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .success,
                "partial read failed"
            )
            expect(resultValue(userBacking, 0) == 3, "partial read count")
            expect(
                bytes(userBacking.advanced(by: dataOffset), count: 4)
                    == [0x61, 0x62, 0x63, 0xcc],
                "partial read copied wrong span"
            )

            store([9, 8, 7, 6], at: userBacking.advanced(by: dataOffset))
            let writeRequest = makeRequest(
                .write,
                arguments: (fileHandle, 11, dataAddress, 4, 0, 0)
            )
            expect(
                perform(
                    writeRequest,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .success,
                "partial write failed"
            )
            expect(resultValue(userBacking, 0) == 3, "partial write count")
            expect(service.backend.writtenBytes == [9, 8, 7, 6], "write input")
            expect(service.backend.lastWriteOffset == 11, "write offset")

            expect(
                perform(
                    makeRequest(.stat, arguments: (fileHandle, 0, 0, 0, 0, 0)),
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .success,
                "stat failed"
            )
            expect(resultPayload(userBacking) == .metadata, "stat payload")
            expect(resultValue(userBacking, 0) == 1, "stat volume")
            expect(resultValue(userBacking, 1) == 10, "stat node")
            expect(resultValue(userBacking, 3) == 123, "stat size")

            let directoryHandle = open(
                path: "/Users/alice",
                access: .enumerate.union(.readMetadata),
                service: &service,
                memory: memory,
                userBacking: userBacking
            )
            let firstEntry = makeRequest(
                .readDirectory,
                arguments: (directoryHandle, 0, nameAddress, 32, 0, 0)
            )
            expect(
                perform(
                    firstEntry,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .success,
                "readdir entry failed"
            )
            expect(resultPayload(userBacking) == .directoryEntry, "entry payload")
            expect(resultValue(userBacking, 0) == 1, "next cookie")
            expect(resultValue(userBacking, 1) == 8, "name length")
            expect(
                bytes(userBacking.advanced(by: nameOffset), count: 8)
                    == Array("file.txt".utf8),
                "directory name"
            )
            expect(
                perform(
                    makeRequest(
                        .readDirectory,
                        arguments: (directoryHandle, 1, nameAddress, 32, 0, 0)
                    ),
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .success,
                "readdir end failed"
            )
            expect(resultPayload(userBacking) == .directoryEnd, "end payload")

            expect(
                perform(
                    makeRequest(.close, arguments: (fileHandle, 0, 0, 0, 0, 0)),
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .success,
                "close failed"
            )
            expect(
                perform(
                    readRequest,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .staleHandle,
                "closed token was not stale"
            )
        }
    }

    private static func enforcesHandleRightsAndDeviceCapabilities() {
        withHarness { service, memory, userBacking in
            let readHandle = open(
                path: "/Users/alice/file.txt",
                access: .readData,
                service: &service,
                memory: memory,
                userBacking: userBacking
            )
            store([1], at: userBacking.advanced(by: dataOffset))
            let writesBefore = service.backend.writeCallCount
            expect(
                perform(
                    makeRequest(
                        .write,
                        arguments: (readHandle, 0, dataAddress, 1, 0, 0)
                    ),
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .accessDenied,
                "read-only handle wrote data"
            )
            expect(
                service.backend.writeCallCount == writesBefore,
                "denied write reached provider"
            )

            expect(
                performOpen(
                    path: "/Devices/Keyboard",
                    access: .readData,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .accessDenied,
                "device opened without capability"
            )
            expect(
                resultDetail(userBacking)
                    == FileSystemStatusDetail.missingDeviceCapability.rawValue,
                "device denial detail"
            )
            expect(
                performOpen(
                    path: "/Users/alice/file.txt",
                    access: .execute,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .accessDenied,
                "node access ceiling bypassed"
            )
        }

        withHarness(
            capability: VFSCapabilityIdentifier(rawValue: 99)
        ) { service, memory, userBacking in
            expect(
                performOpen(
                    path: "/Devices/Keyboard",
                    access: .readData,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .success,
                "matching device capability denied"
            )

            fill(
                userBacking.advanced(by: resultOffset),
                count: FileSystemSyscallABI.resultByteCount,
                value: 0x5a
            )
            let request = makeRequest(
                .open,
                access: VFSAccessRights.readData.rawValue,
                arguments: (pathAddress, 1, 0, 0, 0, 0)
            )
            install(request, in: userBacking)
            let status = dispatchFrame(
                currentTaskIdentifier: 999,
                service: &service,
                memory: memory
            )
            expect(status == .wrongProcess, "wrong process accepted")
            expect(
                loadByte(userBacking, at: resultOffset) == 0x5a,
                "wrong process received result bytes"
            )
        }
    }

    private static func rejectsInvalidPointersBeforeProviderMutation() {
        withHarness { service, memory, userBacking in
            copyASCII("/Users/alice/file.txt", to: userBacking, offset: pathOffset)
            let openRequest = makeRequest(
                .open,
                access: VFSAccessRights.readData.rawValue,
                arguments: (pathAddress, 21, 0, 0, 0, 0)
            )
            install(openRequest, in: userBacking)
            let resolvesBefore = service.backend.resolveCallCount
            expect(
                dispatchFrame(
                    resultAddress: userBase + UInt64(userByteCount - 64),
                    service: &service,
                    memory: memory
                ) == .invalidUserMemory,
                "short result range accepted"
            )
            expect(
                service.backend.resolveCallCount == resolvesBefore,
                "invalid result pointer mutated provider"
            )

            let invalidRequestAddress = userBase + UInt64(userByteCount - 32)
            expect(
                dispatchFrame(
                    requestAddress: invalidRequestAddress,
                    service: &service,
                    memory: memory
                ) == .invalidUserMemory,
                "short request range accepted"
            )
            expect(resultStatus(userBacking) == .invalidUserMemory, "fault result")

            let handle = open(
                path: "/Users/alice/file.txt",
                access: .readData,
                service: &service,
                memory: memory,
                userBacking: userBacking
            )
            let readsBefore = service.backend.readCallCount
            expect(
                perform(
                    makeRequest(
                        .read,
                        arguments: (
                            handle,
                            0,
                            userBase + UInt64(userByteCount - 2),
                            8,
                            0,
                            0
                        )
                    ),
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .invalidUserMemory,
                "short data range accepted"
            )
            expect(
                service.backend.readCallCount == readsBefore,
                "invalid data pointer reached provider"
            )
        }
    }

    private static func boundsPerProcessHandlesAndRejectsStaleTokens() {
        withHarness(handleSlotCount: 1) { service, memory, userBacking in
            let first = open(
                path: "/Users/alice/file.txt",
                access: .readData,
                service: &service,
                memory: memory,
                userBacking: userBacking
            )
            expect(
                performOpen(
                    path: "/Users/alice/file.txt",
                    access: .readData,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .handleTableFull,
                "fixed handle capacity exceeded"
            )
            expect(
                perform(
                    makeRequest(.close, arguments: (first, 0, 0, 0, 0, 0)),
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .success,
                "capacity test close"
            )
            let second = open(
                path: "/Users/alice/file.txt",
                access: .readData,
                service: &service,
                memory: memory,
                userBacking: userBacking
            )
            expect(first != second, "generation did not advance")
            expect(
                perform(
                    makeRequest(.close, arguments: (first, 0, 0, 0, 0, 0)),
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .staleHandle,
                "old handle revived"
            )
            expect(service.openHandleCount == 1, "stale close retired new handle")
        }
    }

    private static func rejectsMalformedRequestsAndBackendResults() {
        withHarness(malformedRead: true) { service, memory, userBacking in
            copyASCII("/Users/../System", to: userBacking, offset: pathOffset)
            expect(
                perform(
                    makeRequest(
                        .open,
                        access: VFSAccessRights.readData.rawValue,
                        arguments: (pathAddress, 16, 0, 0, 0, 0)
                    ),
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .invalidPath,
                "traversal path accepted"
            )
            expect(service.backend.resolveCallCount == 0, "bad path reached backend")

            var unknown = makeRequest(.stat)
            unknown = FileSystemRequest(
                operationRaw: 999,
                flags: 0,
                requestedAccessRaw: 0,
                reserved: 0,
                argument0: unknown.argument0,
                argument1: 0,
                argument2: 0,
                argument3: 0,
                argument4: 0,
                argument5: 0
            )
            expect(
                perform(
                    unknown,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .unsupportedOperation,
                "unknown operation accepted"
            )

            let malformedReserved = FileSystemRequest(
                operationRaw: FileSystemOperation.stat.rawValue,
                flags: 1,
                requestedAccessRaw: 0,
                reserved: 0,
                argument0: 0,
                argument1: 0,
                argument2: 0,
                argument3: 0,
                argument4: 0,
                argument5: 0
            )
            expect(
                perform(
                    malformedReserved,
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .invalidRequest,
                "request flags accepted"
            )

            let handle = open(
                path: "/Users/alice/file.txt",
                access: .readData,
                service: &service,
                memory: memory,
                userBacking: userBacking
            )
            expect(
                perform(
                    makeRequest(
                        .read,
                        arguments: (handle, 0, dataAddress, 4, 0, 0)
                    ),
                    service: &service,
                    memory: memory,
                    userBacking: userBacking
                ) == .malformedBackendResult,
                "oversized provider transfer accepted"
            )
        }
    }

    private static func classifiesAArch64SVCFramesWithoutHijackingOtherCalls() {
        withHarness { service, memory, _ in
            withZeroedFrame { frame in
                frame.pointee.vectorSlot = 4
                expect(
                    EL0FileSystemExceptionDispatcher.dispatch(
                        frame: frame,
                        currentTaskIdentifier: taskIdentifier,
                        service: &service,
                        userMemory: memory
                    ) == .notFromEL0,
                    "EL1 exception claimed"
                )

                frame.pointee.vectorSlot = 8
                frame.pointee.syndrome = 0x24 << 26
                expect(
                    EL0FileSystemExceptionDispatcher.dispatch(
                        frame: frame,
                        currentTaskIdentifier: taskIdentifier,
                        service: &service,
                        userMemory: memory
                    ) == .notSupervisorCall,
                    "non-SVC exception claimed"
                )

                frame.pointee.syndrome = 0x15 << 26
                frame.pointee.x8 = 1
                frame.pointee.x0 = 0xfeed_face
                expect(
                    EL0FileSystemExceptionDispatcher.dispatch(
                        frame: frame,
                        currentTaskIdentifier: taskIdentifier,
                        service: &service,
                        userMemory: memory
                    ) == .unsupportedSystemCall,
                    "report syscall hijacked"
                )
                expect(frame.pointee.x0 == 0xfeed_face, "unclaimed frame mutated")
            }
        }
    }
}

private struct FakeFileServiceBackend: VFSFileServiceBackend {
    private let userVolume = VFSVolumeIdentifier(rawValue: 1)!
    private let deviceVolume = VFSVolumeIdentifier(rawValue: 2)!
    let malformedRead: Bool
    private(set) var resolveCallCount = 0
    private(set) var readCallCount = 0
    private(set) var writeCallCount = 0
    private(set) var writtenBytes: [UInt8] = []
    private(set) var lastWriteOffset: UInt64 = 0

    init(malformedRead: Bool = false) {
        self.malformedRead = malformedRead
    }

    mutating func resolve(
        path: VFSCanonicalPath
    ) -> FileServicePathResolutionResult {
        resolveCallCount += 1
        if pathEquals(path, "/Users/alice/file.txt") {
            return .node(mount: userMount, metadata: fileMetadata)
        }
        if pathEquals(path, "/Users/alice") {
            return .node(mount: userMount, metadata: directoryMetadata)
        }
        if pathEquals(path, "/Devices/Keyboard") {
            return .node(mount: deviceMount, metadata: deviceMetadata)
        }
        return .failure(.notFound)
    }

    mutating func metadata(
        for handle: VFSOpenHandle
    ) -> VFSMetadataResult {
        if handle.node == fileMetadata.identifier { return .metadata(fileMetadata) }
        if handle.node == directoryMetadata.identifier {
            return .metadata(directoryMetadata)
        }
        if handle.node == deviceMetadata.identifier { return .metadata(deviceMetadata) }
        return .failure(.notFound)
    }

    mutating func read(
        from handle: VFSOpenHandle,
        at offset: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> VFSDataIOResult {
        readCallCount += 1
        guard handle.node == fileMetadata.identifier else {
            return .failure(.isDirectory)
        }
        if malformedRead { return .transferred(byteCount: output.count + 1) }
        let payload: [UInt8] = [0x61, 0x62, 0x63]
        let count = min(payload.count, output.count)
        var index = 0
        while index < count {
            output[index] = payload[index]
            index += 1
        }
        return .transferred(byteCount: count)
    }

    mutating func write(
        to handle: VFSOpenHandle,
        at offset: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> VFSDataIOResult {
        writeCallCount += 1
        guard handle.node == fileMetadata.identifier else {
            return .failure(.isDirectory)
        }
        writtenBytes = Array(input)
        lastWriteOffset = offset
        return .transferred(byteCount: max(0, input.count - 1))
    }

    mutating func readDirectory(
        from handle: VFSOpenHandle,
        after cookie: VFSDirectoryCookie,
        nameOutput: UnsafeMutableRawBufferPointer
    ) -> VFSDirectoryReadResult {
        guard handle.node == directoryMetadata.identifier else {
            return .failure(.notDirectory)
        }
        if cookie.rawValue == 1 { return .end }
        if cookie.rawValue != 0 { return .staleCookie }
        let name = Array("file.txt".utf8)
        guard nameOutput.count >= name.count else {
            return .nameBufferTooSmall(requiredByteCount: name.count)
        }
        var index = 0
        while index < name.count {
            nameOutput[index] = name[index]
            index += 1
        }
        let bytes = UnsafeRawBufferPointer(start: nameOutput.baseAddress, count: name.count)
        guard case .name(let view) = VFSNameValidator.validate(bytes) else {
            return .failure(.corrupt)
        }
        return .entry(
            VFSDirectoryEntry(
                identifier: fileMetadata.identifier,
                kind: .regularFile,
                name: view
            ),
            nextCookie: VFSDirectoryCookie(rawValue: 1)
        )
    }

    private var userMount: VFSMountDescriptor {
        VFSMountDescriptor(
            mountIdentifier: VFSMountIdentifier(rawValue: 1)!,
            volume: VFSVolumeDescriptor(
                identifier: userVolume,
                role: .user,
                visibility: .namespace
            ),
            userAccess: .all,
            requiredCapability: nil
        )
    }

    private var deviceMount: VFSMountDescriptor {
        VFSMountDescriptor(
            mountIdentifier: VFSMountIdentifier(rawValue: 2)!,
            volume: VFSVolumeDescriptor(
                identifier: deviceVolume,
                role: .device,
                visibility: .namespace
            ),
            userAccess: .readData.union(.writeData).union(.readMetadata),
            requiredCapability: VFSCapabilityIdentifier(rawValue: 99)
        )
    }

    private var fileMetadata: VFSNodeMetadata {
        makeMetadata(
            volume: userVolume,
            local: 10,
            kind: .regularFile,
            byteCount: 123,
            access: .readData.union(.writeData).union(.readMetadata)
        )
    }

    private var directoryMetadata: VFSNodeMetadata {
        makeMetadata(
            volume: userVolume,
            local: 20,
            kind: .directory,
            byteCount: 1,
            access: .enumerate.union(.traverse).union(.readMetadata)
        )
    }

    private var deviceMetadata: VFSNodeMetadata {
        makeMetadata(
            volume: deviceVolume,
            local: 30,
            kind: .device,
            byteCount: 0,
            access: .readData.union(.writeData).union(.readMetadata)
        )
    }
}

private let userBase: UInt64 = 0x10_0000
private let userByteCount = 8_192
private let requestOffset = 0
private let resultOffset = 256
private let pathOffset = 512
private let dataOffset = 2_048
private let nameOffset = 4_096
private let requestAddress = userBase + UInt64(requestOffset)
private let resultAddress = userBase + UInt64(resultOffset)
private let pathAddress = userBase + UInt64(pathOffset)
private let dataAddress = userBase + UInt64(dataOffset)
private let nameAddress = userBase + UInt64(nameOffset)
private let taskIdentifier: UInt64 = 7

private func withHarness(
    capability: VFSCapabilityIdentifier? = nil,
    handleSlotCount: Int = 8,
    malformedRead: Bool = false,
    _ body: (
        inout EL0ProcessFileService<FakeFileServiceBackend>,
        EL0UserMemoryMap,
        UnsafeMutableRawPointer
    ) -> Void
) {
    let requestScratch = allocate(FileSystemSyscallABI.requestByteCount)
    let resultScratch = allocate(FileSystemSyscallABI.resultByteCount)
    let pathInputScratch = allocate(VFSPathLimits.maximumPathByteCount)
    let canonicalPathScratch = allocate(VFSPathLimits.maximumPathByteCount)
    let transferScratch = allocate(128)
    let nameScratch = allocate(VFSPathLimits.maximumComponentByteCount)
    let userBacking = allocate(userByteCount)
    let handles = UnsafeMutablePointer<VFSHandleSlot>.allocate(
        capacity: handleSlotCount
    )
    let regions = UnsafeMutableBufferPointer<EL0UserMemoryRegion>.allocate(
        capacity: 1
    )
    defer {
        requestScratch.deallocate()
        resultScratch.deallocate()
        pathInputScratch.deallocate()
        canonicalPathScratch.deallocate()
        transferScratch.deallocate()
        nameScratch.deallocate()
        userBacking.deallocate()
        handles.deallocate()
        regions.deallocate()
    }
    fill(userBacking, count: userByteCount, value: 0)

    let workspace = FileServiceWorkspace(
        request: UnsafeMutableRawBufferPointer(
            start: requestScratch,
            count: FileSystemSyscallABI.requestByteCount
        ),
        result: UnsafeMutableRawBufferPointer(
            start: resultScratch,
            count: FileSystemSyscallABI.resultByteCount
        ),
        pathInput: UnsafeMutableRawBufferPointer(
            start: pathInputScratch,
            count: VFSPathLimits.maximumPathByteCount
        ),
        canonicalPath: UnsafeMutableRawBufferPointer(
            start: canonicalPathScratch,
            count: VFSPathLimits.maximumPathByteCount
        ),
        transfer: UnsafeMutableRawBufferPointer(
            start: transferScratch,
            count: 128
        ),
        directoryName: UnsafeMutableRawBufferPointer(
            start: nameScratch,
            count: VFSPathLimits.maximumComponentByteCount
        )
    )!
    regions[0] = EL0UserMemoryRegion(
        virtualBaseAddress: userBase,
        byteCount: UInt64(userByteCount),
        permissions: .readWrite,
        kernelMappedBaseAddress: userBacking
    )!
    let memory = EL0UserMemoryMap(regions: UnsafeBufferPointer(regions))!
    var service = EL0ProcessFileService(
        taskIdentifier: taskIdentifier,
        deviceCapability: capability,
        backend: FakeFileServiceBackend(malformedRead: malformedRead),
        uninitializedHandleSlots: handles,
        handleSlotCount: handleSlotCount,
        workspace: workspace
    )!
    body(&service, memory, userBacking)
}

private func open(
    path: StaticString,
    access: VFSAccessRights,
    service: inout EL0ProcessFileService<FakeFileServiceBackend>,
    memory: EL0UserMemoryMap,
    userBacking: UnsafeMutableRawPointer
) -> UInt64 {
    expect(
        performOpen(
            path: path,
            access: access,
            service: &service,
            memory: memory,
            userBacking: userBacking
        ) == .success,
        "open failed"
    )
    expect(resultPayload(userBacking) == .handle, "open payload")
    return resultValue(userBacking, 0)
}

private func performOpen(
    path: StaticString,
    access: VFSAccessRights,
    service: inout EL0ProcessFileService<FakeFileServiceBackend>,
    memory: EL0UserMemoryMap,
    userBacking: UnsafeMutableRawPointer
) -> FileSystemStatus {
    copyASCII(path, to: userBacking, offset: pathOffset)
    return perform(
        makeRequest(
            .open,
            access: access.rawValue,
            arguments: (
                pathAddress,
                UInt64(path.utf8CodeUnitCount),
                0,
                0,
                0,
                0
            )
        ),
        service: &service,
        memory: memory,
        userBacking: userBacking
    )
}

private func perform(
    _ request: FileSystemRequest,
    service: inout EL0ProcessFileService<FakeFileServiceBackend>,
    memory: EL0UserMemoryMap,
    userBacking: UnsafeMutableRawPointer
) -> FileSystemStatus {
    install(request, in: userBacking)
    fill(
        userBacking.advanced(by: resultOffset),
        count: FileSystemSyscallABI.resultByteCount,
        value: 0xcc
    )
    let status = dispatchFrame(service: &service, memory: memory)
    expect(resultStatus(userBacking) == status, "register/result disagreement")
    return status
}

private func dispatchFrame(
    requestAddress suppliedRequestAddress: UInt64 = requestAddress,
    requestByteCount: UInt64 = UInt64(FileSystemSyscallABI.requestByteCount),
    resultAddress suppliedResultAddress: UInt64 = resultAddress,
    currentTaskIdentifier: UInt64 = taskIdentifier,
    service: inout EL0ProcessFileService<FakeFileServiceBackend>,
    memory: EL0UserMemoryMap
) -> FileSystemStatus {
    var returnedStatus: FileSystemStatus?
    withZeroedFrame { frame in
        frame.pointee.vectorSlot = 8
        frame.pointee.syndrome = 0x15 << 26
        frame.pointee.x8 = FileSystemSyscallABI.systemCallNumber
        frame.pointee.x0 = suppliedRequestAddress
        frame.pointee.x1 = requestByteCount
        frame.pointee.x2 = suppliedResultAddress
        let disposition = EL0FileSystemExceptionDispatcher.dispatch(
            frame: frame,
            currentTaskIdentifier: currentTaskIdentifier,
            service: &service,
            userMemory: memory
        )
        guard case .handled(let status) = disposition else {
            fail("filesystem SVC was not handled")
        }
        expect(frame.pointee.x0 == status.registerValue, "x0 status encoding")
        returnedStatus = status
    }
    return returnedStatus!
}

private func makeRequest(
    _ operation: FileSystemOperation,
    access: UInt16 = 0,
    arguments: (
        UInt64,
        UInt64,
        UInt64,
        UInt64,
        UInt64,
        UInt64
    ) = (0, 0, 0, 0, 0, 0)
) -> FileSystemRequest {
    FileSystemRequest(
        operationRaw: operation.rawValue,
        flags: 0,
        requestedAccessRaw: access,
        reserved: 0,
        argument0: arguments.0,
        argument1: arguments.1,
        argument2: arguments.2,
        argument3: arguments.3,
        argument4: arguments.4,
        argument5: arguments.5
    )
}

private func install(
    _ request: FileSystemRequest,
    in userBacking: UnsafeMutableRawPointer
) {
    let output = UnsafeMutableRawBufferPointer(
        start: userBacking.advanced(by: requestOffset),
        count: FileSystemSyscallABI.requestByteCount
    )
    expect(
        FileSystemSyscallCodec.encodeRequest(request, into: output),
        "request install"
    )
}

private func resultStatus(
    _ userBacking: UnsafeMutableRawPointer
) -> FileSystemStatus? {
    FileSystemSyscallCodec.readEncodedResultStatus(
        UnsafeRawBufferPointer(
            start: userBacking.advanced(by: resultOffset),
            count: FileSystemSyscallABI.resultByteCount
        )
    )
}

private func resultPayload(
    _ userBacking: UnsafeMutableRawPointer
) -> FileSystemResultPayload? {
    FileSystemSyscallCodec.readEncodedResultPayload(
        UnsafeRawBufferPointer(
            start: userBacking.advanced(by: resultOffset),
            count: FileSystemSyscallABI.resultByteCount
        )
    )
}

private func resultDetail(_ userBacking: UnsafeMutableRawPointer) -> UInt32 {
    FileSystemSyscallCodec.readEncodedResultDetail(
        UnsafeRawBufferPointer(
            start: userBacking.advanced(by: resultOffset),
            count: FileSystemSyscallABI.resultByteCount
        )
    )!
}

private func resultValue(
    _ userBacking: UnsafeMutableRawPointer,
    _ index: Int
) -> UInt64 {
    FileSystemSyscallCodec.readEncodedResultValue(
        UnsafeRawBufferPointer(
            start: userBacking.advanced(by: resultOffset),
            count: FileSystemSyscallABI.resultByteCount
        ),
        at: index
    )!
}

private func makeMetadata(
    volume: VFSVolumeIdentifier,
    local: UInt64,
    kind: VFSNodeKind,
    byteCount: UInt64,
    access: VFSAccessRights
) -> VFSNodeMetadata {
    let timestamp = VFSTimestamp(
        secondsSinceUnixEpoch: 1_700_000_000,
        nanoseconds: 123
    )!
    return VFSNodeMetadata(
        identifier: VFSNodeIdentifier(volume: volume, localValue: local)!,
        kind: kind,
        byteCount: byteCount,
        linkCount: 1,
        generation: 9,
        createdAt: timestamp,
        modifiedAt: timestamp,
        availableAccess: access
    )!
}

private func pathEquals(
    _ path: VFSCanonicalPath,
    _ expected: StaticString
) -> Bool {
    expected.withUTF8Buffer { bytes in
        guard path.byteCount == bytes.count else { return false }
        var index = 0
        while index < bytes.count {
            if path.byte(at: index) != bytes[index] { return false }
            index += 1
        }
        return true
    }
}

private func withZeroedFrame(
    _ body: (UnsafeMutablePointer<AArch64ExceptionFrame>) -> Void
) {
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: AArch64ExceptionFrame.byteCount,
        alignment: 16
    )
    defer { raw.deallocate() }
    fill(raw, count: AArch64ExceptionFrame.byteCount, value: 0)
    body(raw.assumingMemoryBound(to: AArch64ExceptionFrame.self))
}

private func allocate(_ byteCount: Int) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
}

private func fill(
    _ pointer: UnsafeMutableRawPointer,
    count: Int,
    value: UInt8
) {
    var index = 0
    while index < count {
        pointer.storeBytes(of: value, toByteOffset: index, as: UInt8.self)
        index += 1
    }
}

private func store(_ values: [UInt8], at pointer: UnsafeMutableRawPointer) {
    var index = 0
    while index < values.count {
        pointer.storeBytes(of: values[index], toByteOffset: index, as: UInt8.self)
        index += 1
    }
}

private func bytes(
    _ pointer: UnsafeRawPointer,
    count: Int
) -> [UInt8] {
    var result: [UInt8] = []
    var index = 0
    while index < count {
        result.append(pointer.load(fromByteOffset: index, as: UInt8.self))
        index += 1
    }
    return result
}

private func copyASCII(
    _ value: StaticString,
    to pointer: UnsafeMutableRawPointer,
    offset: Int
) {
    value.withUTF8Buffer { source in
        var index = 0
        while index < source.count {
            pointer.storeBytes(
                of: source[index],
                toByteOffset: offset + index,
                as: UInt8.self
            )
            index += 1
        }
    }
}

private func loadByte(
    _ pointer: UnsafeRawPointer,
    at offset: Int
) -> UInt8 {
    pointer.load(fromByteOffset: offset, as: UInt8.self)
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() { fatalError(message) }
}

private func fail(_ message: String) -> Never {
    fatalError(message)
}
