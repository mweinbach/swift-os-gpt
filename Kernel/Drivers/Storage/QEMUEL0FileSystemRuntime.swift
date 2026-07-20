private typealias QEMUEL0FileBackend =
    BorrowedMountedProviderBackend<QEMUUserFileSystemProvider>
private typealias QEMUEL0FileService =
    EL0ProcessFileService<QEMUEL0FileBackend>

private nonisolated(unsafe) var qemuEL0FileSystemAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var qemuEL0FileSystemNamespace:
    UnsafeMutablePointer<VFSMountNamespace>?
private nonisolated(unsafe) var qemuEL0FileSystemService:
    UnsafeMutablePointer<QEMUEL0FileService>?
private nonisolated(unsafe) var qemuEL0FileSystemUserMemory:
    EL0UserMemoryMap?
private nonisolated(unsafe) var qemuEL0FileSystemConsole: EarlyConsole?
private nonisolated(unsafe) var qemuEL0FileSystemSawOpen = false
private nonisolated(unsafe) var qemuEL0FileSystemSawRead = false
private nonisolated(unsafe) var qemuEL0FileSystemSawWrite = false
private nonisolated(unsafe) var qemuEL0FileSystemSawClose = false
private nonisolated(unsafe) var qemuEL0FileSystemLockWord: UInt32 = 0

/// Binds the already mounted `/Users` provider to process one. Everything in
/// this adapter is caller-owned, fixed-capacity memory; the provider and its
/// VirtIO transport remain in their original stable records.
enum QEMUEL0FileSystemRuntime {
    private static let pageCount: UInt64 = 8
    private static let mountIdentifier = VFSMountIdentifier(rawValue: 1)!
    private static let taskIdentifier: UInt64 = 1
    private static let handleSlotCount = 8
    private static let maximumUserMemoryRegionCount =
        2 + KernelEL0AddressSpaceMappings.threadCapacity

    private static let regionOffset = 0
    private static let namespaceOffset = 4_096
    private static let mountSlotOffset = 4_352
    private static let mountPathOffset = 4_608
    private static let mountPathByteCount = 1_024
    private static let serviceOffset = 8_192
    private static let handleSlotOffset = 8_704
    private static let requestOffset = 12_288
    private static let resultOffset = 12_352
    private static let pathInputOffset = 12_480
    private static let canonicalPathOffset = 13_504
    private static let directoryNameOffset = 14_528
    private static let transferOffset = 16_384

    static func activate(
        console: EarlyConsole,
        mappings: KernelEL0AddressSpaceMappings
    ) {
        guard qemuEL0FileSystemAllocation == nil,
              let provider = QEMUSwiftFSRuntime.mountedProvider,
              let allocation = allocateWorkspace(),
              let base = rawBase(of: allocation),
              layoutFits(allocation: allocation),
              let regions = makeUserRegions(
                  at: base.advanced(by: regionOffset),
                  mappings: mappings
              )
        else { return }
        qemuEL0FileSystemAllocation = allocation

        let namespacePointer = base.advanced(by: namespaceOffset)
            .assumingMemoryBound(to: VFSMountNamespace.self)
        let mountSlots = base.advanced(by: mountSlotOffset)
            .assumingMemoryBound(to: VFSMountSlot.self)
        let mountPath = buffer(
            base: base,
            offset: mountPathOffset,
            count: mountPathByteCount
        )
        guard let namespace = VFSMountNamespace(
                  uninitializedSlots: mountSlots,
                  slotCount: 1,
                  pathStorage: mountPath,
                  maximumPathByteCountPerMount: mountPathByteCount
              )
        else {
            console.write("SWIFTOS:EL0_SWIFTFS_NAMESPACE_INVALID\n")
            return
        }
        namespacePointer.initialize(to: namespace)

        let pathInput = buffer(
            base: base,
            offset: pathInputOffset,
            count: VFSPathLimits.maximumPathByteCount
        )
        let canonical = buffer(
            base: base,
            offset: canonicalPathOffset,
            count: VFSPathLimits.maximumPathByteCount
        )
        let usersPath: StaticString = "/Users"
        let mounted = usersPath.withUTF8Buffer { pathBytes -> Bool in
            switch VFSPathNormalizer.normalize(
                UnsafeRawBufferPointer(pathBytes),
                into: canonical
            ) {
            case .path(let path):
                return namespacePointer.pointee.mount(
                    VFSVolumeDescriptor(
                        identifier: provider.pointee.volumeIdentifier,
                        role: .user,
                        visibility: .namespace
                    ),
                    at: path,
                    mountIdentifier: mountIdentifier,
                    userAccess: VFSRolePolicy.maximumAccess(for: .user)
                ) == .mounted
            case .failure:
                return false
            }
        }
        guard mounted,
              let backend = QEMUEL0FileBackend(
                  borrowing: namespacePointer,
                  provider: provider,
                  mountIdentifier: mountIdentifier,
                  rootNode: provider.pointee.rootNodeIdentifier
              ), let workspace = FileServiceWorkspace(
                  request: buffer(
                      base: base,
                      offset: requestOffset,
                      count: FileSystemSyscallABI.requestByteCount
                  ),
                  result: buffer(
                      base: base,
                      offset: resultOffset,
                      count: FileSystemSyscallABI.resultByteCount
                  ),
                  pathInput: pathInput,
                  canonicalPath: canonical,
                  transfer: buffer(
                      base: base,
                      offset: transferOffset,
                      count: 4_096
                  ),
                  directoryName: buffer(
                      base: base,
                      offset: directoryNameOffset,
                      count: FileServiceLimits.maximumDirectoryNameByteCount
                  )
              )
        else {
            console.write("SWIFTOS:EL0_SWIFTFS_SERVICE_INVALID\n")
            return
        }

        let handleSlots = base.advanced(by: handleSlotOffset)
            .assumingMemoryBound(to: VFSHandleSlot.self)
        guard let service = QEMUEL0FileService(
                  taskIdentifier: taskIdentifier,
                  backend: backend,
                  uninitializedHandleSlots: handleSlots,
                  handleSlotCount: handleSlotCount,
                  workspace: workspace
              )
        else {
            console.write("SWIFTOS:EL0_SWIFTFS_SERVICE_INVALID\n")
            return
        }
        let servicePointer = base.advanced(by: serviceOffset)
            .assumingMemoryBound(to: QEMUEL0FileService.self)
        servicePointer.initialize(to: service)
        qemuEL0FileSystemNamespace = namespacePointer
        qemuEL0FileSystemService = servicePointer
        qemuEL0FileSystemUserMemory = regions
        qemuEL0FileSystemConsole = console

        guard KernelEL0Runtime.installExternalSystemCallHook(
                  swiftOSQEMUEL0FileSystemSystemCall
              )
        else {
            qemuEL0FileSystemService = nil
            qemuEL0FileSystemUserMemory = nil
            console.write("SWIFTOS:EL0_SWIFTFS_HOOK_UNAVAILABLE\n")
            return
        }
        console.write("SWIFTOS:EL0_SWIFTFS_SERVICE_READY\n")
    }
}

private extension QEMUEL0FileSystemRuntime {
    struct RequestWords {
        var word0: UInt64 = 0
        var word1: UInt64 = 0
        var word2: UInt64 = 0
        var word3: UInt64 = 0
        var word4: UInt64 = 0
        var word5: UInt64 = 0
        var word6: UInt64 = 0
        var word7: UInt64 = 0
    }

    static func dispatch(_ rawFrame: UnsafeMutableRawPointer) -> UInt64 {
        let interruptState = lock()
        defer { unlock(restoring: interruptState) }
        guard let service = qemuEL0FileSystemService,
              let userMemory = qemuEL0FileSystemUserMemory
        else { return 0 }
        let frame = rawFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
        let operation = requestOperation(frame: frame, userMemory: userMemory)
        let disposition = EL0FileSystemExceptionDispatcher.dispatch(
            frame: frame,
            currentTaskIdentifier: taskIdentifier,
            service: &service.pointee,
            userMemory: userMemory
        )
        guard case .handled(let status) = disposition else {
            qemuEL0FileSystemConsole?.write(
                "SWIFTOS:EL0_SWIFTFS_DISPATCH_UNHANDLED\n"
            )
            return 0
        }
        if status != .success {
            qemuEL0FileSystemConsole?.write("SWIFTOS:EL0_SWIFTFS_STATUS=")
            qemuEL0FileSystemConsole?.writeHex(status.registerValue)
            qemuEL0FileSystemConsole?.write("\n")
        }
        if status == .success, let operation {
            record(operation)
        }
        return 1
    }

    static func requestOperation(
        frame: UnsafeMutablePointer<AArch64ExceptionFrame>,
        userMemory: EL0UserMemoryMap
    ) -> FileSystemOperation? {
        guard frame.pointee.x8 == FileSystemSyscallABI.systemCallNumber,
              frame.pointee.x1
                == UInt64(FileSystemSyscallABI.requestByteCount)
        else { return nil }
        var words = RequestWords()
        let copied = withUnsafeMutableBytes(of: &words) { bytes in
            userMemory.copyIn(from: frame.pointee.x0, into: bytes)
        }
        guard copied else { return nil }
        return withUnsafeBytes(of: words) { bytes -> FileSystemOperation? in
            switch FileSystemSyscallCodec.decodeRequest(bytes) {
            case .request(let request): return request.operation
            case .failure: return nil
            }
        }
    }

    static func record(_ operation: FileSystemOperation) {
        switch operation {
        case .open where !qemuEL0FileSystemSawOpen:
            qemuEL0FileSystemSawOpen = true
            qemuEL0FileSystemConsole?.write("SWIFTOS:EL0_SWIFTFS_OPEN_OK\n")
        case .read where qemuEL0FileSystemSawOpen
            && !qemuEL0FileSystemSawRead:
            qemuEL0FileSystemSawRead = true
            qemuEL0FileSystemConsole?.write("SWIFTOS:EL0_SWIFTFS_READ_OK\n")
        case .write where qemuEL0FileSystemSawRead
            && !qemuEL0FileSystemSawWrite:
            qemuEL0FileSystemSawWrite = true
            qemuEL0FileSystemConsole?.write("SWIFTOS:EL0_SWIFTFS_WRITE_OK\n")
        case .close where qemuEL0FileSystemSawWrite
            && !qemuEL0FileSystemSawClose:
            qemuEL0FileSystemSawClose = true
            qemuEL0FileSystemConsole?.write("SWIFTOS:EL0_SWIFTFS_CLOSE_OK\n")
            qemuEL0FileSystemConsole?.write("SWIFTOS:EL0_FILE_IO_PROVEN\n")
        default:
            break
        }
    }

    static func allocateWorkspace() -> ClassifiedPageAllocationToken? {
        let result = KernelMemoryRuntime.allocateClassifiedPages(
            ClassifiedPageAllocationConstraints(
                pageCount: pageCount,
                requiredCapabilities: .cpuAccessible,
                domainSelection: .preferred(
                    KernelMemoryRuntime.defaultSystemMemoryDomain,
                    fallback: .disallowed
                )
            )
        )
        guard case .allocated(let token) = result else { return nil }
        return token
    }

    static func rawBase(
        of allocation: ClassifiedPageAllocationToken
    ) -> UnsafeMutableRawPointer? {
        guard allocation.range.baseAddress <= UInt64(UInt.max) else {
            return nil
        }
        return UnsafeMutableRawPointer(
            bitPattern: UInt(allocation.range.baseAddress)
        )
    }

    static func layoutFits(
        allocation: ClassifiedPageAllocationToken
    ) -> Bool {
        let total = allocation.range.byteCount
        return total >= pageCount * MemoryPageGeometry.pageSize
            && UInt64(
                regionOffset
                    + maximumUserMemoryRegionCount
                        * MemoryLayout<EL0UserMemoryRegion>.stride
            )
                <= UInt64(namespaceOffset)
            && MemoryLayout<VFSMountNamespace>.stride
                <= mountSlotOffset - namespaceOffset
            && MemoryLayout<VFSMountSlot>.stride
                <= mountPathOffset - mountSlotOffset
            && MemoryLayout<QEMUEL0FileService>.stride
                <= handleSlotOffset - serviceOffset
            && handleSlotCount * MemoryLayout<VFSHandleSlot>.stride
                <= requestOffset - handleSlotOffset
            && UInt64(transferOffset + 4_096) <= total
    }

    static func buffer(
        base: UnsafeMutableRawPointer,
        offset: Int,
        count: Int
    ) -> UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(
            start: base.advanced(by: offset),
            count: count
        )
    }

    static func makeUserRegions(
        at raw: UnsafeMutableRawPointer,
        mappings: KernelEL0AddressSpaceMappings
    ) -> EL0UserMemoryMap? {
        let output = raw.assumingMemoryBound(to: EL0UserMemoryRegion.self)
        var count = 0
        guard append(
                  mappings.userText,
                  permissions: .read,
                  to: output,
                  count: &count
              )
        else { return nil }
        if let readOnly = mappings.userReadOnlyData {
            guard append(
                      readOnly,
                      permissions: .read,
                      to: output,
                      count: &count
                  )
            else { return nil }
        }
        var threadIndex = 0
        while threadIndex < KernelEL0AddressSpaceMappings.threadCapacity {
            guard let thread = mappings.thread(at: threadIndex),
                  append(
                      thread.stack,
                      permissions: .readWrite,
                      to: output,
                      count: &count
                  )
            else { return nil }
            threadIndex += 1
        }
        return EL0UserMemoryMap(
            regions: UnsafeBufferPointer(start: output, count: count),
            virtualAddressLimit: FinalTranslationTableGeometry.virtualAddressLimit
        )
    }

    static func append(
        _ mapping: FinalMappingRegion,
        permissions: EL0UserMemoryPermissions,
        to output: UnsafeMutablePointer<EL0UserMemoryRegion>,
        count: inout Int
    ) -> Bool {
        guard count < maximumUserMemoryRegionCount,
              mapping.physicalBaseAddress <= UInt64(UInt.max),
              let physical = UnsafeMutableRawPointer(
                  bitPattern: UInt(mapping.physicalBaseAddress)
              ), let region = EL0UserMemoryRegion(
                  virtualBaseAddress: mapping.virtualBaseAddress,
                  byteCount: mapping.byteCount,
                  permissions: permissions,
                  kernelMappedBaseAddress: physical
              )
        else { return false }
        (output + count).initialize(to: region)
        count += 1
        return true
    }

    private static func lock() -> UInt64 {
        withUnsafeMutablePointer(to: &qemuEL0FileSystemLockWord) { word in
            AArch64.acquireInterruptSafeLock(word)
        }
    }

    private static func unlock(restoring interruptState: UInt64) {
        withUnsafeMutablePointer(to: &qemuEL0FileSystemLockWord) { word in
            AArch64.releaseInterruptSafeLock(
                word,
                restoring: interruptState
            )
        }
    }
}

@_cdecl("swiftos_qemu_el0_filesystem_system_call")
func swiftOSQEMUEL0FileSystemSystemCall(
    _ rawFrame: UnsafeMutableRawPointer
) -> UInt64 {
    QEMUEL0FileSystemRuntime.dispatch(rawFrame)
}
