private struct RetainedQEMUVirtIOInputDevice {
    let allocation: ClassifiedPageAllocationToken
    var device: VirtIOInputMMIODevice
    let capabilities: VirtIOInputCapabilities?
    var isPollable: Bool
    var didReportFault: Bool
    let next: UnsafeMutablePointer<RetainedQEMUVirtIOInputDevice>?
}

private nonisolated(unsafe) var qemuVirtIOInputActivationAttempted = false
private nonisolated(unsafe) var qemuVirtIOInputSerialBaseAddress: UInt = 0
private nonisolated(unsafe) var qemuVirtIOInputHead:
    UnsafeMutablePointer<RetainedQEMUVirtIOInputDevice>?
private nonisolated(unsafe) var qemuVirtIOInputQueueAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var qemuVirtIOInputQueue: InputEventQueue?
private nonisolated(unsafe) var qemuVirtIOInputActiveDeviceCount = 0
private nonisolated(unsafe) var qemuVirtIOInputLastDropCount: UInt64 = 0

private nonisolated(unsafe) var qemuVirtIOInputKeyboardDeviceID: UInt32 = 0
private nonisolated(unsafe) var qemuVirtIOInputPointerDeviceID: UInt32 = 0
private nonisolated(unsafe) var qemuVirtIOInputSawADown = false
private nonisolated(unsafe) var qemuVirtIOInputSawAUp = false
private nonisolated(unsafe) var qemuVirtIOInputPointerDeltaX: Int32 = 0
private nonisolated(unsafe) var qemuVirtIOInputPointerDeltaY: Int32 = 0
private nonisolated(unsafe) var qemuVirtIOInputSawPointerDelta = false
private nonisolated(unsafe) var qemuVirtIOInputSawLeftDown = false
private nonisolated(unsafe) var qemuVirtIOInputSawLeftUp = false
private nonisolated(unsafe) var qemuVirtIOInputWroteProof = false

/// QEMU-only ownership and polling policy around the transport-neutral
/// VirtIO-input device. Device records live in the unused tail of their own
/// allocator-owned page, allowing every discovered input candidate to remain
/// reachable without a heap or a fixed device-count table.
enum QEMUVirtIOInputRuntime {
    private static let maximumTransportCandidateCount = 64
    private static let retainedDeviceOffset: UInt64 = 3_072
    private static let maximumEventsPerDevicePass: UInt16 = 16
    private static let maximumDequeuesPerPass = 96

    static func activate(console: EarlyConsole, platform: Platform) {
        guard case .qemuVirt = platform.kind,
              platform.processorCount == 1,
              !qemuVirtIOInputActivationAttempted
        else {
            return
        }
        qemuVirtIOInputActivationAttempted = true
        guard platform.serial.baseAddress <= UInt64(UInt.max),
              hasModernCoherentInputCandidate(platform: platform)
        else {
            return
        }
        qemuVirtIOInputSerialBaseAddress = UInt(platform.serial.baseAddress)

        guard allocateCanonicalQueue() else {
            console.write("SWIFTOS:VIRTIO_INPUT_QUEUE_UNAVAILABLE\n")
            return
        }

        var inputOrdinal: UInt32 = 0
        var transportIndex = 0
        while transportIndex < maximumTransportCandidateCount,
              let resource = platform.virtioTransport(at: transportIndex) {
            defer { transportIndex += 1 }
            guard let transport = VirtIOMMIOTransport(resource: resource),
                  transport.hasVirtIOMagic,
                  transport.identity.version
                    == VirtIOMMIOTransport.modernVersion,
                  transport.identity.deviceID
                    == VirtIOInputMMIODevice.inputDeviceID
            else {
                continue
            }
            guard inputOrdinal < UInt32.max else {
                console.write("SWIFTOS:VIRTIO_INPUT_ID_EXHAUSTED\n")
                break
            }
            inputOrdinal += 1
            guard platform.virtioTransportIsDMACoherent(at: transportIndex)
            else {
                console.write("SWIFTOS:VIRTIO_INPUT_DMA_UNSUPPORTED\n")
                continue
            }
            activateCandidate(
                resource: resource,
                deviceID: InputDeviceID(rawValue: inputOrdinal),
                console: console
            )
        }

        guard qemuVirtIOInputActiveDeviceCount > 0 else {
            if let queueAllocation = qemuVirtIOInputQueueAllocation {
                if KernelMemoryRuntime.releaseClassifiedPages(queueAllocation)
                    == .released {
                    qemuVirtIOInputQueueAllocation = nil
                    qemuVirtIOInputQueue = nil
                } else {
                    console.write(
                        "SWIFTOS:VIRTIO_INPUT_QUEUE_RELEASE_FAILED\n"
                    )
                }
            }
            console.write("SWIFTOS:VIRTIO_INPUT_NONE_USABLE\n")
            return
        }
        console.write("SWIFTOS:VIRTIO_INPUT_SINGLE_CPU_POLLING\n")
        console.write("SWIFTOS:VIRTIO_INPUT_READY\n")
    }

    static func cooperativeServiceHook(
        for platform: Platform
    ) -> KernelMonitorServiceHook? {
        guard case .qemuVirt = platform.kind,
              platform.processorCount == 1,
              qemuVirtIOInputActiveDeviceCount > 0,
              qemuVirtIOInputQueue != nil
        else {
            return nil
        }
        return swiftOSServiceQEMUVirtIOInput
    }

    static func serviceOnce() {
        guard var queue = qemuVirtIOInputQueue else { return }
        var cursor = qemuVirtIOInputHead
        while let retained = cursor {
            let next = retained.pointee.next
            if retained.pointee.isPollable {
                let result = retained.pointee.device.poll(
                    timestampTicks: AArch64.counterValue,
                    maximumEvents: maximumEventsPerDevicePass,
                    into: &queue
                )
                if case .deviceFault = result {
                    retained.pointee.isPollable = false
                    if !retained.pointee.didReportFault {
                        runtimeConsole.write(
                            "SWIFTOS:VIRTIO_INPUT_DEVICE_FAULT\n"
                        )
                        retained.pointee.didReportFault = true
                    }
                }
            }
            cursor = next
        }

        drainCanonicalEvents(queue: &queue)
        let dropCount = queue.statistics.droppedEventCount
        if dropCount != qemuVirtIOInputLastDropCount {
            qemuVirtIOInputLastDropCount = dropCount
            runtimeConsole.write("SWIFTOS:VIRTIO_INPUT_QUEUE_LOSS\n")
        }
        qemuVirtIOInputQueue = queue
    }

    private static var runtimeConsole: EarlyConsole {
        EarlyConsole(
            uart: PL011(baseAddress: qemuVirtIOInputSerialBaseAddress)
        )
    }

    private static func hasModernCoherentInputCandidate(
        platform: Platform
    ) -> Bool {
        var index = 0
        while index < maximumTransportCandidateCount,
              let resource = platform.virtioTransport(at: index) {
            defer { index += 1 }
            guard platform.virtioTransportIsDMACoherent(at: index),
                  let transport = VirtIOMMIOTransport(resource: resource),
                  transport.hasVirtIOMagic,
                  transport.identity.version
                    == VirtIOMMIOTransport.modernVersion,
                  transport.identity.deviceID
                    == VirtIOInputMMIODevice.inputDeviceID
            else {
                continue
            }
            return true
        }
        return false
    }

    private static func allocateCanonicalQueue() -> Bool {
        let result = KernelMemoryRuntime.allocateClassifiedPages(
            ClassifiedPageAllocationConstraints(
                pageCount: 1,
                requiredCapabilities: .cpuAccessible,
                domainSelection: .preferred(
                    KernelMemoryRuntime.defaultSystemMemoryDomain,
                    fallback: .disallowed
                )
            )
        )
        guard case .allocated(let allocation) = result,
              allocation.range.baseAddress <= UInt64(UInt.max),
              allocation.range.byteCount <= UInt64(Int.max),
              let base = UnsafeMutableRawPointer(
                  bitPattern: UInt(allocation.range.baseAddress)
              ),
              let queue = InputEventQueue(
                  storage: UnsafeMutableRawBufferPointer(
                      start: base,
                      count: Int(allocation.range.byteCount)
                  )
              )
        else {
            if case .allocated(let allocation) = result {
                _ = KernelMemoryRuntime.releaseClassifiedPages(allocation)
            }
            return false
        }
        qemuVirtIOInputQueueAllocation = allocation
        qemuVirtIOInputQueue = queue
        return true
    }

    private static func activateCandidate(
        resource: DeviceResource,
        deviceID: InputDeviceID,
        console: EarlyConsole
    ) {
        let requiredCapabilities = PhysicalMemoryCapabilities.cpuAccessible
            .union(.deviceAccessible)
            .union(.cacheCoherent)
        let allocationResult = KernelMemoryRuntime.allocateClassifiedPages(
            ClassifiedPageAllocationConstraints(
                pageCount: VirtIOInputBootstrapMemory.pageCount,
                requiredCapabilities: requiredCapabilities,
                domainSelection: .preferred(
                    KernelMemoryRuntime.defaultSystemMemoryDomain,
                    fallback: .disallowed
                )
            )
        )
        guard case .allocated(let allocation) = allocationResult else {
            console.write("SWIFTOS:VIRTIO_INPUT_MEMORY_UNAVAILABLE\n")
            return
        }
        guard let workspace = VirtIOInputBootstrapMemory(
                  allocation: allocation,
                  deviceBaseAddress: allocation.range.baseAddress,
                  deviceAddressWidth: .bits64,
                  coherency: .hardwareCoherent
              ), var device = VirtIOInputMMIODevice(
                  resource: resource,
                  storage: workspace.storage,
                  deviceID: deviceID
              )
        else {
            _ = KernelMemoryRuntime.releaseClassifiedPages(allocation)
            console.write("SWIFTOS:VIRTIO_INPUT_MEMORY_INVALID\n")
            return
        }

        let initialization = device.initialize()
        switch initialization {
        case .ready(let capabilities):
            guard retain(
                      device: device,
                      allocation: allocation,
                      capabilities: capabilities,
                      isPollable: true
                  )
            else {
                // The eventq is published. This page cannot be returned even
                // if the CPU-side retained-record layout is unexpectedly too
                // large for its protected tail.
                console.write("SWIFTOS:VIRTIO_INPUT_RETAIN_FAILED\n")
                return
            }
            qemuVirtIOInputActiveDeviceCount += 1
            if capabilities.keyboard {
                console.write("SWIFTOS:VIRTIO_INPUT_KEYBOARD_ID=")
                console.writeHex(UInt64(deviceID.rawValue))
                console.write("\n")
            }
            if capabilities.relativePointer
                && capabilities.primaryPointerButton {
                console.write("SWIFTOS:VIRTIO_INPUT_POINTER_ID=")
                console.writeHex(UInt64(deviceID.rawValue))
                console.write("\n")
            }
        default:
            if device.hasPublishedQueue {
                _ = retain(
                    device: device,
                    allocation: allocation,
                    capabilities: device.capabilities,
                    isPollable: false
                )
            } else {
                _ = KernelMemoryRuntime.releaseClassifiedPages(allocation)
            }
            console.write("SWIFTOS:VIRTIO_INPUT_INIT_FAILED\n")
        }
    }

    private static func retain(
        device: VirtIOInputMMIODevice,
        allocation: ClassifiedPageAllocationToken,
        capabilities: VirtIOInputCapabilities?,
        isPollable: Bool
    ) -> Bool {
        let alignment = UInt64(
            MemoryLayout<RetainedQEMUVirtIOInputDevice>.alignment
        )
        let byteCount = UInt64(
            MemoryLayout<RetainedQEMUVirtIOInputDevice>.stride
        )
        guard alignment > 0,
              retainedDeviceOffset % alignment == 0,
              retainedDeviceOffset <= allocation.range.byteCount,
              byteCount <= allocation.range.byteCount - retainedDeviceOffset,
              allocation.range.baseAddress
                <= UInt64.max - retainedDeviceOffset,
              allocation.range.baseAddress + retainedDeviceOffset
                <= UInt64(UInt.max),
              let address = UnsafeMutableRawPointer(
                  bitPattern: UInt(
                      allocation.range.baseAddress + retainedDeviceOffset
                  )
              )
        else {
            return false
        }
        let retained = address.assumingMemoryBound(
            to: RetainedQEMUVirtIOInputDevice.self
        )
        retained.initialize(
            to: RetainedQEMUVirtIOInputDevice(
                allocation: allocation,
                device: device,
                capabilities: capabilities,
                isPollable: isPollable,
                didReportFault: false,
                next: qemuVirtIOInputHead
            )
        )
        qemuVirtIOInputHead = retained
        return true
    }

    private static func drainCanonicalEvents(queue: inout InputEventQueue) {
        var dequeued = 0
        while dequeued < maximumDequeuesPerPass {
            switch queue.dequeue() {
            case .event(let queued):
                observeCanonicalEvent(queued.event)
                dequeued += 1
            case .corruptRecordDiscarded:
                runtimeConsole.write("SWIFTOS:VIRTIO_INPUT_QUEUE_CORRUPT\n")
                dequeued += 1
            case .empty:
                return
            }
        }
    }

    /// Every proof marker is emitted from this post-dequeue boundary. The
    /// smoke therefore proves eventq DMA decoding, evdev translation, stable
    /// ABI encoding, and canonical queue decoding rather than QMP delivery
    /// alone.
    private static func observeCanonicalEvent(_ event: InputEvent) {
        if event.kind == .keyboardUsage,
           event.keyboardUsage == .keyboard(0x04) {
            if event.isPressed, !qemuVirtIOInputSawADown {
                qemuVirtIOInputKeyboardDeviceID = event.deviceID.rawValue
                qemuVirtIOInputSawADown = true
                runtimeConsole.write("SWIFTOS:VIRTIO_INPUT_A_DOWN\n")
            } else if !event.isPressed,
                      qemuVirtIOInputSawADown,
                      event.deviceID.rawValue
                        == qemuVirtIOInputKeyboardDeviceID,
                      !qemuVirtIOInputSawAUp {
                qemuVirtIOInputSawAUp = true
                runtimeConsole.write("SWIFTOS:VIRTIO_INPUT_A_UP\n")
            }
        } else if event.kind == .pointerMotion {
            if claimPointerDevice(event.deviceID.rawValue) {
                qemuVirtIOInputPointerDeltaX = addingWithoutOverflow(
                    qemuVirtIOInputPointerDeltaX,
                    event.value0
                )
                qemuVirtIOInputPointerDeltaY = addingWithoutOverflow(
                    qemuVirtIOInputPointerDeltaY,
                    event.value1
                )
                if !qemuVirtIOInputSawPointerDelta,
                   qemuVirtIOInputPointerDeltaX == 37,
                   qemuVirtIOInputPointerDeltaY == -19 {
                    qemuVirtIOInputSawPointerDelta = true
                    runtimeConsole.write(
                        "SWIFTOS:VIRTIO_INPUT_POINTER_DX_37_DY_NEG19\n"
                    )
                }
            }
        } else if event.kind == .pointerButton,
                  event.code == 1,
                  claimPointerDevice(event.deviceID.rawValue) {
            if event.isPressed, !qemuVirtIOInputSawLeftDown {
                qemuVirtIOInputSawLeftDown = true
                runtimeConsole.write("SWIFTOS:VIRTIO_INPUT_LEFT_DOWN\n")
            } else if !event.isPressed,
                      qemuVirtIOInputSawLeftDown,
                      !qemuVirtIOInputSawLeftUp {
                qemuVirtIOInputSawLeftUp = true
                runtimeConsole.write("SWIFTOS:VIRTIO_INPUT_LEFT_UP\n")
            }
        }

        if !qemuVirtIOInputWroteProof,
           qemuVirtIOInputSawADown,
           qemuVirtIOInputSawAUp,
           qemuVirtIOInputSawPointerDelta,
           qemuVirtIOInputSawLeftDown,
           qemuVirtIOInputSawLeftUp {
            qemuVirtIOInputWroteProof = true
            runtimeConsole.write("SWIFTOS:VIRTIO_INPUT_PROOF_OK\n")
        }
    }

    private static func claimPointerDevice(_ deviceID: UInt32) -> Bool {
        if qemuVirtIOInputPointerDeviceID == 0 {
            qemuVirtIOInputPointerDeviceID = deviceID
        }
        return qemuVirtIOInputPointerDeviceID == deviceID
    }

    private static func addingWithoutOverflow(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? lhs : sum
    }
}

@_cdecl("swiftos_service_qemu_virtio_input")
func swiftOSServiceQEMUVirtIOInput() {
    QEMUVirtIOInputRuntime.serviceOnce()
}
