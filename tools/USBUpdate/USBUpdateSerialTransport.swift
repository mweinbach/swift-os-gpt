import Darwin
import Dispatch
import Foundation

enum USBUpdateSerialDiscovery {
    private static let deviceNamePrefix = "cu.usbmodem"

    static func devicePaths() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: "/dev"
        ) else { return [] }
        return names
            .filter { $0.hasPrefix(deviceNamePrefix) }
            .sorted()
            .map { "/dev/\($0)" }
    }
}

enum USBUpdateTransportError: Error, CustomStringConvertible {
    case openFailed(path: String, error: String)
    case termiosReadFailed(path: String, error: String)
    case termiosWriteFailed(path: String, error: String)
    case dtrFailed(path: String, error: String)
    case pollFailed(operation: String, error: String)
    case disconnected(String)
    case timedOut(operation: String)
    case writeFailed(String)
    case readFailed(String)

    var description: String {
        switch self {
        case .openFailed(let path, let error):
            return "cannot open \(path): \(error)"
        case .termiosReadFailed(let path, let error):
            return "cannot read tty settings for \(path): \(error)"
        case .termiosWriteFailed(let path, let error):
            return "cannot configure raw tty mode for \(path): \(error)"
        case .dtrFailed(let path, let error):
            return "cannot assert DTR for \(path): \(error)"
        case .pollFailed(let operation, let error):
            return "\(operation) poll failed: \(error)"
        case .disconnected(let detail):
            return "USB device disconnected: \(detail)"
        case .timedOut(let operation):
            return "timed out while \(operation)"
        case .writeFailed(let error):
            return "USB write failed: \(error)"
        case .readFailed(let error):
            return "USB read failed: \(error)"
        }
    }
}

/// One synchronous, nonblocking CDC ACM connection. Stop-and-wait requests
/// allow the caller to reconnect and reissue BEGIN safely after any timeout.
final class USBUpdateSerialConnection {
    let path: String

    private let descriptor: Int32
    private let decoder = USBUpdateStreamDecoder()

    init(path: String) throws {
        self.path = path
        descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw USBUpdateTransportError.openFailed(
                path: path,
                error: currentUSBUpdatePOSIXError()
            )
        }
        do {
            try Self.configureRawTTY(descriptor, path: path)
            try Self.assertDTR(descriptor, path: path)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func exchange(
        _ request: USBUpdateFrame,
        timeoutSeconds: Double,
        acceptingStatus: (USBUpdateFrame) -> Bool = { _ in true }
    ) throws -> USBUpdateFrame {
        let deadline = deadlineNanoseconds(after: timeoutSeconds)
        try writeAll(request.encoded(), deadline: deadline)
        return try readStatus(
            transferID: request.transferID,
            deadline: deadline,
            acceptingStatus: acceptingStatus
        )
    }

    func sendBestEffort(_ frame: USBUpdateFrame, timeoutSeconds: Double) {
        let deadline = deadlineNanoseconds(after: timeoutSeconds)
        try? writeAll(frame.encoded(), deadline: deadline)
    }

    private func writeAll(_ bytes: [UInt8], deadline: UInt64) throws {
        var offset = 0
        while offset < bytes.count {
            try waitFor(events: Int16(POLLOUT), deadline: deadline,
                        operation: "writing update frame")
            let written = bytes.withUnsafeBytes { rawBytes -> Int in
                guard let base = rawBytes.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                throw USBUpdateTransportError.disconnected(
                    "zero-byte write"
                )
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            if errno == EIO || errno == ENXIO || errno == ENODEV {
                throw USBUpdateTransportError.disconnected(
                    currentUSBUpdatePOSIXError()
                )
            }
            throw USBUpdateTransportError.writeFailed(
                currentUSBUpdatePOSIXError()
            )
        }
    }

    private func readStatus(
        transferID: UInt32,
        deadline: UInt64,
        acceptingStatus: (USBUpdateFrame) -> Bool
    ) throws -> USBUpdateFrame {
        var readStorage = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            while true {
                switch decoder.next() {
                case .needMoreBytes:
                    break
                case .rejected:
                    continue
                case .frame(let frame):
                    // The receive direction can simultaneously contain SDDP
                    // display bytes and stale statuses. Only this transfer's
                    // out-of-band status is relevant to the request in flight.
                    guard frame.kind == .status,
                          frame.transferID == transferID,
                          frame.sequence == 0
                    else { continue }
                    // STATUS has no request sequence by design. Ignore stale
                    // progress reports until the caller's semantic boundary
                    // is reached; remote failures are accepted by the caller
                    // immediately and validated there.
                    if acceptingStatus(frame) { return frame }
                }
                break
            }

            try waitFor(events: Int16(POLLIN), deadline: deadline,
                        operation: "waiting for update status")
            let byteCount = readStorage.withUnsafeMutableBytes { destination in
                Darwin.read(
                    descriptor,
                    destination.baseAddress,
                    destination.count
                )
            }
            if byteCount > 0 {
                decoder.append(Array(readStorage[0..<byteCount]))
                continue
            }
            if byteCount == 0 {
                throw USBUpdateTransportError.disconnected(
                    "device closed the CDC stream"
                )
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            if errno == EIO || errno == ENXIO || errno == ENODEV {
                throw USBUpdateTransportError.disconnected(
                    currentUSBUpdatePOSIXError()
                )
            }
            throw USBUpdateTransportError.readFailed(
                currentUSBUpdatePOSIXError()
            )
        }
    }

    private func waitFor(
        events: Int16,
        deadline: UInt64,
        operation: String
    ) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw USBUpdateTransportError.timedOut(operation: operation)
            }
            let remainingMilliseconds = min(
                UInt64(Int32.max),
                (deadline - now + 999_999) / 1_000_000
            )
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(
                &item,
                1,
                Int32(remainingMilliseconds)
            )
            if result > 0 {
                let terminal = Int16(POLLERR | POLLHUP | POLLNVAL)
                if item.revents & terminal != 0 {
                    throw USBUpdateTransportError.disconnected(
                        "poll flags 0x\(String(item.revents, radix: 16))"
                    )
                }
                if item.revents & events != 0 { return }
                continue
            }
            if result == 0 {
                throw USBUpdateTransportError.timedOut(operation: operation)
            }
            if errno == EINTR { continue }
            throw USBUpdateTransportError.pollFailed(
                operation: operation,
                error: currentUSBUpdatePOSIXError()
            )
        }
    }

    private static func configureRawTTY(
        _ descriptor: Int32,
        path: String
    ) throws {
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            throw USBUpdateTransportError.termiosReadFailed(
                path: path,
                error: currentUSBUpdatePOSIXError()
            )
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        _ = cfsetispeed(&settings, speed_t(B115200))
        _ = cfsetospeed(&settings, speed_t(B115200))
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            throw USBUpdateTransportError.termiosWriteFailed(
                path: path,
                error: currentUSBUpdatePOSIXError()
            )
        }
    }

    private static func assertDTR(_ descriptor: Int32, path: String) throws {
        if ioctl(descriptor, TIOCSDTR) == 0 { return }
        var bits = Int32(TIOCM_DTR)
        guard ioctl(descriptor, TIOCMBIS, &bits) == 0 else {
            throw USBUpdateTransportError.dtrFailed(
                path: path,
                error: currentUSBUpdatePOSIXError()
            )
        }
    }
}

private func deadlineNanoseconds(after seconds: Double) -> UInt64 {
    let boundedSeconds = max(0.001, min(seconds, 3_600))
    let delta = UInt64(boundedSeconds * 1_000_000_000)
    return DispatchTime.now().uptimeNanoseconds &+ delta
}

private func currentUSBUpdatePOSIXError() -> String {
    String(cString: strerror(errno))
}
