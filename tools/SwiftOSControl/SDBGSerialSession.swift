import Darwin
import Dispatch

enum SwiftOSSDBGSerialOperation: String, Equatable {
    case read
    case write
}

enum SwiftOSSDBGSerialChannelError: Error, Equatable,
    CustomStringConvertible
{
    case invalidReadSize(Int)
    case invalidDTRPulse(UInt64)
    case openFailed(path: String, code: Int32)
    case termiosReadFailed(path: String, code: Int32)
    case termiosWriteFailed(path: String, code: Int32)
    case dtrFailed(path: String, asserted: Bool, code: Int32)
    case dtrWaitFailed(path: String, code: Int32)
    case pollFailed(
        path: String,
        operation: SwiftOSSDBGSerialOperation,
        code: Int32
    )
    case timedOut(path: String, operation: SwiftOSSDBGSerialOperation)
    case disconnected(path: String, detail: String)
    case readFailed(path: String, code: Int32)
    case writeFailed(path: String, code: Int32)

    var description: String {
        switch self {
        case .invalidReadSize(let byteCount):
            return "invalid serial read size: \(byteCount)"
        case .invalidDTRPulse(let nanoseconds):
            return "invalid DTR low interval: \(nanoseconds) ns"
        case .openFailed(let path, let code):
            return "cannot open \(path): \(Self.errorText(code))"
        case .termiosReadFailed(let path, let code):
            return "cannot read tty settings for \(path): \(Self.errorText(code))"
        case .termiosWriteFailed(let path, let code):
            return "cannot configure raw tty mode for \(path): \(Self.errorText(code))"
        case .dtrFailed(let path, let asserted, let code):
            let action = asserted ? "assert" : "clear"
            return "cannot \(action) DTR for \(path): \(Self.errorText(code))"
        case .dtrWaitFailed(let path, let code):
            return "DTR pulse wait failed for \(path): \(Self.errorText(code))"
        case .pollFailed(let path, let operation, let code):
            return "\(path) \(operation.rawValue) poll failed: \(Self.errorText(code))"
        case .timedOut(let path, let operation):
            return "timed out waiting to \(operation.rawValue) \(path)"
        case .disconnected(let path, let detail):
            return "SwiftOS disconnected from \(path): \(detail)"
        case .readFailed(let path, let code):
            return "cannot read \(path): \(Self.errorText(code))"
        case .writeFailed(let path, let code):
            return "cannot write \(path): \(Self.errorText(code))"
        }
    }

    private static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

protocol SwiftOSSDBGMonotonicClock: AnyObject {
    func nowNanoseconds() -> UInt64
}

final class SwiftOSSDBGSystemMonotonicClock: SwiftOSSDBGMonotonicClock {
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// Ordered byte I/O used by the synchronous SDBG session. Implementations use
/// absolute monotonic deadlines, so every wait remains bounded even when a
/// syscall is interrupted and retried.
protocol SwiftOSSDBGSerialByteChannel: AnyObject {
    var path: String { get }

    func pulseDTR(lowNanoseconds: UInt64) throws

    func writeAll(
        _ bytes: [UInt8],
        deadlineNanoseconds: UInt64
    ) throws

    func read(
        maximumByteCount: Int,
        deadlineNanoseconds: UInt64
    ) throws -> [UInt8]
}

/// A synchronous Darwin CDC ACM channel. The descriptor is opened in
/// nonblocking mode, configured as an unprocessed byte stream, and never waits
/// outside a caller-provided poll deadline.
final class SwiftOSCDCRawSerialChannel: SwiftOSSDBGSerialByteChannel {
    let path: String

    private let descriptor: Int32
    private let clock: any SwiftOSSDBGMonotonicClock

    init(
        path: String,
        clock: any SwiftOSSDBGMonotonicClock =
            SwiftOSSDBGSystemMonotonicClock()
    ) throws {
        self.path = path
        self.clock = clock

        let opened = Darwin.open(
            path,
            O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC
        )
        guard opened >= 0 else {
            throw SwiftOSSDBGSerialChannelError.openFailed(
                path: path,
                code: errno
            )
        }
        descriptor = opened
        do {
            try Self.configureRawTTY(opened, path: path)
        } catch {
            Darwin.close(opened)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func pulseDTR(lowNanoseconds: UInt64) throws {
        // Long modem-control sleeps are almost certainly a caller error. A
        // normal reconnect pulse is 10 ms; permit up to one second.
        guard lowNanoseconds <= 1_000_000_000 else {
            throw SwiftOSSDBGSerialChannelError.invalidDTRPulse(
                lowNanoseconds
            )
        }
        try setDTR(asserted: false)
        if lowNanoseconds != 0 {
            var remaining = timespec(
                tv_sec: Int(lowNanoseconds / 1_000_000_000),
                tv_nsec: Int(lowNanoseconds % 1_000_000_000)
            )
            while true {
                var requested = remaining
                var unslept = timespec()
                if nanosleep(&requested, &unslept) == 0 { break }
                if errno == EINTR {
                    remaining = unslept
                    continue
                }
                let code = errno
                // Restore the usable line state before reporting the failure.
                try? setDTR(asserted: true)
                throw SwiftOSSDBGSerialChannelError.dtrWaitFailed(
                    path: path,
                    code: code
                )
            }
        }
        try setDTR(asserted: true)
    }

    func writeAll(
        _ bytes: [UInt8],
        deadlineNanoseconds: UInt64
    ) throws {
        var offset = 0
        while offset < bytes.count {
            try waitFor(
                events: Int16(POLLOUT),
                deadlineNanoseconds: deadlineNanoseconds,
                operation: .write
            )
            let result = bytes.withUnsafeBytes { source -> Int in
                guard let base = source.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if result > 0 {
                offset += result
                continue
            }
            if result == 0 {
                throw SwiftOSSDBGSerialChannelError.disconnected(
                    path: path,
                    detail: "zero-byte write"
                )
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            let code = errno
            if Self.isDisconnectError(code) {
                throw SwiftOSSDBGSerialChannelError.disconnected(
                    path: path,
                    detail: Self.errorText(code)
                )
            }
            throw SwiftOSSDBGSerialChannelError.writeFailed(
                path: path,
                code: code
            )
        }
    }

    func read(
        maximumByteCount: Int,
        deadlineNanoseconds: UInt64
    ) throws -> [UInt8] {
        guard maximumByteCount > 0 else {
            throw SwiftOSSDBGSerialChannelError.invalidReadSize(
                maximumByteCount
            )
        }
        var storage = [UInt8](repeating: 0, count: maximumByteCount)
        while true {
            try waitFor(
                events: Int16(POLLIN),
                deadlineNanoseconds: deadlineNanoseconds,
                operation: .read
            )
            let result = storage.withUnsafeMutableBytes { destination in
                Darwin.read(
                    descriptor,
                    destination.baseAddress,
                    destination.count
                )
            }
            if result > 0 {
                storage.removeLast(storage.count - result)
                return storage
            }
            if result == 0 {
                throw SwiftOSSDBGSerialChannelError.disconnected(
                    path: path,
                    detail: "device closed the CDC byte stream"
                )
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            let code = errno
            if Self.isDisconnectError(code) {
                throw SwiftOSSDBGSerialChannelError.disconnected(
                    path: path,
                    detail: Self.errorText(code)
                )
            }
            throw SwiftOSSDBGSerialChannelError.readFailed(
                path: path,
                code: code
            )
        }
    }

    private func waitFor(
        events: Int16,
        deadlineNanoseconds: UInt64,
        operation: SwiftOSSDBGSerialOperation
    ) throws {
        while true {
            let now = clock.nowNanoseconds()
            guard now < deadlineNanoseconds else {
                throw SwiftOSSDBGSerialChannelError.timedOut(
                    path: path,
                    operation: operation
                )
            }
            let remaining = deadlineNanoseconds - now
            let roundedMilliseconds = remaining > UInt64.max - 999_999
                ? UInt64.max
                : (remaining + 999_999) / 1_000_000
            let milliseconds = min(UInt64(Int32.max), roundedMilliseconds)
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(milliseconds))
            if result > 0 {
                let terminal = Int16(POLLERR | POLLHUP | POLLNVAL)
                if item.revents & terminal != 0 {
                    throw SwiftOSSDBGSerialChannelError.disconnected(
                        path: path,
                        detail: "poll flags 0x\(String(item.revents, radix: 16))"
                    )
                }
                if item.revents & events != 0 {
                    guard clock.nowNanoseconds() < deadlineNanoseconds else {
                        throw SwiftOSSDBGSerialChannelError.timedOut(
                            path: path,
                            operation: operation
                        )
                    }
                    return
                }
                continue
            }
            if result == 0 {
                throw SwiftOSSDBGSerialChannelError.timedOut(
                    path: path,
                    operation: operation
                )
            }
            if errno == EINTR { continue }
            throw SwiftOSSDBGSerialChannelError.pollFailed(
                path: path,
                operation: operation,
                code: errno
            )
        }
    }

    private func setDTR(asserted: Bool) throws {
        let directRequest = asserted ? TIOCSDTR : TIOCCDTR
        if ioctl(descriptor, directRequest) == 0 { return }
        var bits = Int32(TIOCM_DTR)
        let fallbackRequest = asserted ? TIOCMBIS : TIOCMBIC
        guard ioctl(descriptor, fallbackRequest, &bits) == 0 else {
            throw SwiftOSSDBGSerialChannelError.dtrFailed(
                path: path,
                asserted: asserted,
                code: errno
            )
        }
    }

    private static func configureRawTTY(
        _ descriptor: Int32,
        path: String
    ) throws {
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            throw SwiftOSSDBGSerialChannelError.termiosReadFailed(
                path: path,
                code: errno
            )
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard cfsetispeed(&settings, speed_t(B115200)) == 0,
              cfsetospeed(&settings, speed_t(B115200)) == 0,
              tcsetattr(descriptor, TCSANOW, &settings) == 0
        else {
            throw SwiftOSSDBGSerialChannelError.termiosWriteFailed(
                path: path,
                code: errno
            )
        }
    }

    private static func isDisconnectError(_ code: Int32) -> Bool {
        code == EIO || code == ENXIO || code == ENODEV
    }

    private static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

struct SwiftOSSDBGSerialSessionConfiguration: Equatable {
    let handshakeTimeoutNanoseconds: UInt64
    let requestTimeoutNanoseconds: UInt64
    let writeTimeoutNanoseconds: UInt64
    let readPollNanoseconds: UInt64
    let dtrLowNanoseconds: UInt64
    let maximumReadByteCount: Int

    init?(
        handshakeTimeoutNanoseconds: UInt64 = 3_000_000_000,
        requestTimeoutNanoseconds: UInt64 = 2_000_000_000,
        writeTimeoutNanoseconds: UInt64 = 500_000_000,
        readPollNanoseconds: UInt64 = 100_000_000,
        dtrLowNanoseconds: UInt64 = 10_000_000,
        maximumReadByteCount: Int = 16 * 1_024
    ) {
        guard handshakeTimeoutNanoseconds != 0,
              requestTimeoutNanoseconds != 0,
              writeTimeoutNanoseconds != 0,
              readPollNanoseconds != 0,
              dtrLowNanoseconds <= 1_000_000_000,
              maximumReadByteCount > 0,
              maximumReadByteCount <= SDBGProtocol.maximumFrameByteCount
        else { return nil }
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
        self.writeTimeoutNanoseconds = writeTimeoutNanoseconds
        self.readPollNanoseconds = readPollNanoseconds
        self.dtrLowNanoseconds = dtrLowNanoseconds
        self.maximumReadByteCount = maximumReadByteCount
    }

    static var `default`: Self { Self()! }
}

struct SwiftOSSDBGSerialHandshake: Equatable {
    let hello: SDBGHelloPayload
    let capabilities: SDBGCapabilitiesPayload
}

enum SwiftOSSDBGSerialSessionError: Error, Equatable,
    CustomStringConvertible
{
    case clientInitializationFailed
    case handshakeRequired
    case handshakeTimedOut(path: String)
    case requestTimedOut(path: String, operation: SDBGOperation)
    case requestStartFailed(SwiftOSSDBGHostClientError)
    case protocolViolation(SwiftOSSDBGHostProtocolViolation)
    case bootSessionChanged
    case unexpectedCompletion(requestID: UInt64)
    case transportWriteWithoutDeadline

    var description: String {
        switch self {
        case .clientInitializationFailed:
            return "could not initialize the SDBG stream decoder"
        case .handshakeRequired:
            return "SDBG HELLO and CAPABILITIES handshake is required"
        case .handshakeTimedOut(let path):
            return "timed out waiting for SwiftOS SDBG handshake on \(path)"
        case .requestTimedOut(let path, let operation):
            return "timed out waiting for \(operation) response on \(path)"
        case .requestStartFailed(let error):
            return "could not start SDBG request: \(error)"
        case .protocolViolation(let violation):
            return "SwiftOS SDBG protocol violation: \(violation)"
        case .bootSessionChanged:
            return "SwiftOS rebooted while an SDBG request was in flight"
        case .unexpectedCompletion(let requestID):
            return "received unexpected SDBG completion \(requestID)"
        case .transportWriteWithoutDeadline:
            return "SDBG transport write was attempted without a deadline"
        }
    }
}

private final class SwiftOSSDBGDeadlineTransport:
    SwiftOSSDBGHostTransport
{
    private let channel: any SwiftOSSDBGSerialByteChannel
    private var deadlineNanoseconds: UInt64?

    init(channel: any SwiftOSSDBGSerialByteChannel) {
        self.channel = channel
    }

    func arm(deadlineNanoseconds: UInt64) {
        self.deadlineNanoseconds = deadlineNanoseconds
    }

    func disarm() {
        deadlineNanoseconds = nil
    }

    func send(_ frame: [UInt8]) throws {
        guard let deadlineNanoseconds else {
            throw SwiftOSSDBGSerialSessionError
                .transportWriteWithoutDeadline
        }
        try channel.writeAll(
            frame,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }
}

/// Synchronous, stop-and-wait SDBG runner for a CDC byte stream.
///
/// The session deliberately ignores decoder discard events. SDDP display and
/// SUPD update frames share the same CDC stream and are therefore ordinary
/// resynchronization noise here. Valid-but-inconsistent SDBG messages remain
/// fatal protocol violations. Calls must be serialized by the owner.
final class SwiftOSSDBGSerialSession {
    let path: String

    private let channel: any SwiftOSSDBGSerialByteChannel
    private let clock: any SwiftOSSDBGMonotonicClock
    private let configuration: SwiftOSSDBGSerialSessionConfiguration
    private let transport: SwiftOSSDBGDeadlineTransport
    private var client: SwiftOSSDBGHostStreamClient
    private var completedHandshake = false

    convenience init(
        path: String,
        configuration: SwiftOSSDBGSerialSessionConfiguration = .default
    ) throws {
        let clock = SwiftOSSDBGSystemMonotonicClock()
        let channel = try SwiftOSCDCRawSerialChannel(
            path: path,
            clock: clock
        )
        try self.init(
            channel: channel,
            clock: clock,
            configuration: configuration
        )
    }

    init(
        channel: any SwiftOSSDBGSerialByteChannel,
        clock: any SwiftOSSDBGMonotonicClock,
        configuration: SwiftOSSDBGSerialSessionConfiguration = .default
    ) throws {
        self.path = channel.path
        self.channel = channel
        self.clock = clock
        self.configuration = configuration
        let transport = SwiftOSSDBGDeadlineTransport(channel: channel)
        guard let client = SwiftOSSDBGHostStreamClient(transport: transport)
        else {
            throw SwiftOSSDBGSerialSessionError.clientInitializationFailed
        }
        self.transport = transport
        self.client = client
    }

    func connect() throws -> SwiftOSSDBGSerialHandshake {
        completedHandshake = false
        // Discard stale partial frames and request correlation state before a
        // DTR edge asks the guest for a fresh discovery pair.
        guard let freshClient = SwiftOSSDBGHostStreamClient(
            transport: transport
        ) else {
            throw SwiftOSSDBGSerialSessionError.clientInitializationFailed
        }
        client = freshClient
        try channel.pulseDTR(
            lowNanoseconds: configuration.dtrLowNanoseconds
        )

        let deadline = Self.deadline(
            after: configuration.handshakeTimeoutNanoseconds,
            now: clock.nowNanoseconds()
        )
        var sawHello = false
        var sawCapabilities = false
        while true {
            let now = clock.nowNanoseconds()
            guard now < deadline else {
                throw SwiftOSSDBGSerialSessionError.handshakeTimedOut(
                    path: path
                )
            }
            let events = try receiveEvents(overallDeadline: deadline)
            for event in events {
                switch event {
                case .hello:
                    sawHello = true
                case .capabilities:
                    sawCapabilities = true
                case .sessionChanged, .discardedFrame:
                    continue
                case .protocolViolation(let violation):
                    throw SwiftOSSDBGSerialSessionError.protocolViolation(
                        violation
                    )
                case .completed(let requestID, _):
                    throw SwiftOSSDBGSerialSessionError
                        .unexpectedCompletion(requestID: requestID)
                case .timedOut, .cancelledForSessionChange:
                    continue
                }
            }
            if sawHello, sawCapabilities,
               let hello = client.hello,
               let capabilities = client.capabilities
            {
                completedHandshake = true
                return SwiftOSSDBGSerialHandshake(
                    hello: hello,
                    capabilities: capabilities
                )
            }
        }
    }

    func perform(
        _ request: SDBGRequest
    ) throws -> SwiftOSSDBGHostTransactionResult {
        guard completedHandshake else {
            throw SwiftOSSDBGSerialSessionError.handshakeRequired
        }
        let started = clock.nowNanoseconds()
        let deadline = Self.deadline(
            after: configuration.requestTimeoutNanoseconds,
            now: started
        )
        let writeDeadline = min(
            deadline,
            Self.deadline(
                after: configuration.writeTimeoutNanoseconds,
                now: started
            )
        )
        transport.arm(deadlineNanoseconds: writeDeadline)
        let requestID: UInt64
        do {
            requestID = try client.begin(
                request,
                now: started,
                timeoutTicks: deadline - started
            )
        } catch let error as SwiftOSSDBGHostClientError {
            transport.disarm()
            throw SwiftOSSDBGSerialSessionError.requestStartFailed(error)
        } catch {
            transport.disarm()
            throw error
        }
        transport.disarm()

        while true {
            let now = clock.nowNanoseconds()
            if now >= deadline {
                _ = client.expire(now: now)
                throw SwiftOSSDBGSerialSessionError.requestTimedOut(
                    path: path,
                    operation: request.operation
                )
            }
            let events = try receiveEvents(overallDeadline: deadline)
            for event in events {
                switch event {
                case .completed(let completedID, let result):
                    guard completedID == requestID else {
                        throw SwiftOSSDBGSerialSessionError
                            .unexpectedCompletion(requestID: completedID)
                    }
                    return result
                case .timedOut(let timedOutID, let operation)
                        where timedOutID == requestID:
                    throw SwiftOSSDBGSerialSessionError.requestTimedOut(
                        path: path,
                        operation: operation
                    )
                case .cancelledForSessionChange(let cancelledID, _)
                        where cancelledID == requestID:
                    completedHandshake = false
                    throw SwiftOSSDBGSerialSessionError.bootSessionChanged
                case .sessionChanged:
                    completedHandshake = false
                case .protocolViolation(let violation):
                    throw SwiftOSSDBGSerialSessionError.protocolViolation(
                        violation
                    )
                case .hello, .capabilities, .discardedFrame:
                    continue
                case .timedOut, .cancelledForSessionChange:
                    continue
                }
            }
        }
    }

    func perform(
        _ requests: [SDBGRequest]
    ) throws -> [SwiftOSSDBGHostTransactionResult] {
        var results: [SwiftOSSDBGHostTransactionResult] = []
        results.reserveCapacity(requests.count)
        for request in requests {
            results.append(try perform(request))
        }
        return results
    }

    private func receiveEvents(
        overallDeadline: UInt64
    ) throws -> [SwiftOSSDBGHostClientEvent] {
        let now = clock.nowNanoseconds()
        let readDeadline = min(
            overallDeadline,
            Self.deadline(
                after: configuration.readPollNanoseconds,
                now: now
            )
        )
        do {
            let bytes = try channel.read(
                maximumByteCount: configuration.maximumReadByteCount,
                deadlineNanoseconds: readDeadline
            )
            return client.receive(bytes, now: clock.nowNanoseconds())
        } catch SwiftOSSDBGSerialChannelError.timedOut(
            _, .read
        ) {
            return client.expire(now: clock.nowNanoseconds())
        }
    }

    private static func deadline(after delta: UInt64, now: UInt64) -> UInt64 {
        now > UInt64.max - delta ? UInt64.max : now + delta
    }
}
