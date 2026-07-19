enum DisplayBackendKind: UInt8, Equatable {
    case virtIOGPU
    case platformFramebuffer
    case firmwareRAMFramebuffer
    /// A kernel-owned render target with no physical scanout. This keeps the
    /// compositor and remote-display transports usable on headless machines.
    case memorySurface

    fileprivate var automaticPriority: UInt8 {
        switch self {
        case .virtIOGPU:
            return 0
        case .platformFramebuffer:
            return 1
        case .firmwareRAMFramebuffer:
            return 2
        case .memorySurface:
            return 3
        }
    }
}

// This closed value policy avoids protocol existentials and heap-backed backend
// collections in the freestanding kernel. Drivers can be represented by their
// enum tag and selected with a fixed switch.
enum DisplayBackendSelectionPolicy: Equatable {
    case automatic
    case prefer(DisplayBackendKind)
    case require(DisplayBackendKind)

    func priority(for backend: DisplayBackendKind) -> UInt8? {
        switch self {
        case .automatic:
            return backend.automaticPriority
        case .prefer(let preferred):
            if backend == preferred {
                return 0
            }
            return backend.automaticPriority + 1
        case .require(let required):
            return backend == required ? 0 : nil
        }
    }
}
