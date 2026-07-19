/// Allocation-free path and file-name contracts for the virtual filesystem.
///
/// Paths are case-sensitive UTF-8 byte strings. The kernel deliberately does
/// not perform locale-sensitive or Unicode-equivalence folding: two different
/// valid UTF-8 encodings remain two different names. Callers own all borrowed
/// buffers for the lifetime of the returned views.
enum VFSPathLimits {
    static let maximumPathByteCount = 1_024
    static let maximumComponentByteCount = 255
    static let maximumComponentCount = 64
}

enum VFSPathFailure: Equatable {
    case empty
    case notAbsolute
    case inputTooLong
    case outputTooSmall(requiredByteCount: Int)
    case tooManyComponents
    case componentTooLong(componentIndex: Int)
    case traversalComponent(componentIndex: Int)
    case separatorInName(offset: Int)
    case nulByte(offset: Int)
    case controlByte(offset: Int)
    case invalidUTF8(offset: Int)
}

struct VFSNameView {
    private let bytes: UnsafePointer<UInt8>
    let byteCount: Int

    fileprivate init(bytes: UnsafePointer<UInt8>, byteCount: Int) {
        self.bytes = bytes
        self.byteCount = byteCount
    }

    func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < byteCount else { return nil }
        return bytes[index]
    }

    func isBytewiseEqual(to other: VFSNameView) -> Bool {
        guard byteCount == other.byteCount else { return false }
        var index = 0
        while index < byteCount {
            if bytes[index] != other.bytes[index] { return false }
            index += 1
        }
        return true
    }
}

enum VFSNameValidationResult {
    case name(VFSNameView)
    case failure(VFSPathFailure)
}

enum VFSNameValidator {
    static func validate(_ input: UnsafeRawBufferPointer) -> VFSNameValidationResult {
        guard input.count != 0 else { return .failure(.empty) }
        guard input.count <= VFSPathLimits.maximumComponentByteCount else {
            return .failure(.componentTooLong(componentIndex: 0))
        }
        guard let base = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return .failure(.empty)
        }
        if input.count == 1, base[0] == 0x2e {
            return .failure(.traversalComponent(componentIndex: 0))
        }
        if input.count == 2, base[0] == 0x2e, base[1] == 0x2e {
            return .failure(.traversalComponent(componentIndex: 0))
        }
        var index = 0
        while index < input.count {
            let byte = base[index]
            if byte == 0 { return .failure(.nulByte(offset: index)) }
            if byte == 0x2f {
                return .failure(.separatorInName(offset: index))
            }
            if byte < 0x20 || byte == 0x7f {
                return .failure(.controlByte(offset: index))
            }
            index += 1
        }
        if let invalidOffset = VFSUTF8.firstInvalidOffset(base, count: input.count) {
            return .failure(.invalidUTF8(offset: invalidOffset))
        }
        return .name(VFSNameView(bytes: base, byteCount: input.count))
    }
}

struct VFSCanonicalPath {
    private let bytes: UnsafePointer<UInt8>
    let byteCount: Int
    let componentCount: Int

    fileprivate init(
        bytes: UnsafePointer<UInt8>,
        byteCount: Int,
        componentCount: Int
    ) {
        self.bytes = bytes
        self.byteCount = byteCount
        self.componentCount = componentCount
    }

    var isRoot: Bool { byteCount == 1 }

    func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < byteCount else { return nil }
        return bytes[index]
    }

    func component(at requestedIndex: Int) -> VFSNameView? {
        guard requestedIndex >= 0, requestedIndex < componentCount else {
            return nil
        }
        var componentIndex = 0
        var start = 1
        while start < byteCount {
            var end = start
            while end < byteCount, bytes[end] != 0x2f { end += 1 }
            if componentIndex == requestedIndex {
                return VFSNameView(bytes: bytes + start, byteCount: end - start)
            }
            componentIndex += 1
            start = end + 1
        }
        return nil
    }

    func isBytewiseEqual(to other: VFSCanonicalPath) -> Bool {
        guard byteCount == other.byteCount else { return false }
        return sharesBytes(with: other, through: byteCount)
    }

    /// Returns true only for a complete-component prefix. `/Users` therefore
    /// matches `/Users/alice`, but not `/Users-old`.
    func hasMountPrefix(_ prefix: VFSCanonicalPath) -> Bool {
        if prefix.isRoot { return true }
        guard byteCount >= prefix.byteCount,
              sharesBytes(with: prefix, through: prefix.byteCount)
        else { return false }
        return byteCount == prefix.byteCount || bytes[prefix.byteCount] == 0x2f
    }

    var borrowedBaseAddress: UnsafePointer<UInt8> { bytes }

    private func sharesBytes(
        with other: VFSCanonicalPath,
        through count: Int
    ) -> Bool {
        var index = 0
        while index < count {
            if bytes[index] != other.bytes[index] { return false }
            index += 1
        }
        return true
    }
}

enum VFSPathNormalizationResult {
    case path(VFSCanonicalPath)
    case failure(VFSPathFailure)
}

enum VFSPathNormalizer {
    /// Produces one canonical absolute representation. Repeated separators and
    /// a trailing separator are removed. `.` and `..` are rejected rather than
    /// resolved, so a security decision never depends on path traversal.
    static func normalize(
        _ input: UnsafeRawBufferPointer,
        into output: UnsafeMutableRawBufferPointer
    ) -> VFSPathNormalizationResult {
        guard input.count != 0 else { return .failure(.empty) }
        guard input.count <= VFSPathLimits.maximumPathByteCount else {
            return .failure(.inputTooLong)
        }
        guard input[0] == 0x2f else { return .failure(.notAbsolute) }
        guard output.count != 0,
              let outputBase = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
        else { return .failure(.outputTooSmall(requiredByteCount: 1)) }

        outputBase[0] = 0x2f
        var outputCount = 1
        var componentCount = 0
        var inputIndex = 1

        while inputIndex < input.count {
            while inputIndex < input.count, input[inputIndex] == 0x2f {
                inputIndex += 1
            }
            if inputIndex == input.count { break }
            let componentStart = inputIndex
            while inputIndex < input.count, input[inputIndex] != 0x2f {
                inputIndex += 1
            }
            let componentByteCount = inputIndex - componentStart
            guard componentByteCount <= VFSPathLimits.maximumComponentByteCount else {
                return .failure(.componentTooLong(componentIndex: componentCount))
            }
            guard componentCount < VFSPathLimits.maximumComponentCount else {
                return .failure(.tooManyComponents)
            }

            let componentPointer = input.baseAddress!
                .advanced(by: componentStart)
                .assumingMemoryBound(to: UInt8.self)
            let componentBytes = UnsafeRawBufferPointer(
                start: componentPointer,
                count: componentByteCount
            )
            switch VFSNameValidator.validate(componentBytes) {
            case .name:
                break
            case .failure(let failure):
                return .failure(
                    pathFailure(
                        failure,
                        componentIndex: componentCount,
                        inputOffset: componentStart
                    )
                )
            }

            let separatorByteCount = outputCount == 1 ? 0 : 1
            let required = outputCount + separatorByteCount + componentByteCount
            guard required <= output.count,
                  required <= VFSPathLimits.maximumPathByteCount
            else { return .failure(.outputTooSmall(requiredByteCount: required)) }
            if separatorByteCount != 0 {
                outputBase[outputCount] = 0x2f
                outputCount += 1
            }
            var componentOffset = 0
            while componentOffset < componentByteCount {
                outputBase[outputCount] = componentPointer[componentOffset]
                outputCount += 1
                componentOffset += 1
            }
            componentCount += 1
        }

        return .path(
            VFSCanonicalPath(
                bytes: UnsafePointer(outputBase),
                byteCount: outputCount,
                componentCount: componentCount
            )
        )
    }

    private static func pathFailure(
        _ failure: VFSPathFailure,
        componentIndex: Int,
        inputOffset: Int
    ) -> VFSPathFailure {
        switch failure {
        case .traversalComponent:
            return .traversalComponent(componentIndex: componentIndex)
        case .nulByte(let offset):
            return .nulByte(offset: inputOffset + offset)
        case .controlByte(let offset):
            return .controlByte(offset: inputOffset + offset)
        case .invalidUTF8(let offset):
            return .invalidUTF8(offset: inputOffset + offset)
        case .componentTooLong:
            return .componentTooLong(componentIndex: componentIndex)
        default:
            return failure
        }
    }
}

private enum VFSUTF8 {
    /// Strict UTF-8 validation rejects overlong sequences, surrogate scalars,
    /// truncated input, and values above U+10FFFF.
    static func firstInvalidOffset(
        _ bytes: UnsafePointer<UInt8>,
        count: Int
    ) -> Int? {
        var index = 0
        while index < count {
            let first = bytes[index]
            if first < 0x80 {
                index += 1
                continue
            }

            let length: Int
            var minimum: UInt32
            var scalar: UInt32
            if first >= 0xc2, first <= 0xdf {
                length = 2
                minimum = 0x80
                scalar = UInt32(first & 0x1f)
            } else if first >= 0xe0, first <= 0xef {
                length = 3
                minimum = 0x800
                scalar = UInt32(first & 0x0f)
            } else if first >= 0xf0, first <= 0xf4 {
                length = 4
                minimum = 0x1_0000
                scalar = UInt32(first & 0x07)
            } else {
                return index
            }
            guard index <= count - length else { return index }
            var continuation = 1
            while continuation < length {
                let next = bytes[index + continuation]
                guard next & 0xc0 == 0x80 else {
                    return index + continuation
                }
                scalar = scalar << 6 | UInt32(next & 0x3f)
                continuation += 1
            }
            if scalar < minimum || scalar > 0x10_ffff
                || (scalar >= 0xd800 && scalar <= 0xdfff) {
                return index
            }
            index += length
        }
        return nil
    }
}
