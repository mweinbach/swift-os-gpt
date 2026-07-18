@main
struct MonitorCommandTests {
    static func main() {
        expect(parse("") == .empty, "empty command")
        expect(parse("help") == .help, "lowercase help")
        expect(parse("UNAME") == .uname, "uppercase uname")
        expect(parse("StAtUs") == .status, "mixed-case status")
        expect(parse("clear") == .clear, "clear")
        expect(parse("about") == .about, "about")
        expect(parse("uptime") == .uptime, "uptime")
        expect(parse("help ") == .unknown, "trailing bytes")
        expect(parse("nope") == .unknown, "unknown")
        print("monitor command host tests: 9 passed")
    }

    private static func parse(_ command: String) -> MonitorCommand {
        let bytes = Array(command.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            MonitorCommand.parse(buffer)
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}
