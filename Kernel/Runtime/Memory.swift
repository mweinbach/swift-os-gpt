@_cdecl("memcpy")
@_optimize(none)
func swiftOSMemcpy(
    _ destination: UnsafeMutableRawPointer?,
    _ source: UnsafeRawPointer?,
    _ count: UInt
) -> UnsafeMutableRawPointer? {
    guard let destination, let source else {
        return destination
    }
    var index: UInt = 0
    while index < count {
        let byte = source.advanced(by: Int(index)).load(as: UInt8.self)
        destination.advanced(by: Int(index)).storeBytes(of: byte, as: UInt8.self)
        index += 1
    }
    return destination
}

@_cdecl("memmove")
@_optimize(none)
func swiftOSMemmove(
    _ destination: UnsafeMutableRawPointer?,
    _ source: UnsafeRawPointer?,
    _ count: UInt
) -> UnsafeMutableRawPointer? {
    guard let destination, let source else {
        return destination
    }
    if UInt(bitPattern: destination) <= UInt(bitPattern: source) {
        return swiftOSMemcpy(destination, source, count)
    }

    var index = count
    while index > 0 {
        index -= 1
        let byte = source.advanced(by: Int(index)).load(as: UInt8.self)
        destination.advanced(by: Int(index)).storeBytes(of: byte, as: UInt8.self)
    }
    return destination
}

@_cdecl("memset")
@_optimize(none)
func swiftOSMemset(
    _ destination: UnsafeMutableRawPointer?,
    _ value: Int32,
    _ count: UInt
) -> UnsafeMutableRawPointer? {
    guard let destination else {
        return nil
    }
    let byte = UInt8(truncatingIfNeeded: value)
    var index: UInt = 0
    while index < count {
        destination.advanced(by: Int(index)).storeBytes(of: byte, as: UInt8.self)
        index += 1
    }
    return destination
}

