enum QEMUAcceleratedFileManagerActivationResult: Equatable {
    case activated(
        fileCount: Int,
        mountedFileSystem: Bool,
        directoryWasTruncated: Bool
    )
    case alreadyAttempted
    case inputHandlerUnavailable
    case invalidConfiguration
    case allocationUnavailable
    case invalidRuntimeStorage
    case fileSystemReadFailed
}

enum QEMUAcceleratedFileManagerRuntimeFailure: Equatable {
    case commandIdentifierExhausted
    case sceneCompilation(GPUFileManagerSceneRejection)
    case invalidPresentationDamage
    case gpu(VirtIOGPU3DSessionError)
}

enum QEMUAcceleratedFileManagerServiceResult: Equatable {
    case inactive
    case idle(ticksUntilNextFrame: UInt64)
    case presented(completionFenceID: UInt64)
    case failed(QEMUAcceleratedFileManagerRuntimeFailure)
}

private struct QEMUAcceleratedFileManagerState {
    var interaction: AcceleratedFileManagerInteractionState
    let viewport: DisplayViewport
    let target: GPURenderTargetID
    let fontAtlas: GPUTextureID
    var nextCommandIdentifier: UInt64
    var failure: QEMUAcceleratedFileManagerRuntimeFailure?

    mutating func service(
        session: inout VirtIOGPU3DSession,
        counterTick: UInt64
    ) -> QEMUAcceleratedFileManagerServiceResult {
        if let failure { return .failed(failure) }
        let animation = interaction.advanceAnimations(to: counterTick)
        guard interaction.needsPresentation
                || animation.framesDue > 0
                && interaction.animationNeedsPresentation
        else {
            return .idle(ticksUntilNextFrame: animation.ticksUntilNextFrame)
        }
        guard nextCommandIdentifier <= UInt64.max - 2,
              let chromeID = GPUCommandBufferID(
                  rawValue: nextCommandIdentifier
              ), let textID = GPUCommandBufferID(
                  rawValue: nextCommandIdentifier + 1
              )
        else {
            return fail(.commandIdentifierExhausted)
        }
        nextCommandIdentifier += 2

        let presentationSample = FileManagerAnimationSample(
            windowOpacity: animation.sample.windowOpacity,
            focusOpacity: animation.sample.focusOpacity,
            selectionOpacity: animation.sample.selectionOpacity,
            hoverOpacity: animation.sample.hoverOpacity,
            cursorIsVisible: true
        )
        let compiled = GPUFileManagerSceneCompiler.compile(
            model: interaction.browser,
            layout: interaction.layout,
            cursor: interaction.router.cursor,
            animation: presentationSample,
            hoveredVisibleRow: interaction.hoveredVisibleRow,
            viewport: viewport,
            target: target,
            fontAtlas: fontAtlas,
            chromeCommandBufferID: chromeID,
            textCommandBufferID: textID
        )
        let frame: GPUFileManagerSceneFrame
        switch compiled {
        case .frame(let compiledFrame):
            frame = compiledFrame
        case .rejected(let rejection):
            return fail(.sceneCompilation(rejection))
        }
        let damage = frame.presentationDamage
        guard damage.width != 0, damage.height != 0 else {
            return fail(.invalidPresentationDamage)
        }
        let result = session.renderBatch(
            frame.chromeCommandBuffer,
            then: frame.textCommandBuffer,
            damage: VirtIOGPURectangle(
                x: damage.x,
                y: damage.y,
                width: damage.width,
                height: damage.height
            )
        )
        switch result {
        case .presented(let completionFenceID):
            interaction.markPresented()
            return .presented(completionFenceID: completionFenceID)
        case .failed(let error):
            return fail(.gpu(error))
        }
    }

    private mutating func fail(
        _ failure: QEMUAcceleratedFileManagerRuntimeFailure
    ) -> QEMUAcceleratedFileManagerServiceResult {
        self.failure = failure
        return .failed(failure)
    }
}

private nonisolated(unsafe) var qemuFileManagerActivationAttempted = false
private nonisolated(unsafe) var qemuFileManagerStateAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var qemuFileManagerBackingAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var qemuFileManagerState:
    UnsafeMutablePointer<QEMUAcceleratedFileManagerState>?

@_cdecl("swiftos_qemu_accelerated_file_manager_input")
private func qemuAcceleratedFileManagerInput(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafeRawPointer
) {
    guard let context else { return }
    let state = context.assumingMemoryBound(
        to: QEMUAcceleratedFileManagerState.self
    )
    state.pointee.interaction.accept(
        event.assumingMemoryBound(to: InputEvent.self).pointee
    )
}

/// Owns the QEMU accelerated desktop's UI state while KernelMain retains the
/// actual VirtIO-GPU session. The root loop activates once, services canonical
/// VirtIO input, then passes its session here for bounded presentation work.
enum QEMUAcceleratedFileManagerRuntime {
    static let readyMarker: StaticString =
        "SWIFTOS:QEMU_FILE_MANAGER_READY\n"
    static let frameMarker: StaticString =
        "SWIFTOS:QEMU_FILE_MANAGER_FRAME\n"
    static let steadyMarker: StaticString =
        "SWIFTOS:QEMU_FILE_MANAGER_STEADY\n"
    static let interactionFrameMarker: StaticString =
        "SWIFTOS:QEMU_FILE_MANAGER_INTERACTION_FRAME\n"

    private static let statePageCount: UInt64 = 1
    private static let backingPageCount: UInt64 = 3
    private static let entryCount = 32
    private static let windowCount = 4
    private static let entryOffset = 0
    private static let windowOffset = 2_048
    private static let directoryNameOffset = 2_560
    private static let directoryNameByteCount =
        VFSPathLimits.maximumComponentByteCount
    private static let typeaheadOffset = 3_072
    private static let typeaheadByteCount = 64
    private static let nameOffset = 4_096
    private static let nameByteCount = 8_192
    private static let firstCommandIdentifier: UInt64 = 0x1_000

    static var isActive: Bool { qemuFileManagerState != nil }

    static func activate(
        configuration: VirtIOGPU3DSessionConfiguration,
        counterFrequency: UInt64,
        startingAt counterTick: UInt64
    ) -> QEMUAcceleratedFileManagerActivationResult {
        guard !qemuFileManagerActivationAttempted else {
            return .alreadyAttempted
        }
        qemuFileManagerActivationAttempted = true
        guard !SynchronousInputEventDispatcher.hasHandler else {
            return .inputHandlerUnavailable
        }
        guard let mode = DisplayMode(
                  widthInPixels: configuration.width,
                  heightInPixels: configuration.height,
                  refreshRateMilliHertz: nil,
                  pixelFormat: .b8g8r8a8
              ), let viewport = DisplayViewport(mode: mode),
              let layout = FileManagerLayout(
                  desktopBounds: viewport.logicalBounds,
                  windowFrame: Rectangle(
                      x: 80,
                      y: 70,
                      width: 640,
                      height: 460
                  )
              ), let target = GPURenderTargetID(
                  rawValue: configuration.resourceID
              ), let fontAtlas = GPUTextureID(
                  rawValue: configuration.glyphAtlasResourceID
              ), counterFrequency >= 60
        else {
            return .invalidConfiguration
        }

        guard let stateAllocation = allocate(pageCount: statePageCount) else {
            return .allocationUnavailable
        }
        guard let backingAllocation = allocate(pageCount: backingPageCount) else {
            _ = KernelMemoryRuntime.releaseClassifiedPages(stateAllocation)
            return .allocationUnavailable
        }
        guard let storage = makeStorage(backingAllocation) else {
            release(stateAllocation, backingAllocation)
            return .invalidRuntimeStorage
        }
        guard let statePointer = pointer(
                  in: stateAllocation,
                  to: QEMUAcceleratedFileManagerState.self
              ), var interaction = AcceleratedFileManagerInteractionState(
                  entryStorage: storage.entries,
                  nameStorage: storage.names,
                  windowStorage: storage.windows,
                  typeaheadStorage: storage.typeahead,
                  layout: layout,
                  counterFrequency: counterFrequency,
                  startingAt: counterTick,
                  pointerScale: viewport.scale
              )
        else {
            storage.deinitializeRecords()
            release(stateAllocation, backingAllocation)
            return .invalidRuntimeStorage
        }

        let mounted = QEMUSwiftFSRuntime.mountedProvider != nil
        var directoryWasTruncated = false
        if let provider = QEMUSwiftFSRuntime.mountedProvider {
            let root = provider.pointee.rootNodeIdentifier
            let loadResult = FileManagerDirectoryLoader.load(
                interaction: &interaction,
                provider: &provider.pointee,
                root: root,
                nameScratch: storage.directoryName
            )
            guard case .loaded(_, let wasTruncated) = loadResult else {
                storage.deinitializeRecords()
                release(stateAllocation, backingAllocation)
                return .fileSystemReadFailed
            }
            directoryWasTruncated = wasTruncated
        }
        statePointer.initialize(
            to: QEMUAcceleratedFileManagerState(
                interaction: interaction,
                viewport: viewport,
                target: target,
                fontAtlas: fontAtlas,
                nextCommandIdentifier: firstCommandIdentifier,
                failure: nil
            )
        )
        qemuFileManagerStateAllocation = stateAllocation
        qemuFileManagerBackingAllocation = backingAllocation
        qemuFileManagerState = statePointer
        SynchronousInputEventDispatcher.install(
            qemuAcceleratedFileManagerInput,
            context: UnsafeMutableRawPointer(statePointer)
        )
        return .activated(
            fileCount: statePointer.pointee.interaction.browser.count,
            mountedFileSystem: mounted,
            directoryWasTruncated: directoryWasTruncated
        )
    }

    static func serviceOnce(
        session: inout VirtIOGPU3DSession,
        counterTick: UInt64
    ) -> QEMUAcceleratedFileManagerServiceResult {
        guard let state = qemuFileManagerState else { return .inactive }
        return state.pointee.service(
            session: &session,
            counterTick: counterTick
        )
    }

    static var transitionIsActive: Bool {
        guard let state = qemuFileManagerState else { return false }
        return state.pointee.interaction.animationNeedsPresentation
    }

    private struct Storage {
        let entries: UnsafeMutableBufferPointer<FileBrowserEntryRecord>
        let windows: UnsafeMutableBufferPointer<UIWindowRecord>
        let directoryName: UnsafeMutableRawBufferPointer
        let typeahead: UnsafeMutableRawBufferPointer
        let names: UnsafeMutableRawBufferPointer

        func deinitializeRecords() {
            entries.baseAddress?.deinitialize(count: entries.count)
            windows.baseAddress?.deinitialize(count: windows.count)
        }
    }

    private static func makeStorage(
        _ allocation: ClassifiedPageAllocationToken
    ) -> Storage? {
        guard allocation.range.byteCount >= UInt64(nameOffset + nameByteCount),
              allocation.range.baseAddress <= UInt64(UInt.max),
              let base = UnsafeMutableRawPointer(
                  bitPattern: UInt(allocation.range.baseAddress)
              ), MemoryLayout<FileBrowserEntryRecord>.stride * entryCount
                <= windowOffset - entryOffset,
              MemoryLayout<UIWindowRecord>.stride * windowCount
                <= directoryNameOffset - windowOffset,
              directoryNameOffset + directoryNameByteCount <= typeaheadOffset,
              typeaheadOffset + typeaheadByteCount <= nameOffset
        else {
            return nil
        }
        let entryBase = (base + entryOffset).bindMemory(
            to: FileBrowserEntryRecord.self,
            capacity: entryCount
        )
        let windowBase = (base + windowOffset).bindMemory(
            to: UIWindowRecord.self,
            capacity: windowCount
        )
        entryBase.initialize(repeating: .vacant, count: entryCount)
        windowBase.initialize(repeating: .vacant, count: windowCount)
        return Storage(
            entries: UnsafeMutableBufferPointer(
                start: entryBase,
                count: entryCount
            ),
            windows: UnsafeMutableBufferPointer(
                start: windowBase,
                count: windowCount
            ),
            directoryName: UnsafeMutableRawBufferPointer(
                start: base + directoryNameOffset,
                count: directoryNameByteCount
            ),
            typeahead: UnsafeMutableRawBufferPointer(
                start: base + typeaheadOffset,
                count: typeaheadByteCount
            ),
            names: UnsafeMutableRawBufferPointer(
                start: base + nameOffset,
                count: nameByteCount
            )
        )
    }

    private static func allocate(
        pageCount: UInt64
    ) -> ClassifiedPageAllocationToken? {
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
        guard case .allocated(let allocation) = result else { return nil }
        return allocation
    }

    private static func pointer<Value>(
        in allocation: ClassifiedPageAllocationToken,
        to type: Value.Type
    ) -> UnsafeMutablePointer<Value>? {
        guard UInt64(MemoryLayout<Value>.stride) <= allocation.range.byteCount,
              allocation.range.baseAddress <= UInt64(UInt.max),
              allocation.range.baseAddress
                % UInt64(MemoryLayout<Value>.alignment) == 0,
              let base = UnsafeMutableRawPointer(
                  bitPattern: UInt(allocation.range.baseAddress)
              )
        else {
            return nil
        }
        return base.bindMemory(to: Value.self, capacity: 1)
    }

    private static func release(
        _ state: ClassifiedPageAllocationToken,
        _ backing: ClassifiedPageAllocationToken
    ) {
        _ = KernelMemoryRuntime.releaseClassifiedPages(backing)
        _ = KernelMemoryRuntime.releaseClassifiedPages(state)
    }
}
