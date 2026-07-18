enum GPUCommandRecordRejection: Equatable {
    case recorderSealed
    case capacityExhausted
    case renderPassAlreadyActive
    case renderPassNotActive
    case scissorOutsideRenderTarget
}

enum GPUCommandRecordResult: Equatable {
    case recorded(index: Int)
    case rejected(GPUCommandRecordRejection)
}

enum GPUCommandBufferSealRejection: Equatable {
    case alreadySealed
    case renderPassStillActive
    case noCompletedRenderPass
}

enum GPUCommandBufferSealResult {
    case sealed(GPURenderCommandBuffer)
    case rejected(GPUCommandBufferSealRejection)
}

/// Immutable, allocation-free command stream handed to a hardware backend.
/// The backend is expected to translate commands in exact index order.
struct GPURenderCommandBuffer {
    let id: GPUCommandBufferID
    let commandCount: Int
    let renderPassCount: Int

    private let storage: GPUCommandStorage

    fileprivate init(
        id: GPUCommandBufferID,
        commandCount: Int,
        renderPassCount: Int,
        storage: GPUCommandStorage
    ) {
        self.id = id
        self.commandCount = commandCount
        self.renderPassCount = renderPassCount
        self.storage = storage
    }

    func command(at index: Int) -> GPURenderCommand? {
        guard index >= 0, index < commandCount else { return nil }
        return storage.command(at: index)
    }
}

/// Stateful builder that enforces render-pass ordering before a backend sees
/// the stream. Its complete backing store is inline and copy-safe.
struct GPUCommandRecorder {
    static let maximumCommandCount = 32

    let id: GPUCommandBufferID
    let capacity: Int
    private(set) var commandCount: Int = 0
    private(set) var completedRenderPassCount: Int = 0
    private(set) var isInsideRenderPass: Bool = false
    private(set) var isSealed: Bool = false

    private var activeExtent: GPUPixelExtent?
    private var storage = GPUCommandStorage()

    init?(
        id: GPUCommandBufferID,
        capacity: Int = maximumCommandCount
    ) {
        guard capacity > 0, capacity <= Self.maximumCommandCount else {
            return nil
        }
        self.id = id
        self.capacity = capacity
    }

    mutating func record(_ command: GPURenderCommand) -> GPUCommandRecordResult {
        guard !isSealed else { return .rejected(.recorderSealed) }

        let nextExtent: GPUPixelExtent?
        switch command {
        case .beginRenderPass(let descriptor):
            guard !isInsideRenderPass else {
                return .rejected(.renderPassAlreadyActive)
            }
            nextExtent = descriptor.extent

        case .endRenderPass:
            guard isInsideRenderPass else {
                return .rejected(.renderPassNotActive)
            }
            nextExtent = nil

        case .setScissor(let state):
            guard isInsideRenderPass, let extent = activeExtent else {
                return .rejected(.renderPassNotActive)
            }
            if case .rectangle(let rectangle) = state,
               !Self.scissor(rectangle, fits: extent) {
                return .rejected(.scissorOutsideRenderTarget)
            }
            nextExtent = extent

        case .setTransform, .drawQuad, .drawGlyph:
            guard isInsideRenderPass, let extent = activeExtent else {
                return .rejected(.renderPassNotActive)
            }
            nextExtent = extent
        }

        guard commandCount < capacity else {
            return .rejected(.capacityExhausted)
        }

        let recordedIndex = commandCount
        storage.set(command, at: recordedIndex)
        commandCount += 1

        switch command {
        case .beginRenderPass:
            isInsideRenderPass = true
            activeExtent = nextExtent
        case .endRenderPass:
            isInsideRenderPass = false
            activeExtent = nil
            completedRenderPassCount += 1
        case .setScissor, .setTransform, .drawQuad, .drawGlyph:
            break
        }
        return .recorded(index: recordedIndex)
    }

    mutating func seal() -> GPUCommandBufferSealResult {
        guard !isSealed else { return .rejected(.alreadySealed) }
        guard !isInsideRenderPass else {
            return .rejected(.renderPassStillActive)
        }
        guard completedRenderPassCount > 0 else {
            return .rejected(.noCompletedRenderPass)
        }

        isSealed = true
        return .sealed(
            GPURenderCommandBuffer(
                id: id,
                commandCount: commandCount,
                renderPassCount: completedRenderPassCount,
                storage: storage
            )
        )
    }

    private static func scissor(
        _ rectangle: GPUScissorRectangle,
        fits extent: GPUPixelExtent
    ) -> Bool {
        rectangle.endX <= extent.width && rectangle.endY <= extent.height
    }
}

/// Eight command values form one storage page so the 32-entry buffer remains
/// readable without a heap-backed Array or an unsafe self-referential pointer.
private struct GPUCommandPage {
    private var command0 = GPURenderCommand.endRenderPass
    private var command1 = GPURenderCommand.endRenderPass
    private var command2 = GPURenderCommand.endRenderPass
    private var command3 = GPURenderCommand.endRenderPass
    private var command4 = GPURenderCommand.endRenderPass
    private var command5 = GPURenderCommand.endRenderPass
    private var command6 = GPURenderCommand.endRenderPass
    private var command7 = GPURenderCommand.endRenderPass

    func command(at index: Int) -> GPURenderCommand {
        switch index {
        case 0: return command0
        case 1: return command1
        case 2: return command2
        case 3: return command3
        case 4: return command4
        case 5: return command5
        case 6: return command6
        default: return command7
        }
    }

    mutating func set(_ command: GPURenderCommand, at index: Int) {
        switch index {
        case 0: command0 = command
        case 1: command1 = command
        case 2: command2 = command
        case 3: command3 = command
        case 4: command4 = command
        case 5: command5 = command
        case 6: command6 = command
        default: command7 = command
        }
    }
}

private struct GPUCommandStorage {
    private var page0 = GPUCommandPage()
    private var page1 = GPUCommandPage()
    private var page2 = GPUCommandPage()
    private var page3 = GPUCommandPage()

    func command(at index: Int) -> GPURenderCommand {
        let slot = index & 7
        switch index >> 3 {
        case 0: return page0.command(at: slot)
        case 1: return page1.command(at: slot)
        case 2: return page2.command(at: slot)
        default: return page3.command(at: slot)
        }
    }

    mutating func set(_ command: GPURenderCommand, at index: Int) {
        let slot = index & 7
        switch index >> 3 {
        case 0: page0.set(command, at: slot)
        case 1: page1.set(command, at: slot)
        case 2: page2.set(command, at: slot)
        default: page3.set(command, at: slot)
        }
    }
}
