/// Device-neutral scalar and resource types used by SwiftOS's GPU command IR.
///
/// These values deliberately describe rendering intent rather than a VirtIO,
/// virgl, Vulkan, or V3D packet layout. A hardware backend translates them to
/// its own command stream after validating the referenced resources.

struct GPUFixed16: Equatable, Comparable {
    static let fractionalBitCount: UInt32 = 16
    static let unitRawValue: Int32 = 1 << fractionalBitCount

    static let zero = GPUFixed16(rawValue: 0)
    static let one = GPUFixed16(rawValue: unitRawValue)

    let rawValue: Int32

    init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Creates an exact integral 16.16 value when it fits the representation.
    init?(whole value: Int) {
        let minimumWhole = Int(Int32.min) / Int(Self.unitRawValue)
        let maximumWhole = Int(Int32.max) / Int(Self.unitRawValue)
        guard value >= minimumWhole, value <= maximumWhole else {
            return nil
        }
        rawValue = Int32(value) * Self.unitRawValue
    }

    static func < (lhs: GPUFixed16, rhs: GPUFixed16) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A half-open rectangle in subpixel 16.16 local coordinates.
struct GPUFixedRectangle: Equatable {
    let x: GPUFixed16
    let y: GPUFixed16
    let width: GPUFixed16
    let height: GPUFixed16

    init?(
        x: GPUFixed16,
        y: GPUFixed16,
        width: GPUFixed16,
        height: GPUFixed16
    ) {
        guard width.rawValue > 0, height.rawValue > 0 else {
            return nil
        }
        let endX = x.rawValue.addingReportingOverflow(width.rawValue)
        let endY = y.rawValue.addingReportingOverflow(height.rawValue)
        guard !endX.overflow, !endY.overflow else {
            return nil
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

struct GPUPixelExtent: Equatable {
    let width: UInt32
    let height: UInt32

    init?(width: UInt32, height: UInt32) {
        guard width != 0, height != 0 else { return nil }
        self.width = width
        self.height = height
    }
}

/// Integer framebuffer scissor coordinates. The rectangle is always nonempty
/// and representable; a recorder additionally checks it against its target.
struct GPUScissorRectangle: Equatable {
    let x: UInt32
    let y: UInt32
    let width: UInt32
    let height: UInt32

    init?(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        guard width != 0, height != 0 else { return nil }
        let endX = x.addingReportingOverflow(width)
        let endY = y.addingReportingOverflow(height)
        guard !endX.overflow, !endY.overflow else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var endX: UInt32 { x + width }
    var endY: UInt32 { y + height }
}

enum GPUScissorState: Equatable {
    /// Use the complete render target.
    case disabled
    /// Intersect rasterization with the supplied target-space rectangle.
    case rectangle(GPUScissorRectangle)
}

/// Normalized, premultiplied linear-sRGB color. Sixteen-bit channels keep the
/// IR independent from the eventual render-target precision.
struct GPUPremultipliedColor: Equatable {
    let red: UInt16
    let green: UInt16
    let blue: UInt16
    let alpha: UInt16

    init?(red: UInt16, green: UInt16, blue: UInt16, alpha: UInt16) {
        guard red <= alpha, green <= alpha, blue <= alpha else {
            return nil
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let transparent = GPUPremultipliedColor(
        uncheckedRed: 0,
        green: 0,
        blue: 0,
        alpha: 0
    )

    static let opaqueBlack = GPUPremultipliedColor(
        uncheckedRed: 0,
        green: 0,
        blue: 0,
        alpha: .max
    )

    static let opaqueWhite = GPUPremultipliedColor(
        uncheckedRed: .max,
        green: .max,
        blue: .max,
        alpha: .max
    )

    private init(
        uncheckedRed red: UInt16,
        green: UInt16,
        blue: UInt16,
        alpha: UInt16
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// A 2D affine transform in column-vector form:
///
///     | m11 m21 translationX |
///     | m12 m22 translationY |
///     |  0   0        1       |
///
/// Fixed-point storage gives the kernel deterministic subpixel animation
/// without requiring floating-point execution before a backend encodes it.
struct GPUTransform2D: Equatable {
    let m11: GPUFixed16
    let m12: GPUFixed16
    let m21: GPUFixed16
    let m22: GPUFixed16
    let translationX: GPUFixed16
    let translationY: GPUFixed16

    init(
        m11: GPUFixed16,
        m12: GPUFixed16,
        m21: GPUFixed16,
        m22: GPUFixed16,
        translationX: GPUFixed16,
        translationY: GPUFixed16
    ) {
        self.m11 = m11
        self.m12 = m12
        self.m21 = m21
        self.m22 = m22
        self.translationX = translationX
        self.translationY = translationY
    }

    static let identity = GPUTransform2D(
        m11: .one,
        m12: .zero,
        m21: .zero,
        m22: .one,
        translationX: .zero,
        translationY: .zero
    )

    static func translation(
        x: GPUFixed16,
        y: GPUFixed16
    ) -> GPUTransform2D {
        GPUTransform2D(
            m11: .one,
            m12: .zero,
            m21: .zero,
            m22: .one,
            translationX: x,
            translationY: y
        )
    }
}

/// Normalized unsigned texture coordinates use Q16 where 65,536 is exactly 1.
struct GPUTextureRegion: Equatable {
    static let unitRawValue: UInt32 = 1 << 16

    let minimumU: UInt32
    let minimumV: UInt32
    let maximumU: UInt32
    let maximumV: UInt32

    init?(
        minimumU: UInt32,
        minimumV: UInt32,
        maximumU: UInt32,
        maximumV: UInt32
    ) {
        guard maximumU <= Self.unitRawValue,
              maximumV <= Self.unitRawValue,
              minimumU < maximumU,
              minimumV < maximumV
        else {
            return nil
        }
        self.minimumU = minimumU
        self.minimumV = minimumV
        self.maximumU = maximumU
        self.maximumV = maximumV
    }

    static let complete = GPUTextureRegion(
        uncheckedMinimumU: 0,
        minimumV: 0,
        maximumU: unitRawValue,
        maximumV: unitRawValue
    )

    private init(
        uncheckedMinimumU minimumU: UInt32,
        minimumV: UInt32,
        maximumU: UInt32,
        maximumV: UInt32
    ) {
        self.minimumU = minimumU
        self.minimumV = minimumV
        self.maximumU = maximumU
        self.maximumV = maximumV
    }
}

struct GPURenderTargetID: Equatable {
    let rawValue: UInt32

    init?(rawValue: UInt32) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

struct GPUTextureID: Equatable {
    let rawValue: UInt32

    init?(rawValue: UInt32) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

struct GPUCommandBufferID: Equatable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

struct GPUQueueID: Equatable, Comparable {
    let rawValue: UInt16

    init?(rawValue: UInt16) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }

    static func < (lhs: GPUQueueID, rhs: GPUQueueID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
