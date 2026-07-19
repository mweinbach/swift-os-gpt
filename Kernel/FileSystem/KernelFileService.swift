enum FileServiceLimits {
    static let maximumTransferByteCount = 64 * 1_024
    static let maximumDirectoryNameByteCount =
        VFSPathLimits.maximumComponentByteCount
}

enum FileServicePathResolutionResult {
    case node(mount: VFSMountDescriptor, metadata: VFSNodeMetadata)
    case syntheticDirectory
    case notMounted
    case failure(VFSProviderFailure)
}

/// Trusted kernel adapter between a mount/provider registry and one process's
/// syscall service. A concrete filesystem is not required by this boundary.
/// Path resolution must stay within the checked VFS namespace and must not
/// follow symbolic links; final mount/node/principal policy is rechecked here.
protocol VFSFileServiceBackend {
    mutating func resolve(
        path: VFSCanonicalPath
    ) -> FileServicePathResolutionResult

    mutating func metadata(
        for handle: VFSOpenHandle
    ) -> VFSMetadataResult

    mutating func read(
        from handle: VFSOpenHandle,
        at offset: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> VFSDataIOResult

    mutating func write(
        to handle: VFSOpenHandle,
        at offset: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> VFSDataIOResult

    mutating func readDirectory(
        from handle: VFSOpenHandle,
        after cookie: VFSDirectoryCookie,
        nameOutput: UnsafeMutableRawBufferPointer
    ) -> VFSDirectoryReadResult
}

/// Caller-owned, pairwise-disjoint kernel buffers. No syscall path allocates,
/// borrows user memory across a provider call, or lets a provider write into a
/// user mapping directly.
struct FileServiceWorkspace {
    fileprivate let request: UnsafeMutableRawBufferPointer
    fileprivate let result: UnsafeMutableRawBufferPointer
    fileprivate let pathInput: UnsafeMutableRawBufferPointer
    fileprivate let canonicalPath: UnsafeMutableRawBufferPointer
    fileprivate let transfer: UnsafeMutableRawBufferPointer
    fileprivate let directoryName: UnsafeMutableRawBufferPointer

    init?(
        request: UnsafeMutableRawBufferPointer,
        result: UnsafeMutableRawBufferPointer,
        pathInput: UnsafeMutableRawBufferPointer,
        canonicalPath: UnsafeMutableRawBufferPointer,
        transfer: UnsafeMutableRawBufferPointer,
        directoryName: UnsafeMutableRawBufferPointer
    ) {
        guard request.count >= FileSystemSyscallABI.requestByteCount,
              result.count >= FileSystemSyscallABI.resultByteCount,
              pathInput.count >= VFSPathLimits.maximumPathByteCount,
              canonicalPath.count >= VFSPathLimits.maximumPathByteCount,
              transfer.count > 0,
              transfer.count <= FileServiceLimits.maximumTransferByteCount,
              directoryName.count
                >= FileServiceLimits.maximumDirectoryNameByteCount,
              Self.arePairwiseDisjoint(
                  request,
                  result,
                  pathInput,
                  canonicalPath,
                  transfer,
                  directoryName
              )
        else { return nil }
        self.request = request
        self.result = result
        self.pathInput = pathInput
        self.canonicalPath = canonicalPath
        self.transfer = transfer
        self.directoryName = directoryName
    }

    private static func arePairwiseDisjoint(
        _ first: UnsafeMutableRawBufferPointer,
        _ second: UnsafeMutableRawBufferPointer,
        _ third: UnsafeMutableRawBufferPointer,
        _ fourth: UnsafeMutableRawBufferPointer,
        _ fifth: UnsafeMutableRawBufferPointer,
        _ sixth: UnsafeMutableRawBufferPointer
    ) -> Bool {
        disjoint(first, second)
            && disjoint(first, third)
            && disjoint(first, fourth)
            && disjoint(first, fifth)
            && disjoint(first, sixth)
            && disjoint(second, third)
            && disjoint(second, fourth)
            && disjoint(second, fifth)
            && disjoint(second, sixth)
            && disjoint(third, fourth)
            && disjoint(third, fifth)
            && disjoint(third, sixth)
            && disjoint(fourth, fifth)
            && disjoint(fourth, sixth)
            && disjoint(fifth, sixth)
    }

    private static func disjoint(
        _ firstBuffer: UnsafeMutableRawBufferPointer,
        _ secondBuffer: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard let first = interval(for: firstBuffer),
              let second = interval(for: secondBuffer)
        else { return false }
        return first.end <= second.start || second.end <= first.start
    }

    private static func interval(
        for buffer: UnsafeMutableRawBufferPointer
    ) -> (start: UInt, end: UInt)? {
        guard !buffer.isEmpty, let baseAddress = buffer.baseAddress else {
            return nil
        }
        let start = UInt(bitPattern: baseAddress)
        guard UInt(buffer.count) <= UInt.max - start else { return nil }
        return (start, start + UInt(buffer.count))
    }
}

struct FileServiceDispatchResult: Equatable {
    let status: FileSystemStatus
    /// False only when the result user range was invalid. In that case the
    /// register status remains authoritative and no result bytes were written.
    let resultWasCopied: Bool
}

/// One process's bounded filesystem authority. Give each process independent
/// handle slots and an instance carrying only its kernel-assigned capabilities.
struct EL0ProcessFileService<Backend: VFSFileServiceBackend> {
    let taskIdentifier: UInt64
    private let deviceCapability: VFSCapabilityIdentifier?
    private var handles: VFSHandleTable
    private let workspace: FileServiceWorkspace
    private(set) var backend: Backend

    init?(
        taskIdentifier: UInt64,
        deviceCapability: VFSCapabilityIdentifier? = nil,
        backend: Backend,
        uninitializedHandleSlots: UnsafeMutablePointer<VFSHandleSlot>?,
        handleSlotCount: Int,
        workspace: FileServiceWorkspace
    ) {
        guard taskIdentifier != 0,
              let handles = VFSHandleTable(
                  uninitializedSlots: uninitializedHandleSlots,
                  slotCount: handleSlotCount
              )
        else { return nil }
        self.taskIdentifier = taskIdentifier
        self.deviceCapability = deviceCapability
        self.backend = backend
        self.handles = handles
        self.workspace = workspace
    }

    var openHandleCount: Int { handles.openCount }

    mutating func dispatch(
        requestAddress: UInt64,
        requestByteCount: UInt64,
        resultAddress: UInt64,
        currentTaskIdentifier: UInt64,
        userMemory: EL0UserMemoryMap
    ) -> FileServiceDispatchResult {
        guard currentTaskIdentifier == taskIdentifier else {
            return FileServiceDispatchResult(
                status: .wrongProcess,
                resultWasCopied: false
            )
        }

        guard userMemory.validate(
            virtualAddress: resultAddress,
            byteCount: UInt64(FileSystemSyscallABI.resultByteCount),
            access: .write
        ) else {
            return FileServiceDispatchResult(
                status: .invalidUserMemory,
                resultWasCopied: false
            )
        }

        var result = FileSystemResult()
        guard requestByteCount
                == UInt64(FileSystemSyscallABI.requestByteCount),
              userMemory.validate(
                  virtualAddress: requestAddress,
                  byteCount: requestByteCount,
                  access: .read
              )
        else {
            result.status = requestByteCount
                == UInt64(FileSystemSyscallABI.requestByteCount)
                ? .invalidUserMemory : .invalidRequest
            return finish(
                result,
                at: resultAddress,
                userMemory: userMemory
            )
        }

        let requestScratch = prefix(
            workspace.request,
            count: FileSystemSyscallABI.requestByteCount
        )
        guard userMemory.copyIn(
            from: requestAddress,
            into: requestScratch
        ) else {
            result.status = .invalidUserMemory
            return finish(result, at: resultAddress, userMemory: userMemory)
        }

        let decoded = FileSystemSyscallCodec.decodeRequest(
            UnsafeRawBufferPointer(requestScratch)
        )
        let request: FileSystemRequest
        switch decoded {
        case .request(let validRequest):
            request = validRequest
            result.operationRaw = validRequest.operationRaw
        case .failure(let status):
            result.status = status
            return finish(result, at: resultAddress, userMemory: userMemory)
        }

        guard request.flags == 0, request.reserved == 0 else {
            result.status = .invalidRequest
            return finish(result, at: resultAddress, userMemory: userMemory)
        }
        guard let operation = request.operation else {
            result.status = .unsupportedOperation
            return finish(result, at: resultAddress, userMemory: userMemory)
        }

        switch operation {
        case .open:
            result = open(request, userMemory: userMemory)
        case .read:
            result = read(request, userMemory: userMemory)
        case .write:
            result = write(request, userMemory: userMemory)
        case .stat:
            result = stat(request)
        case .readDirectory:
            result = readDirectory(request, userMemory: userMemory)
        case .close:
            result = close(request)
        }
        result.operationRaw = request.operationRaw
        return finish(result, at: resultAddress, userMemory: userMemory)
    }

    private var principal: VFSPrincipal {
        .user(
            taskIdentifier: taskIdentifier,
            deviceCapability: deviceCapability
        )
    }

    private mutating func open(
        _ request: FileSystemRequest,
        userMemory: EL0UserMemoryMap
    ) -> FileSystemResult {
        var result = FileSystemResult()
        guard request.argument2 == 0,
              request.argument3 == 0,
              request.argument4 == 0,
              request.argument5 == 0,
              let requestedAccess = VFSAccessRights(
                  rawValue: request.requestedAccessRaw
              )
        else {
            result.status = .invalidRequest
            return result
        }
        guard !requestedAccess.isEmpty else {
            result.status = .accessDenied
            result.detail = FileSystemStatusDetail.emptyRights.rawValue
            return result
        }
        guard request.argument1 > 0,
              request.argument1 <= UInt64(VFSPathLimits.maximumPathByteCount),
              request.argument1 <= UInt64(Int.max)
        else {
            result.status = .invalidPath
            result.detail = FileSystemStatusDetail.pathInputTooLong.rawValue
            return result
        }
        let pathByteCount = Int(request.argument1)
        guard userMemory.validate(
            virtualAddress: request.argument0,
            byteCount: request.argument1,
            access: .read
        ) else {
            result.status = .invalidUserMemory
            return result
        }
        let input = prefix(workspace.pathInput, count: pathByteCount)
        guard userMemory.copyIn(from: request.argument0, into: input) else {
            result.status = .invalidUserMemory
            return result
        }

        let normalized = VFSPathNormalizer.normalize(
            UnsafeRawBufferPointer(input),
            into: workspace.canonicalPath
        )
        let path: VFSCanonicalPath
        switch normalized {
        case .path(let canonical):
            path = canonical
        case .failure(let failure):
            result.status = .invalidPath
            result.detail = detail(for: failure).rawValue
            return result
        }

        switch backend.resolve(path: path) {
        case .node(let mount, let metadata):
            switch handles.open(
                metadata: metadata,
                on: mount,
                for: principal,
                requesting: requestedAccess
            ) {
            case .handle(let token):
                result.status = .success
                result.payload = .handle
                result.value0 = encode(token)
                result.value1 = UInt64(requestedAccess.rawValue)
                result.value2 = UInt64(metadata.kind.rawValue)
            case .denied(let denial):
                result.status = .accessDenied
                result.detail = detail(for: denial).rawValue
            case .tableFull:
                result.status = .handleTableFull
            }
        case .syntheticDirectory:
            result.status = .unavailable
        case .notMounted:
            result.status = .notMounted
        case .failure(let failure):
            apply(failure, to: &result)
        }
        return result
    }

    private mutating func read(
        _ request: FileSystemRequest,
        userMemory: EL0UserMemoryMap
    ) -> FileSystemResult {
        var result = FileSystemResult()
        guard commonDataRequestIsValid(request),
              let byteCount = transferByteCount(request.argument3)
        else {
            result.status = .invalidRequest
            return result
        }
        guard request.argument3 <= UInt64.max - request.argument1 else {
            result.status = .overflow
            return result
        }
        guard userMemory.validate(
            virtualAddress: request.argument2,
            byteCount: request.argument3,
            access: .write
        ) else {
            result.status = .invalidUserMemory
            return result
        }
        guard let handle = lookup(
            request.argument0,
            requiring: .readData,
            result: &result
        ) else { return result }
        if byteCount == 0 {
            result.payload = .transfer
            return result
        }

        let output = prefix(workspace.transfer, count: byteCount)
        switch backend.read(
            from: handle,
            at: request.argument1,
            into: output
        ) {
        case .transferred(let transferred):
            guard transferred >= 0, transferred <= byteCount else {
                result.status = .malformedBackendResult
                return result
            }
            let transferredBytes = prefix(output, count: transferred)
            guard userMemory.copyOut(
                UnsafeRawBufferPointer(transferredBytes),
                to: request.argument2
            ) else {
                result.status = .invalidUserMemory
                return result
            }
            result.payload = .transfer
            result.value0 = UInt64(transferred)
        case .failure(let failure):
            apply(failure, to: &result)
        }
        return result
    }

    private mutating func write(
        _ request: FileSystemRequest,
        userMemory: EL0UserMemoryMap
    ) -> FileSystemResult {
        var result = FileSystemResult()
        guard commonDataRequestIsValid(request),
              let byteCount = transferByteCount(request.argument3)
        else {
            result.status = .invalidRequest
            return result
        }
        guard request.argument3 <= UInt64.max - request.argument1 else {
            result.status = .overflow
            return result
        }
        guard userMemory.validate(
            virtualAddress: request.argument2,
            byteCount: request.argument3,
            access: .read
        ) else {
            result.status = .invalidUserMemory
            return result
        }
        guard let handle = lookup(
            request.argument0,
            requiring: .writeData,
            result: &result
        ) else { return result }
        if byteCount == 0 {
            result.payload = .transfer
            return result
        }

        let input = prefix(workspace.transfer, count: byteCount)
        guard userMemory.copyIn(from: request.argument2, into: input) else {
            result.status = .invalidUserMemory
            return result
        }
        switch backend.write(
            to: handle,
            at: request.argument1,
            from: UnsafeRawBufferPointer(input)
        ) {
        case .transferred(let transferred):
            guard transferred >= 0, transferred <= byteCount else {
                result.status = .malformedBackendResult
                return result
            }
            result.payload = .transfer
            result.value0 = UInt64(transferred)
        case .failure(let failure):
            apply(failure, to: &result)
        }
        return result
    }

    private mutating func stat(
        _ request: FileSystemRequest
    ) -> FileSystemResult {
        var result = FileSystemResult()
        guard scalarHandleRequestIsValid(request) else {
            result.status = .invalidRequest
            return result
        }
        guard let handle = lookup(
            request.argument0,
            requiring: .readMetadata,
            result: &result
        ) else { return result }

        switch backend.metadata(for: handle) {
        case .metadata(let metadata):
            guard metadata.identifier == handle.node else {
                result.status = .malformedBackendResult
                return result
            }
            result.payload = .metadata
            result.value0 = metadata.identifier.volume.rawValue
            result.value1 = metadata.identifier.localValue
            result.value2 = UInt64(metadata.kind.rawValue)
            result.value3 = metadata.byteCount
            result.value4 = UInt64(metadata.linkCount)
            result.value5 = metadata.generation
            result.value6 = UInt64(bitPattern: metadata.createdAt.secondsSinceUnixEpoch)
            result.value7 = UInt64(metadata.createdAt.nanoseconds)
            result.value8 = UInt64(bitPattern: metadata.modifiedAt.secondsSinceUnixEpoch)
            result.value9 = UInt64(metadata.modifiedAt.nanoseconds)
            result.value10 = UInt64(metadata.availableAccess.rawValue)
            result.value11 = UInt64(handle.access.rawValue)
            result.value12 = UInt64(handle.mountIdentifier.rawValue)
        case .failure(let failure):
            apply(failure, to: &result)
        }
        return result
    }

    private mutating func readDirectory(
        _ request: FileSystemRequest,
        userMemory: EL0UserMemoryMap
    ) -> FileSystemResult {
        var result = FileSystemResult()
        guard request.requestedAccessRaw == 0,
              request.argument4 == 0,
              request.argument5 == 0,
              request.argument3 > 0,
              request.argument3
                <= UInt64(FileServiceLimits.maximumDirectoryNameByteCount),
              request.argument3 <= UInt64(workspace.directoryName.count)
        else {
            result.status = .invalidRequest
            return result
        }
        guard userMemory.validate(
            virtualAddress: request.argument2,
            byteCount: request.argument3,
            access: .write
        ) else {
            result.status = .invalidUserMemory
            return result
        }
        guard let handle = lookup(
            request.argument0,
            requiring: .enumerate,
            result: &result
        ) else { return result }

        let nameCapacity = Int(request.argument3)
        let nameOutput = prefix(workspace.directoryName, count: nameCapacity)
        let cookie = VFSDirectoryCookie(rawValue: request.argument1)
        switch backend.readDirectory(
            from: handle,
            after: cookie,
            nameOutput: nameOutput
        ) {
        case .entry(let entry, let nextCookie):
            let nameByteCount = entry.name.byteCount
            guard entry.identifier.volume == handle.node.volume,
                  nameByteCount > 0,
                  nameByteCount <= nameCapacity,
                  nextCookie != cookie
            else {
                result.status = .malformedBackendResult
                return result
            }
            let nameBytes = prefix(nameOutput, count: nameByteCount)
            guard case .name(let scratchName) = VFSNameValidator.validate(
                      UnsafeRawBufferPointer(nameBytes)
                  ),
                  scratchName.isBytewiseEqual(to: entry.name),
                  userMemory.copyOut(
                      UnsafeRawBufferPointer(nameBytes),
                      to: request.argument2
                  )
            else {
                result.status = .malformedBackendResult
                return result
            }
            result.payload = .directoryEntry
            result.value0 = nextCookie.rawValue
            result.value1 = UInt64(nameByteCount)
            result.value2 = entry.identifier.volume.rawValue
            result.value3 = entry.identifier.localValue
            result.value4 = UInt64(entry.kind.rawValue)
        case .end:
            result.payload = .directoryEnd
        case .staleCookie:
            result.status = .invalidOffset
        case .nameBufferTooSmall(let requiredByteCount):
            guard requiredByteCount > nameCapacity else {
                result.status = .malformedBackendResult
                return result
            }
            result.status = .bufferTooSmall
            result.detail = requiredByteCount > Int(UInt32.max)
                ? UInt32.max : UInt32(requiredByteCount)
        case .failure(let failure):
            apply(failure, to: &result)
        }
        return result
    }

    private mutating func close(
        _ request: FileSystemRequest
    ) -> FileSystemResult {
        var result = FileSystemResult()
        guard scalarHandleRequestIsValid(request) else {
            result.status = .invalidRequest
            return result
        }
        guard let token = decodeHandle(request.argument0) else {
            result.status = .invalidHandle
            return result
        }
        switch handles.close(token) {
        case .closed:
            break
        case .failure(let failure):
            apply(failure, to: &result)
        }
        return result
    }

    private func commonDataRequestIsValid(
        _ request: FileSystemRequest
    ) -> Bool {
        request.requestedAccessRaw == 0
            && request.argument4 == 0
            && request.argument5 == 0
    }

    private func scalarHandleRequestIsValid(
        _ request: FileSystemRequest
    ) -> Bool {
        request.requestedAccessRaw == 0
            && request.argument1 == 0
            && request.argument2 == 0
            && request.argument3 == 0
            && request.argument4 == 0
            && request.argument5 == 0
    }

    private func transferByteCount(_ rawValue: UInt64) -> Int? {
        guard rawValue <= UInt64(workspace.transfer.count),
              rawValue <= UInt64(FileServiceLimits.maximumTransferByteCount),
              rawValue <= UInt64(Int.max)
        else { return nil }
        return Int(rawValue)
    }

    private func lookup(
        _ rawHandle: UInt64,
        requiring rights: VFSAccessRights,
        result: inout FileSystemResult
    ) -> VFSOpenHandle? {
        guard let token = decodeHandle(rawHandle) else {
            result.status = .invalidHandle
            return nil
        }
        switch handles.lookup(token) {
        case .handle(let handle):
            guard handle.access.contains(rights) else {
                result.status = .accessDenied
                result.detail = FileSystemStatusDetail.deniedByNode.rawValue
                return nil
            }
            return handle
        case .failure(let failure):
            apply(failure, to: &result)
            return nil
        }
    }

    private func encode(_ token: VFSHandleToken) -> UInt64 {
        UInt64(token.slot) | UInt64(token.generation) << 32
    }

    private func decodeHandle(_ rawValue: UInt64) -> VFSHandleToken? {
        guard rawValue >> 16 & 0xffff == 0 else { return nil }
        let generation = UInt32(truncatingIfNeeded: rawValue >> 32)
        guard generation != 0 else { return nil }
        return VFSHandleToken(
            slot: UInt16(truncatingIfNeeded: rawValue),
            generation: generation
        )
    }

    private func finish(
        _ result: FileSystemResult,
        at resultAddress: UInt64,
        userMemory: EL0UserMemoryMap
    ) -> FileServiceDispatchResult {
        let output = prefix(
            workspace.result,
            count: FileSystemSyscallABI.resultByteCount
        )
        guard FileSystemSyscallCodec.encodeResult(result, into: output),
              userMemory.copyOut(
                  UnsafeRawBufferPointer(output),
                  to: resultAddress
              )
        else {
            return FileServiceDispatchResult(
                status: .invalidUserMemory,
                resultWasCopied: false
            )
        }
        return FileServiceDispatchResult(
            status: result.status,
            resultWasCopied: true
        )
    }

    private func prefix(
        _ buffer: UnsafeMutableRawBufferPointer,
        count: Int
    ) -> UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(
            start: buffer.baseAddress,
            count: count
        )
    }

    private func detail(
        for failure: VFSPathFailure
    ) -> FileSystemStatusDetail {
        switch failure {
        case .empty: return .pathEmpty
        case .notAbsolute: return .pathNotAbsolute
        case .inputTooLong: return .pathInputTooLong
        case .outputTooSmall: return .pathOutputTooSmall
        case .tooManyComponents: return .pathTooManyComponents
        case .componentTooLong: return .pathComponentTooLong
        case .traversalComponent: return .pathTraversal
        case .separatorInName: return .pathSeparatorInName
        case .nulByte: return .pathNUL
        case .controlByte: return .pathControlByte
        case .invalidUTF8: return .pathInvalidUTF8
        }
    }

    private func detail(
        for denial: VFSAccessDenial
    ) -> FileSystemStatusDetail {
        switch denial {
        case .emptyRequest: return .emptyRights
        case .invalidPrincipal: return .invalidPrincipal
        case .kernelOnlyVolume: return .kernelOnlyVolume
        case .volumeMismatch: return .volumeMismatch
        case .nodeRoleMismatch: return .nodeRoleMismatch
        case .deniedByRole: return .deniedByRole
        case .deniedByMount: return .deniedByMount
        case .deniedByNode: return .deniedByNode
        case .missingDeviceCapability: return .missingDeviceCapability
        }
    }

    private func apply(
        _ failure: VFSProviderFailure,
        to result: inout FileSystemResult
    ) {
        switch failure {
        case .notFound:
            result.status = .notFound
            result.detail = FileSystemStatusDetail.providerNotFound.rawValue
        case .notDirectory:
            result.status = .notDirectory
            result.detail = FileSystemStatusDetail.providerNotDirectory.rawValue
        case .isDirectory:
            result.status = .isDirectory
            result.detail = FileSystemStatusDetail.providerIsDirectory.rawValue
        case .alreadyExists:
            result.status = .alreadyExists
            result.detail = FileSystemStatusDetail.providerAlreadyExists.rawValue
        case .noSpace:
            result.status = .noSpace
            result.detail = FileSystemStatusDetail.providerNoSpace.rawValue
        case .readOnly:
            result.status = .readOnly
            result.detail = FileSystemStatusDetail.providerReadOnly.rawValue
        case .invalidOffset:
            result.status = .invalidOffset
            result.detail = FileSystemStatusDetail.providerInvalidOffset.rawValue
        case .corrupt:
            result.status = .corrupt
            result.detail = FileSystemStatusDetail.providerCorrupt.rawValue
        case .unavailable:
            result.status = .unavailable
            result.detail = FileSystemStatusDetail.providerUnavailable.rawValue
        case .ioFailure:
            result.status = .ioFailure
            result.detail = FileSystemStatusDetail.providerIOFailure.rawValue
        }
    }

    private func apply(
        _ failure: VFSHandleLookupFailure,
        to result: inout FileSystemResult
    ) {
        switch failure {
        case .invalidSlot:
            result.status = .invalidHandle
            result.detail = FileSystemStatusDetail.handleInvalidSlot.rawValue
        case .staleGeneration:
            result.status = .staleHandle
            result.detail = FileSystemStatusDetail.handleStaleGeneration.rawValue
        case .closed:
            result.status = .closedHandle
            result.detail = FileSystemStatusDetail.handleClosed.rawValue
        case .corruptSlot:
            result.status = .invalidHandle
            result.detail = FileSystemStatusDetail.handleCorrupt.rawValue
        }
    }
}
