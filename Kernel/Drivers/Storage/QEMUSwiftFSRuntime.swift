typealias QEMUUserFileSystemBlockDevice =
    BorrowedBlockDeviceRegion<VirtIOBlockMMIODevice>
typealias QEMUUserFileSystemProvider =
    SwiftFSPersistentProvider<QEMUUserFileSystemBlockDevice>

private nonisolated(unsafe) var qemuSwiftFSActivationAttempted = false
private nonisolated(unsafe) var qemuVirtIOBlockDMAAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var qemuVirtIOBlockRecordAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var qemuSwiftFSScratchAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var qemuSwiftFSProviderAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var qemuVirtIOBlockDevice:
    UnsafeMutablePointer<VirtIOBlockMMIODevice>?
private nonisolated(unsafe) var qemuUserFileSystemProvider:
    UnsafeMutablePointer<QEMUUserFileSystemProvider>?

/// QEMU policy around the transport-neutral block, data-volume, and SwiftFS
/// layers. The attached raw disk represents exactly one SwiftOS data
/// partition; the physical Pi path reaches the same layers after MBR selection.
/// No filesystem code depends on VirtIO or a QEMU address.
enum QEMUSwiftFSRuntime {
    static let userVolumeIdentifier = VFSVolumeIdentifier(
        rawValue: 0x5357_4653_5553_4552
    )!
    static let kernelLogBlockCount: UInt64 = 8
    static let nodeCapacity: UInt32 = 32

    static var mountedProvider:
        UnsafeMutablePointer<QEMUUserFileSystemProvider>? {
        qemuUserFileSystemProvider
    }

    static func activate(console: EarlyConsole, platform: Platform) {
        guard case .qemuVirt = platform.kind,
              !qemuSwiftFSActivationAttempted
        else { return }
        qemuSwiftFSActivationAttempted = true
        guard let resource = blockResource(platform: platform) else { return }

        guard let allocations = allocateRuntimePages() else {
            console.write("SWIFTOS:VIRTIO_BLOCK_MEMORY_UNAVAILABLE\n")
            return
        }
        retain(allocations)

        guard let workspace = VirtIOBlockBootstrapMemory(
                  allocation: allocations.dma,
                  deviceBaseAddress: allocations.dma.range.baseAddress,
                  deviceAddressWidth: .bits64,
                  coherency: .hardwareCoherent
              ), let devicePointer = pointer(
                  in: allocations.deviceRecord,
                  to: VirtIOBlockMMIODevice.self
              ), let providerPointer = pointer(
                  in: allocations.providerRecord,
                  to: QEMUUserFileSystemProvider.self
              ), let scratch = rawBuffer(for: allocations.scratch)
        else {
            console.write("SWIFTOS:VIRTIO_BLOCK_MEMORY_INVALID\n")
            return
        }

        let initialized = VirtIOBlockMMIODevice.initialize(
            resource: resource,
            storage: workspace.storage
        )
        let initializedDevice: VirtIOBlockMMIODevice
        switch initialized {
        case .ready(let device):
            initializedDevice = device
        case .failure:
            // All pages remain owned by this runtime. Even if a future driver
            // regression leaves a queue device-visible, allocator reuse cannot
            // turn it into a cross-owner DMA write.
            console.write("SWIFTOS:VIRTIO_BLOCK_INIT_FAILED\n")
            return
        }
        devicePointer.initialize(to: initializedDevice)
        qemuVirtIOBlockDevice = devicePointer
        console.write("SWIFTOS:VIRTIO_BLOCK_READY\n")
        console.write("SWIFTOS:VIRTIO_BLOCK_CAPACITY=")
        console.writeHex(devicePointer.pointee.geometry.logicalBlockCount)
        console.write("\n")

        guard let fullRange = BlockDeviceRange(
                  startBlock: 0,
                  blockCount: devicePointer.pointee.geometry.logicalBlockCount,
                  within: devicePointer.pointee.geometry.logicalBlockCount
              ), var dataPartition = QEMUUserFileSystemBlockDevice(
                  borrowing: devicePointer,
                  partitionRange: fullRange
              )
        else {
            console.write("SWIFTOS:DATA_VOLUME_BOUNDS_INVALID\n")
            return
        }

        let dataBootstrap = SwiftOSDataVolumeBootstrap.openOrInitializeBlank(
            &dataPartition,
            kernelLogBlockCount: kernelLogBlockCount,
            scratch: scratch
        )
        let dataLayout: SwiftOSDataVolumeLayout
        switch dataBootstrap {
        case .opened(let layout):
            dataLayout = layout
            console.write("SWIFTOS:DATA_VOLUME_MOUNTED\n")
        case .initialized(let layout):
            dataLayout = layout
            console.write("SWIFTOS:DATA_VOLUME_INITIALIZED\n")
        case .failure:
            console.write("SWIFTOS:DATA_VOLUME_UNAVAILABLE\n")
            return
        }

        guard let userRange = BlockDeviceRange(
                  startBlock: dataLayout.userDataStartBlock,
                  blockCount: dataLayout.userDataBlockCount,
                  within: devicePointer.pointee.geometry.logicalBlockCount
              ), let userDevice = QEMUUserFileSystemBlockDevice(
                  borrowing: devicePointer,
                  partitionRange: userRange
              )
        else {
            console.write("SWIFTOS:SWIFTFS_BOUNDS_INVALID\n")
            return
        }

        let filesystem = SwiftFSPersistentVolumeBootstrap.openOrFormatBlank(
            userDevice,
            volumeIdentifier: userVolumeIdentifier,
            nodeCapacity: nodeCapacity,
            scratch: scratch
        )
        let state: SwiftFSPersistentVolumeState
        switch filesystem {
        case .ready(let provider, let mountedState):
            providerPointer.initialize(to: provider)
            qemuUserFileSystemProvider = providerPointer
            state = mountedState
        case .failure:
            console.write("SWIFTOS:SWIFTFS_UNAVAILABLE\n")
            return
        }

        switch state {
        case .formatted:
            guard seedWelcomeFile(
                      provider: providerPointer,
                      scratch: scratch
                  ) else {
                console.write("SWIFTOS:SWIFTFS_SEED_FAILED\n")
                qemuUserFileSystemProvider = nil
                return
            }
            console.write("SWIFTOS:SWIFTFS_FORMATTED\n")
            console.write("SWIFTOS:SWIFTFS_SEEDED\n")
        case .mounted:
            console.write("SWIFTOS:SWIFTFS_REMOUNTED\n")
        }

        guard verifyWelcomeFile(
                  provider: providerPointer,
                  scratch: scratch
              )
        else {
            console.write("SWIFTOS:SWIFTFS_DATA_INVALID\n")
            qemuUserFileSystemProvider = nil
            return
        }
        console.write("SWIFTOS:SWIFTFS_DATA_OK\n")
        console.write("SWIFTOS:SWIFTFS_READY\n")
    }
}

private extension QEMUSwiftFSRuntime {
    struct Allocations {
        let dma: ClassifiedPageAllocationToken
        let deviceRecord: ClassifiedPageAllocationToken
        let scratch: ClassifiedPageAllocationToken
        let providerRecord: ClassifiedPageAllocationToken
    }

    static let welcomeName: StaticString = "Welcome.txt"
    static let welcomeContents: StaticString =
        "Welcome to SwiftOS. This file survived a real block-device reboot.\n"

    static func blockResource(platform: Platform) -> DeviceResource? {
        var index = 0
        while index < 64, let resource = platform.virtioTransport(at: index) {
            defer { index += 1 }
            guard platform.virtioTransportIsDMACoherent(at: index),
                  let transport = VirtIOMMIOTransport(resource: resource),
                  transport.hasVirtIOMagic,
                  transport.identity.version
                    == VirtIOMMIOTransport.modernVersion,
                  transport.identity.deviceID
                    == VirtIOBlockMMIODevice.blockDeviceID
            else { continue }
            return resource
        }
        return nil
    }

    static func allocateRuntimePages() -> Allocations? {
        let coherent = PhysicalMemoryCapabilities.cpuAccessible
            .union(.deviceAccessible)
            .union(.cacheCoherent)
        guard let dma = allocate(
                  pageCount: VirtIOBlockBootstrapMemory.pageCount,
                  capabilities: coherent
              ), let deviceRecord = allocate(
                  pageCount: 1,
                  capabilities: .cpuAccessible
              ), let scratch = allocate(
                  pageCount: 1,
                  capabilities: .cpuAccessible
              ), let providerRecord = allocate(
                  pageCount: 1,
                  capabilities: .cpuAccessible
              )
        else {
            // A partial allocation is intentionally retained by the kernel
            // allocator for now; this boot path is one-shot and never obtains
            // device authority before the complete set exists.
            return nil
        }
        return Allocations(
            dma: dma,
            deviceRecord: deviceRecord,
            scratch: scratch,
            providerRecord: providerRecord
        )
    }

    static func allocate(
        pageCount: UInt64,
        capabilities: PhysicalMemoryCapabilities
    ) -> ClassifiedPageAllocationToken? {
        let result = KernelMemoryRuntime.allocateClassifiedPages(
            ClassifiedPageAllocationConstraints(
                pageCount: pageCount,
                requiredCapabilities: capabilities,
                domainSelection: .preferred(
                    KernelMemoryRuntime.defaultSystemMemoryDomain,
                    fallback: .disallowed
                )
            )
        )
        guard case .allocated(let token) = result else { return nil }
        return token
    }

    static func retain(_ allocations: Allocations) {
        qemuVirtIOBlockDMAAllocation = allocations.dma
        qemuVirtIOBlockRecordAllocation = allocations.deviceRecord
        qemuSwiftFSScratchAllocation = allocations.scratch
        qemuSwiftFSProviderAllocation = allocations.providerRecord
    }

    static func pointer<Value>(
        in allocation: ClassifiedPageAllocationToken,
        to type: Value.Type
    ) -> UnsafeMutablePointer<Value>? {
        guard UInt64(MemoryLayout<Value>.stride) <= allocation.range.byteCount,
              allocation.range.baseAddress <= UInt64(UInt.max),
              allocation.range.baseAddress
                & UInt64(MemoryLayout<Value>.alignment - 1) == 0,
              let raw = UnsafeMutableRawPointer(
                  bitPattern: UInt(allocation.range.baseAddress)
              )
        else { return nil }
        return raw.assumingMemoryBound(to: Value.self)
    }

    static func rawBuffer(
        for allocation: ClassifiedPageAllocationToken
    ) -> UnsafeMutableRawBufferPointer? {
        guard allocation.range.baseAddress <= UInt64(UInt.max),
              allocation.range.byteCount <= UInt64(Int.max),
              let pointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(allocation.range.baseAddress)
              )
        else { return nil }
        return UnsafeMutableRawBufferPointer(
            start: pointer,
            count: Int(allocation.range.byteCount)
        )
    }

    static func seedWelcomeFile(
        provider: UnsafeMutablePointer<QEMUUserFileSystemProvider>,
        scratch: UnsafeMutableRawBufferPointer
    ) -> Bool {
        let timestamp = VFSTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 0)!
        return welcomeName.withUTF8Buffer { nameBytes in
            guard case .name(let name) = VFSNameValidator.validate(
                      UnsafeRawBufferPointer(nameBytes)
                  )
            else { return false }
            let created = provider.pointee.create(
                parent: provider.pointee.rootNodeIdentifier,
                name: name,
                kind: .regularFile,
                timestamp: timestamp
            )
            let file: VFSNodeIdentifier
            switch created {
            case .created(let metadata):
                file = metadata.identifier
            case .failure:
                return false
            }
            return welcomeContents.withUTF8Buffer { contents in
                provider.pointee.write(
                    node: file,
                    at: 0,
                    from: UnsafeRawBufferPointer(contents),
                    modifiedAt: timestamp
                ) == .transferred(byteCount: contents.count)
            }
        }
    }

    static func verifyWelcomeFile(
        provider: UnsafeMutablePointer<QEMUUserFileSystemProvider>,
        scratch: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard scratch.count >= 2_048 + 512,
              let outputBase = scratch.baseAddress?.advanced(by: 2_048)
        else { return false }
        return welcomeName.withUTF8Buffer { nameBytes in
            guard case .name(let name) = VFSNameValidator.validate(
                      UnsafeRawBufferPointer(nameBytes)
                  ), case .node(let metadata) = provider.pointee.lookup(
                      parent: provider.pointee.rootNodeIdentifier,
                      name: name
                  )
            else { return false }
            let output = UnsafeMutableRawBufferPointer(
                start: outputBase,
                count: 512
            )
            return welcomeContents.withUTF8Buffer { expected in
                guard case .transferred(let byteCount) = provider.pointee.read(
                          node: metadata.identifier,
                          at: 0,
                          into: output
                      ), byteCount == expected.count
                else { return false }
                var index = 0
                while index < expected.count {
                    if output[index] != expected[index] { return false }
                    index += 1
                }
                return true
            }
        }
    }
}
