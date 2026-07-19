enum EL0FileSystemSystemCallDisposition: Equatable {
    case notFromEL0
    case notSupervisorCall
    case unsupportedSystemCall
    case handled(FileSystemStatus)
}

/// Host-testable bridge from the saved AArch64 SVC frame into one process's
/// service. Runtime installation is deliberately separate: the current EL0
/// workload has no provider registry or mapped filesystem request arena yet.
enum EL0FileSystemExceptionDispatcher {
    private static let supervisorCall64ExceptionClass: UInt64 = 0x15
    private static let exceptionClassShift: UInt64 = 26
    private static let exceptionClassMask: UInt64 = 0x3f

    static func dispatch<Backend: VFSFileServiceBackend>(
        frame: UnsafeMutablePointer<AArch64ExceptionFrame>,
        currentTaskIdentifier: UInt64,
        service: inout EL0ProcessFileService<Backend>,
        userMemory: EL0UserMemoryMap
    ) -> EL0FileSystemSystemCallDisposition {
        guard frame.pointee.exceptionKind == .synchronous,
              frame.pointee.cameFromLowerExceptionLevel
        else { return .notFromEL0 }

        let exceptionClass =
            frame.pointee.syndrome >> exceptionClassShift
                & exceptionClassMask
        guard exceptionClass == supervisorCall64ExceptionClass else {
            return .notSupervisorCall
        }
        guard frame.pointee.x8 == FileSystemSyscallABI.systemCallNumber else {
            return .unsupportedSystemCall
        }

        let dispatchResult = service.dispatch(
            requestAddress: frame.pointee.x0,
            requestByteCount: frame.pointee.x1,
            resultAddress: frame.pointee.x2,
            currentTaskIdentifier: currentTaskIdentifier,
            userMemory: userMemory
        )
        frame.pointee.x0 = dispatchResult.status.registerValue
        return .handled(dispatchResult.status)
    }
}
