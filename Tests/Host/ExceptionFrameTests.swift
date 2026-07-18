@main
struct ExceptionFrameTests {
    static func main() {
        expect(
            MemoryLayout<AArch64SIMDRegister>.size == 16,
            "SIMD register size"
        )
        expect(
            MemoryLayout<AArch64ExceptionFrame>.size
                == AArch64ExceptionFrame.byteCount,
            "exception frame size"
        )
        expect(offset(of: \AArch64ExceptionFrame.q0) == 0, "q0 offset")
        expect(offset(of: \AArch64ExceptionFrame.q31) == 496, "q31 offset")
        expect(
            offset(of: \AArch64ExceptionFrame.floatingPointControl) == 512,
            "FPCR offset"
        )
        expect(
            offset(of: \AArch64ExceptionFrame.floatingPointStatus) == 520,
            "FPSR offset"
        )
        expect(
            offset(of: \AArch64ExceptionFrame.x0)
                == AArch64ExceptionFrame.generalPurposeRegisterOffset,
            "x0 offset"
        )
        expect(offset(of: \AArch64ExceptionFrame.x30) == 768, "x30 offset")
        expect(
            offset(of: \AArch64ExceptionFrame.vectorSlot)
                == AArch64ExceptionFrame.vectorSlotOffset,
            "vector offset"
        )
        expect(
            offset(of: \AArch64ExceptionFrame.exceptionLink)
                == AArch64ExceptionFrame.exceptionLinkOffset,
            "ELR offset"
        )
        expect(
            offset(of: \AArch64ExceptionFrame.savedProgramStatus)
                == AArch64ExceptionFrame.savedProgramStatusOffset,
            "SPSR offset"
        )
        expect(offset(of: \AArch64ExceptionFrame.syndrome) == 800, "ESR offset")
        expect(
            offset(of: \AArch64ExceptionFrame.faultAddress) == 808,
            "FAR offset"
        )
        expect(
            offset(of: \AArch64ExceptionFrame.stackPointerEL0)
                == AArch64ExceptionFrame.stackPointerEL0Offset,
            "SP_EL0 offset"
        )
        expect(
            offset(of: \AArch64ExceptionFrame.threadPointerEL0)
                == AArch64ExceptionFrame.threadPointerEL0Offset,
            "TPIDR_EL0 offset"
        )
        print("exception frame host tests: 15 passed")
    }

    private static func offset<Value>(
        of keyPath: KeyPath<AArch64ExceptionFrame, Value>
    ) -> Int {
        MemoryLayout<AArch64ExceptionFrame>.offset(of: keyPath) ?? -1
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}
