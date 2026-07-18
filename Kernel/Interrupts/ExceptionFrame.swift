@frozen
public struct AArch64SIMDRegister {
    public var low: UInt64
    public var high: UInt64
}

/// Complete register image shared by the AArch64 exception veneers and Swift.
///
/// This type is frozen because its byte layout is part of the assembly ABI.
/// Keep `Tests/Host/ExceptionFrameTests.swift` synchronized with any change.
@frozen
public struct AArch64ExceptionFrame {
    public static let byteCount = 832
    public static let generalPurposeRegisterOffset = 528
    public static let vectorSlotOffset = 776
    public static let exceptionLinkOffset = 784
    public static let savedProgramStatusOffset = 792
    public static let stackPointerEL0Offset = 816
    public static let threadPointerEL0Offset = 824

    public var q0: AArch64SIMDRegister
    public var q1: AArch64SIMDRegister
    public var q2: AArch64SIMDRegister
    public var q3: AArch64SIMDRegister
    public var q4: AArch64SIMDRegister
    public var q5: AArch64SIMDRegister
    public var q6: AArch64SIMDRegister
    public var q7: AArch64SIMDRegister
    public var q8: AArch64SIMDRegister
    public var q9: AArch64SIMDRegister
    public var q10: AArch64SIMDRegister
    public var q11: AArch64SIMDRegister
    public var q12: AArch64SIMDRegister
    public var q13: AArch64SIMDRegister
    public var q14: AArch64SIMDRegister
    public var q15: AArch64SIMDRegister
    public var q16: AArch64SIMDRegister
    public var q17: AArch64SIMDRegister
    public var q18: AArch64SIMDRegister
    public var q19: AArch64SIMDRegister
    public var q20: AArch64SIMDRegister
    public var q21: AArch64SIMDRegister
    public var q22: AArch64SIMDRegister
    public var q23: AArch64SIMDRegister
    public var q24: AArch64SIMDRegister
    public var q25: AArch64SIMDRegister
    public var q26: AArch64SIMDRegister
    public var q27: AArch64SIMDRegister
    public var q28: AArch64SIMDRegister
    public var q29: AArch64SIMDRegister
    public var q30: AArch64SIMDRegister
    public var q31: AArch64SIMDRegister
    public var floatingPointControl: UInt64
    public var floatingPointStatus: UInt64

    public var x0: UInt64
    public var x1: UInt64
    public var x2: UInt64
    public var x3: UInt64
    public var x4: UInt64
    public var x5: UInt64
    public var x6: UInt64
    public var x7: UInt64
    public var x8: UInt64
    public var x9: UInt64
    public var x10: UInt64
    public var x11: UInt64
    public var x12: UInt64
    public var x13: UInt64
    public var x14: UInt64
    public var x15: UInt64
    public var x16: UInt64
    public var x17: UInt64
    public var x18: UInt64
    public var x19: UInt64
    public var x20: UInt64
    public var x21: UInt64
    public var x22: UInt64
    public var x23: UInt64
    public var x24: UInt64
    public var x25: UInt64
    public var x26: UInt64
    public var x27: UInt64
    public var x28: UInt64
    public var x29: UInt64
    public var x30: UInt64

    /// Slot in the architectural 16-entry vector table.
    public var vectorSlot: UInt64
    public var exceptionLink: UInt64
    public var savedProgramStatus: UInt64
    public var syndrome: UInt64
    public var faultAddress: UInt64
    public var stackPointerEL0: UInt64
    public var threadPointerEL0: UInt64
}

enum AArch64ExceptionKind: UInt64 {
    case synchronous = 0
    case irq = 1
    case fiq = 2
    case systemError = 3
}

extension AArch64ExceptionFrame {
    var exceptionKind: AArch64ExceptionKind? {
        AArch64ExceptionKind(rawValue: vectorSlot & 3)
    }

    var cameFromLowerExceptionLevel: Bool {
        vectorSlot >= 8
    }
}
