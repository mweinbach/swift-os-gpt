enum ShellCommand: UInt8, Equatable {
    case empty
    case help
    case uname
    case status
    case clear
    case about
    case uptime
    case unknown

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> ShellCommand {
        if bytes.isEmpty { return .empty }
        if equals(bytes, "HELP") { return .help }
        if equals(bytes, "UNAME") { return .uname }
        if equals(bytes, "STATUS") { return .status }
        if equals(bytes, "CLEAR") { return .clear }
        if equals(bytes, "ABOUT") { return .about }
        if equals(bytes, "UPTIME") { return .uptime }
        return .unknown
    }

    private static func equals(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ expected: StaticString
    ) -> Bool {
        expected.withUTF8Buffer { expectedBytes in
            guard bytes.count == expectedBytes.count else {
                return false
            }
            var index = 0
            while index < bytes.count {
                var byte = bytes[index]
                if byte >= 97 && byte <= 122 {
                    byte -= 32
                }
                if byte != expectedBytes[index] {
                    return false
                }
                index += 1
            }
            return true
        }
    }
}

