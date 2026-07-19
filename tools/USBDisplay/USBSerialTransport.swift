import Darwin
import Dispatch
import Foundation

enum USBSerialDiscovery {
    static let deviceNamePrefix = "cu.usbmodem"

    static func devicePaths() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(
                  atPath: "/dev"
              )
        else { return [] }
        return names
            .filter { $0.hasPrefix(deviceNamePrefix) }
            .sorted()
            .map { "/dev/\($0)" }
    }
}

enum USBSerialTransportError: Error, CustomStringConvertible {
    case openFailed(path: String, error: String)
    case termiosReadFailed(path: String, error: String)
    case termiosWriteFailed(path: String, error: String)
    case dtrFailed(path: String, error: String)

    var description: String {
        switch self {
        case .openFailed(let path, let error):
            return "cannot open \(path): \(error)"
        case .termiosReadFailed(let path, let error):
            return "cannot read tty settings for \(path): \(error)"
        case .termiosWriteFailed(let path, let error):
            return "cannot configure raw tty mode for \(path): \(error)"
        case .dtrFailed(let path, let error):
            return "cannot pulse DTR for \(path): \(error)"
        }
    }
}

/// Nonblocking raw tty reader for the CDC ACM data interface. Callbacks execute
/// synchronously on the queue supplied at construction; byte pointers never
/// escape the callback invocation.
final class USBSerialTransport: @unchecked Sendable {
    typealias ByteHandler = (UnsafeRawBufferPointer) -> Void
    typealias DisconnectHandler = (String) -> Void

    let path: String

    private let fileDescriptor: Int32
    private let source: DispatchSourceRead
    private let onBytes: ByteHandler
    private let onDisconnect: DisconnectHandler
    private var terminated = false

    init(
        path: String,
        queue: DispatchQueue,
        onBytes: @escaping ByteHandler,
        onDisconnect: @escaping DisconnectHandler
    ) throws {
        self.path = path
        self.onBytes = onBytes
        self.onDisconnect = onDisconnect

        let descriptor = Darwin.open(
            path,
            O_RDWR | O_NOCTTY | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw USBSerialTransportError.openFailed(
                path: path,
                error: currentPOSIXError()
            )
        }

        do {
            try Self.configureRawTTY(descriptor, path: path)
            try Self.pulseDTR(descriptor, path: path)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        fileDescriptor = descriptor
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.drainAvailableBytes() }
        source.setCancelHandler { Darwin.close(descriptor) }
    }

    func start() {
        source.resume()
    }

    func stop() {
        terminate(reason: nil)
    }

    private func drainAvailableBytes() {
        guard !terminated else { return }
        var storage = [UInt8](repeating: 0, count: 16 * 1_024)
        // Bound work per dispatch wakeup so a saturated stream cannot starve
        // reconnect and UI delivery tasks on the serial queue.
        var reads = 0
        while reads < 64 {
            let byteCount = storage.withUnsafeMutableBytes { destination in
                Darwin.read(
                    fileDescriptor,
                    destination.baseAddress,
                    destination.count
                )
            }
            if byteCount > 0 {
                storage.withUnsafeBytes { sourceBytes in
                    onBytes(
                        UnsafeRawBufferPointer(
                            start: sourceBytes.baseAddress,
                            count: byteCount
                        )
                    )
                }
                reads += 1
                continue
            }
            if byteCount == 0 {
                terminate(reason: "device closed the CDC stream")
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            terminate(reason: "tty read failed: \(currentPOSIXError())")
            return
        }
    }

    private func terminate(reason: String?) {
        guard !terminated else { return }
        terminated = true
        source.cancel()
        if let reason { onDisconnect(reason) }
    }

    private static func configureRawTTY(
        _ descriptor: Int32,
        path: String
    ) throws {
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            throw USBSerialTransportError.termiosReadFailed(
                path: path,
                error: currentPOSIXError()
            )
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        _ = cfsetispeed(&settings, speed_t(B115200))
        _ = cfsetospeed(&settings, speed_t(B115200))
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            throw USBSerialTransportError.termiosWriteFailed(
                path: path,
                error: currentPOSIXError()
            )
        }
    }

    /// Opening a Darwin `cu` device normally asserts DTR. Explicitly pulsing it
    /// gives a reconnecting guest an unambiguous falling/rising edge on which
    /// to restart hello, mode, and full-frame transmission. Both direct DTR
    /// ioctls and the modem-bit fallback are standard Darwin tty operations.
    private static func pulseDTR(_ descriptor: Int32, path: String) throws {
        guard setDTR(false, descriptor: descriptor) else {
            throw USBSerialTransportError.dtrFailed(
                path: path,
                error: currentPOSIXError()
            )
        }
        usleep(10_000)
        guard setDTR(true, descriptor: descriptor) else {
            throw USBSerialTransportError.dtrFailed(
                path: path,
                error: currentPOSIXError()
            )
        }
    }

    private static func setDTR(
        _ asserted: Bool,
        descriptor: Int32
    ) -> Bool {
        let directRequest = asserted ? TIOCSDTR : TIOCCDTR
        if ioctl(descriptor, directRequest) == 0 { return true }
        var bits = Int32(TIOCM_DTR)
        let bitRequest = asserted ? TIOCMBIS : TIOCMBIC
        return ioctl(descriptor, bitRequest, &bits) == 0
    }
}

private func currentPOSIXError() -> String {
    String(cString: strerror(errno))
}

/// Owns device discovery, reconnect, and the queue-confined protocol pipeline.
final class USBDisplayConnectionManager: @unchecked Sendable {
    typealias StatusHandler = (String) -> Void
    typealias ModeHandler = (USBDebugDisplayMode) -> Void
    typealias FrameHandler = (USBDisplayCompletedFrame) -> Void

    private let requestedPath: String?
    private let onStatus: StatusHandler
    private let onMode: ModeHandler
    private let onFrame: FrameHandler
    private let queue = DispatchQueue(
        label: "org.swiftos.usb-display.serial",
        qos: .userInteractive
    )
    private let pipeline = USBDisplayHostPipeline()

    private var monitor: DispatchSourceTimer?
    private var transport: USBSerialTransport?
    private var lastStatus = ""

    init(
        requestedPath: String?,
        onStatus: @escaping StatusHandler,
        onMode: @escaping ModeHandler,
        onFrame: @escaping FrameHandler
    ) {
        self.requestedPath = requestedPath
        self.onStatus = onStatus
        self.onMode = onMode
        self.onFrame = onFrame
        pipeline.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.discoverAndConnect() }
            monitor = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            monitor?.cancel()
            monitor = nil
            transport?.stop()
            transport = nil
            pipeline.resetForTransportDisconnect()
        }
    }

    private func discoverAndConnect() {
        guard transport == nil else { return }
        let path: String?
        if let requestedPath {
            path = FileManager.default.fileExists(atPath: requestedPath)
                ? requestedPath : nil
        } else {
            path = USBSerialDiscovery.devicePaths().first
        }
        guard let path else {
            publishStatus(
                requestedPath.map { "Waiting for \($0)" }
                    ?? "Waiting for /dev/cu.usbmodem*"
            )
            return
        }

        do {
            pipeline.resetForTransportDisconnect()
            let candidate = try USBSerialTransport(
                path: path,
                queue: queue,
                onBytes: { [weak self] bytes in self?.pipeline.ingest(bytes) },
                onDisconnect: { [weak self] reason in
                    self?.didDisconnect(path: path, reason: reason)
                }
            )
            transport = candidate
            publishStatus("Connected to \(path); awaiting SwiftOS handshake")
            candidate.start()
        } catch {
            publishStatus("USB display open failed: \(error)")
        }
    }

    private func didDisconnect(path: String, reason: String) {
        guard transport?.path == path else { return }
        transport = nil
        pipeline.resetForTransportDisconnect()
        publishStatus("Disconnected from \(path): \(reason); retrying")
    }

    private func handle(_ event: USBDisplayHostEvent) {
        switch event {
        case .modeChanged(let mode):
            publishStatus("SwiftOS display mode received")
            DispatchQueue.main.async { [onMode] in onMode(mode) }

        case .frameCompleted(let frame):
            DispatchQueue.main.async { [onFrame] in onFrame(frame) }

        case .protocolReset(let generation):
            publishStatus("SwiftOS display protocol reset \(generation)")

        case .framingRejected(let rejection):
            publishStatus("USB display resynchronizing: \(rejection)")

        case .semanticRejected(let rejection):
            publishStatus("USB display protocol fault: \(rejection)")

        case .assemblyRejected(let rejection):
            publishStatus("USB display frame rejected: \(rejection)")

        case .streamBytesDiscarded(let count):
            publishStatus("USB display dropped \(count) buffered bytes")
        }
    }

    private func publishStatus(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        fputs("swiftos-usb-display: \(status)\n", stderr)
        DispatchQueue.main.async { [onStatus] in onStatus(status) }
    }
}
