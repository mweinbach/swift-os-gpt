import Darwin
import Dispatch
import Foundation

private enum SwiftOSControlCommand {
    case discover(json: Bool)
    case doctor(json: Bool)
    case waitReady(json: Bool, timeout: Double)
    case identity(SwiftOSRemoteOptions)
    case status(SwiftOSRemoteOptions)
    case ping(SwiftOSRemoteOptions, token: UInt64?)
    case logs(
        SwiftOSRemoteOptions,
        startingSequence: UInt64?,
        maximumEntryCount: UInt32
    )
    case help
}

private struct SwiftOSRemoteOptions {
    let json: Bool
    let timeout: Double
    let devicePath: String?
}

private enum SwiftOSControlOptionError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case invalidTimeout(String)
    case invalidInteger(option: String, value: String)

    var description: String {
        switch self {
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .unknownOption(let option):
            return "unknown option: \(option)"
        case .missingValue(let option):
            return "\(option) requires a value"
        case .invalidTimeout(let value):
            return "invalid timeout: \(value)"
        case .invalidInteger(let option, let value):
            return "invalid integer for \(option): \(value)"
        }
    }
}

private enum SwiftOSControlArguments {
    static func parse(_ arguments: [String]) throws -> SwiftOSControlCommand {
        guard arguments.count > 1 else { return .help }
        let name = arguments[1]
        if name == "help" || name == "--help" || name == "-h" {
            return .help
        }
        let remoteCommands = ["identity", "status", "ping", "logs"]
        guard ["discover", "doctor", "wait-ready"].contains(name)
                || remoteCommands.contains(name)
        else {
            throw SwiftOSControlOptionError.unknownCommand(name)
        }

        var json = false
        var timeout = 30.0
        var devicePath: String?
        var pingToken: UInt64?
        var logStartingSequence: UInt64?
        var logEntryCount: UInt32 = 32
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                json = true
            case "--timeout" where name == "wait-ready"
                    || remoteCommands.contains(name):
                index += 1
                guard index < arguments.count else {
                    throw SwiftOSControlOptionError.missingValue("--timeout")
                }
                guard let value = Double(arguments[index]),
                      value >= (name == "wait-ready" ? 0 : 0.001),
                      value <= 3_600
                else {
                    throw SwiftOSControlOptionError.invalidTimeout(
                        arguments[index]
                    )
                }
                timeout = value
            case "--device" where remoteCommands.contains(name):
                index += 1
                guard index < arguments.count else {
                    throw SwiftOSControlOptionError.missingValue("--device")
                }
                devicePath = arguments[index]
            case "--token" where name == "ping":
                index += 1
                guard index < arguments.count else {
                    throw SwiftOSControlOptionError.missingValue("--token")
                }
                pingToken = try parseUInt64(
                    arguments[index],
                    option: "--token"
                )
            case "--start" where name == "logs":
                index += 1
                guard index < arguments.count else {
                    throw SwiftOSControlOptionError.missingValue("--start")
                }
                let value = try parseUInt64(
                    arguments[index],
                    option: "--start"
                )
                guard value != 0 else {
                    throw SwiftOSControlOptionError.invalidInteger(
                        option: "--start",
                        value: arguments[index]
                    )
                }
                logStartingSequence = value
            case "--count" where name == "logs":
                index += 1
                guard index < arguments.count else {
                    throw SwiftOSControlOptionError.missingValue("--count")
                }
                let value = try parseUInt64(
                    arguments[index],
                    option: "--count"
                )
                guard value > 0, value <= 4_096 else {
                    throw SwiftOSControlOptionError.invalidInteger(
                        option: "--count",
                        value: arguments[index]
                    )
                }
                logEntryCount = UInt32(value)
            default:
                throw SwiftOSControlOptionError.unknownOption(arguments[index])
            }
            index += 1
        }

        switch name {
        case "discover": return .discover(json: json)
        case "doctor": return .doctor(json: json)
        case "wait-ready": return .waitReady(json: json, timeout: timeout)
        default:
            let options = SwiftOSRemoteOptions(
                json: json,
                timeout: timeout,
                devicePath: devicePath
            )
            switch name {
            case "identity": return .identity(options)
            case "status": return .status(options)
            case "ping": return .ping(options, token: pingToken)
            default:
                return .logs(
                    options,
                    startingSequence: logStartingSequence,
                    maximumEntryCount: logEntryCount
                )
            }
        }
    }

    private static func parseUInt64(
        _ input: String,
        option: String
    ) throws -> UInt64 {
        let value: UInt64?
        if input.hasPrefix("0x") || input.hasPrefix("0X") {
            value = UInt64(input.dropFirst(2), radix: 16)
        } else {
            value = UInt64(input)
        }
        guard let value else {
            throw SwiftOSControlOptionError.invalidInteger(
                option: option,
                value: input
            )
        }
        return value
    }
}

private enum SwiftOSRemoteRunError: Error, CustomStringConvertible {
    case invalidDevicePath(String)
    case noDevice
    case ambiguousDevices([String])
    case invalidSessionConfiguration
    case unexpectedResponse(expected: String)
    case remoteError(SwiftOSSDBGHostRemoteError)
    case logCursorDidNotAdvance(UInt64)

    var description: String {
        switch self {
        case .invalidDevicePath(let path):
            return "device must be a macOS callout or tty path under /dev: \(path)"
        case .noDevice:
            return "no SwiftOS CDC control device is ready; run `swiftosctl doctor`"
        case .ambiguousDevices(let paths):
            return "multiple SwiftOS CDC devices are ready; select one with --device (\(paths.joined(separator: ", ")))"
        case .invalidSessionConfiguration:
            return "could not construct the bounded SDBG serial session"
        case .unexpectedResponse(let expected):
            return "SwiftOS returned a response other than \(expected)"
        case .remoteError(let error):
            return "SwiftOS rejected operation \(error.operationRawValue) with \(Self.statusName(error.status)) (detail0 \(Self.hex(error.detail0)), detail1 \(Self.hex(error.detail1)))"
        case .logCursorDidNotAdvance(let sequence):
            return "SwiftOS log cursor did not advance from sequence \(sequence)"
        }
    }

    private static func statusName(_ status: SDBGResponseStatus) -> String {
        switch status {
        case .success: return "success"
        case .malformedRequest: return "malformed-request"
        case .unsupportedSchema: return "unsupported-schema"
        case .unsupportedOperation: return "unsupported-operation"
        case .unsupportedFlags: return "unsupported-flags"
        case .invalidArgument: return "invalid-argument"
        case .bootSessionMismatch: return "boot-session-mismatch"
        case .logSequenceLost: return "log-sequence-lost"
        case .logSequenceNotYetWritten: return "log-sequence-not-yet-written"
        case .logProviderInconsistent: return "log-provider-inconsistent"
        case .requestTooLarge: return "request-too-large"
        }
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }
}

private enum SwiftOSControlFormat {
    static func identity(_ value: KernelIdentity128) -> String {
        String(format: "%016llx%016llx", value.high, value.low)
    }

    static func identity(_ value: SDBGBootSessionID) -> String {
        String(format: "%016llx%016llx", value.high, value.low)
    }

    static func hex(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }

    static func phase(_ value: DebugKernelPhase) -> String {
        switch value {
        case .reset: return "reset"
        case .earlyBoot: return "early-boot"
        case .memoryReady: return "memory-ready"
        case .driversReady: return "drivers-ready"
        case .schedulerRunning: return "scheduler-running"
        case .userlandRunning: return "userland-running"
        case .updating: return "updating"
        case .failed: return "failed"
        }
    }

    static func display(_ value: DebugDisplayState) -> String {
        switch value {
        case .unavailable: return "unavailable"
        case .discovering: return "discovering"
        case .configured: return "configured"
        case .presenting: return "presenting"
        case .failed: return "failed"
        }
    }

    static func link(_ value: DebugLinkState) -> String {
        switch value {
        case .unavailable: return "unavailable"
        case .initializing: return "initializing"
        case .ready: return "ready"
        case .connected: return "connected"
        case .failed: return "failed"
        }
    }

    static func update(_ value: DebugUpdateState) -> String {
        switch value {
        case .idle: return "idle"
        case .receiving: return "receiving"
        case .verifying: return "verifying"
        case .committed: return "committed"
        case .activating: return "activating"
        case .rejected: return "rejected"
        }
    }

    static func buildFlavor(_ value: KernelBuildFlavor) -> String {
        switch value {
        case .development: return "development"
        case .release: return "release"
        case .diagnostic: return "diagnostic"
        }
    }

    static func bootReason(_ value: KernelBootReason) -> String {
        switch value {
        case .cold: return "cold"
        case .warmReset: return "warm-reset"
        case .softwareUpdate: return "software-update"
        case .recovery: return "recovery"
        case .unknown: return "unknown"
        }
    }

    static func logLevel(_ value: KernelLogLevel) -> String {
        switch value {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .warning: return "warning"
        case .error: return "error"
        case .critical: return "critical"
        }
    }

    static func subsystem(_ value: KernelLogSubsystem) -> String {
        switch value.rawValue {
        case KernelLogSubsystem.kernel.rawValue: return "kernel"
        case KernelLogSubsystem.boot.rawValue: return "boot"
        case KernelLogSubsystem.memory.rawValue: return "memory"
        case KernelLogSubsystem.scheduler.rawValue: return "scheduler"
        case KernelLogSubsystem.interrupts.rawValue: return "interrupts"
        case KernelLogSubsystem.drivers.rawValue: return "drivers"
        case KernelLogSubsystem.graphics.rawValue: return "graphics"
        case KernelLogSubsystem.update.rawValue: return "update"
        case KernelLogSubsystem.userland.rawValue: return "userland"
        default: return "subsystem-\(value.rawValue)"
        }
    }

    static func flags(_ value: DebugStatusFlags) -> [String] {
        var result: [String] = []
        if value.contains(.interruptsEnabled) { result.append("interrupts-enabled") }
        if value.contains(.virtualMemoryEnabled) { result.append("virtual-memory-enabled") }
        if value.contains(.preemptionEnabled) { result.append("preemption-enabled") }
        if value.contains(.userlandIsolated) { result.append("userland-isolated") }
        if value.contains(.degraded) { result.append("degraded") }
        return result
    }
}

private struct SwiftOSIdentityReport: Codable {
    let devicePath: String
    let protocolVersion: String
    let bootSessionID: String
    let buildID: String
    let sourceRevision: String
    let imageDigestPrefix: String
    let buildFlavor: String
    let abiRevision: UInt16
    let bootOrdinal: UInt64
    let startedAtTicks: UInt64
    let bootReason: String

    init(
        devicePath: String,
        handshake: SwiftOSSDBGSerialHandshake,
        identity: KernelBootIdentity
    ) {
        self.devicePath = devicePath
        protocolVersion = "\(handshake.hello.protocolMajor).\(handshake.hello.protocolMinor)"
        bootSessionID = SwiftOSControlFormat.identity(identity.sessionID)
        buildID = SwiftOSControlFormat.identity(identity.build.buildID)
        sourceRevision = SwiftOSControlFormat.hex(identity.build.sourceRevision)
        imageDigestPrefix = SwiftOSControlFormat.hex(
            identity.build.imageDigestPrefix
        )
        buildFlavor = SwiftOSControlFormat.buildFlavor(identity.build.flavor)
        abiRevision = identity.build.abiRevision
        bootOrdinal = identity.bootOrdinal
        startedAtTicks = identity.startedAtTicks
        bootReason = SwiftOSControlFormat.bootReason(identity.reason)
    }

    var text: [String] {
        [
            "device: \(devicePath)",
            "protocol: SDBG \(protocolVersion)",
            "boot-session: \(bootSessionID)",
            "build: \(buildID) (\(buildFlavor), ABI \(abiRevision))",
            "source-revision: \(sourceRevision)",
            "image-digest-prefix: \(imageDigestPrefix)",
            "boot: \(bootReason), ordinal \(bootOrdinal), start tick \(startedAtTicks)",
        ]
    }
}

private struct SwiftOSStatusReport: Codable {
    let devicePath: String
    let bootSessionID: String
    let snapshotSequence: UInt64
    let monotonicTicks: UInt64
    let phase: String
    let flags: [String]
    let flagsRawValue: UInt32
    let configuredProcessorCount: UInt16
    let onlineProcessorCount: UInt16
    let runnableThreadCount: UInt32
    let managedMemoryByteCount: UInt64
    let freeMemoryByteCount: UInt64
    let displayState: String
    let displayWidthPixels: UInt32
    let displayHeightPixels: UInt32
    let displayRefreshMilliHertz: UInt32
    let debugLinkState: String
    let updateState: String
    let oldestLogSequence: UInt64
    let newestLogSequence: UInt64
    let lostLogEntryCount: UInt64
    let lastErrorDomain: UInt16
    let lastErrorCode: UInt16
    let lastErrorDetail: UInt32

    init(devicePath: String, status: DebugStatusSnapshot) {
        self.devicePath = devicePath
        bootSessionID = SwiftOSControlFormat.identity(status.bootSessionID)
        snapshotSequence = status.snapshotSequence
        monotonicTicks = status.monotonicTicks
        phase = SwiftOSControlFormat.phase(status.phase)
        flags = SwiftOSControlFormat.flags(status.flags)
        flagsRawValue = status.flags.rawValue
        configuredProcessorCount = status.configuredProcessorCount
        onlineProcessorCount = status.onlineProcessorCount
        runnableThreadCount = status.runnableThreadCount
        managedMemoryByteCount = status.managedMemoryByteCount
        freeMemoryByteCount = status.freeMemoryByteCount
        displayState = SwiftOSControlFormat.display(status.displayState)
        displayWidthPixels = status.displayWidthPixels
        displayHeightPixels = status.displayHeightPixels
        displayRefreshMilliHertz = status.displayRefreshMilliHertz
        debugLinkState = SwiftOSControlFormat.link(status.debugLinkState)
        updateState = SwiftOSControlFormat.update(status.updateState)
        oldestLogSequence = status.oldestLogSequence
        newestLogSequence = status.newestLogSequence
        lostLogEntryCount = status.lostLogEntryCount
        lastErrorDomain = status.lastError.domain
        lastErrorCode = status.lastError.code
        lastErrorDetail = status.lastError.detail
    }

    var text: [String] {
        let activeFlags = flags.isEmpty ? "none" : flags.joined(separator: ", ")
        let mode = displayWidthPixels == 0
            ? "no active mode"
            : "\(displayWidthPixels)x\(displayHeightPixels) @ \(Double(displayRefreshMilliHertz) / 1_000.0) Hz"
        return [
            "device: \(devicePath)",
            "boot-session: \(bootSessionID)",
            "kernel: \(phase); flags \(activeFlags)",
            "cpus: \(onlineProcessorCount)/\(configuredProcessorCount) online; \(runnableThreadCount) runnable threads",
            "memory: \(freeMemoryByteCount)/\(managedMemoryByteCount) bytes free",
            "display: \(displayState); \(mode)",
            "debug-link: \(debugLinkState); update: \(updateState)",
            "logs: \(oldestLogSequence)...\(newestLogSequence); lost \(lostLogEntryCount)",
            "last-error: \(lastErrorDomain):\(lastErrorCode) detail \(lastErrorDetail)",
        ]
    }
}

private struct SwiftOSPingReport: Codable {
    let devicePath: String
    let token: String

    var text: [String] { ["device: \(devicePath)", "pong: \(token)"] }
}

private struct SwiftOSLogEntryReport: Codable {
    let sequence: UInt64
    let timestampTicks: UInt64
    let level: String
    let subsystem: String
    let subsystemID: UInt16
    let eventCode: UInt32
    let processorID: UInt32
    let flags: UInt32
    let argument0: String
    let argument1: String

    init(_ entry: KernelLogEntry) {
        sequence = entry.sequence
        timestampTicks = entry.event.timestampTicks
        level = SwiftOSControlFormat.logLevel(entry.event.level)
        subsystem = SwiftOSControlFormat.subsystem(entry.event.subsystem)
        subsystemID = entry.event.subsystem.rawValue
        eventCode = entry.event.eventCode
        processorID = entry.event.processorID
        flags = entry.event.flags
        argument0 = SwiftOSControlFormat.hex(entry.event.argument0)
        argument1 = SwiftOSControlFormat.hex(entry.event.argument1)
    }

    var text: String {
        "#\(sequence) t=\(timestampTicks) \(level) \(subsystem) event=\(eventCode) cpu=\(processorID) flags=\(flags) arg0=\(argument0) arg1=\(argument1)"
    }
}

private struct SwiftOSLogsReport: Codable {
    let devicePath: String
    let bootSessionID: String
    let requestedStartingSequence: UInt64?
    let effectiveStartingSequence: UInt64?
    let oldestAvailableSequence: UInt64
    let newestAvailableSequence: UInt64
    let lostEntryCount: UInt64
    let moreAvailable: Bool
    let entries: [SwiftOSLogEntryReport]

    var text: [String] {
        var lines = [
            "device: \(devicePath)",
            "boot-session: \(bootSessionID)",
            "available: \(oldestAvailableSequence)...\(newestAvailableSequence); lost \(lostEntryCount)",
        ]
        if entries.isEmpty { lines.append("logs: empty") }
        else { lines.append(contentsOf: entries.map(\.text)) }
        if moreAvailable { lines.append("logs: more entries available") }
        return lines
    }
}

private struct SwiftOSRemoteRunner {
    private let provider: any SwiftOSDiscoveryProvider

    init(provider: any SwiftOSDiscoveryProvider) {
        self.provider = provider
    }

    func identity(_ options: SwiftOSRemoteOptions) throws -> SwiftOSIdentityReport {
        let connection = try connect(options)
        let result = try connection.session.perform(.identity)
        switch result {
        case .identity(let identity):
            return SwiftOSIdentityReport(
                devicePath: connection.path,
                handshake: connection.handshake,
                identity: identity
            )
        case .remoteError(let error): throw SwiftOSRemoteRunError.remoteError(error)
        default: throw SwiftOSRemoteRunError.unexpectedResponse(expected: "identity")
        }
    }

    func status(_ options: SwiftOSRemoteOptions) throws -> SwiftOSStatusReport {
        let connection = try connect(options)
        let result = try connection.session.perform(.status)
        switch result {
        case .status(let status):
            return SwiftOSStatusReport(devicePath: connection.path, status: status)
        case .remoteError(let error): throw SwiftOSRemoteRunError.remoteError(error)
        default: throw SwiftOSRemoteRunError.unexpectedResponse(expected: "status")
        }
    }

    func ping(
        _ options: SwiftOSRemoteOptions,
        token: UInt64?
    ) throws -> SwiftOSPingReport {
        let connection = try connect(options)
        let sentToken = token ?? DispatchTime.now().uptimeNanoseconds
        let result = try connection.session.perform(.ping(token: sentToken))
        switch result {
        case .ping(let returnedToken) where returnedToken == sentToken:
            return SwiftOSPingReport(
                devicePath: connection.path,
                token: SwiftOSControlFormat.hex(returnedToken)
            )
        case .ping:
            throw SwiftOSRemoteRunError.unexpectedResponse(
                expected: "ping with the transmitted token"
            )
        case .remoteError(let error): throw SwiftOSRemoteRunError.remoteError(error)
        default: throw SwiftOSRemoteRunError.unexpectedResponse(expected: "ping")
        }
    }

    func logs(
        _ options: SwiftOSRemoteOptions,
        startingSequence: UInt64?,
        maximumEntryCount: UInt32
    ) throws -> SwiftOSLogsReport {
        let connection = try connect(options)
        var cursor = startingSequence
        var oldest: UInt64 = 0
        var newest: UInt64 = 0
        var lost: UInt64 = 0

        if cursor == nil {
            let statusResult = try connection.session.perform(.status)
            switch statusResult {
            case .status(let status):
                oldest = status.oldestLogSequence
                newest = status.newestLogSequence
                lost = status.lostLogEntryCount
                cursor = oldest == 0 ? nil : oldest
            case .remoteError(let error):
                throw SwiftOSRemoteRunError.remoteError(error)
            default:
                throw SwiftOSRemoteRunError.unexpectedResponse(expected: "status")
            }
        }

        guard var nextSequence = cursor else {
            return SwiftOSLogsReport(
                devicePath: connection.path,
                bootSessionID: SwiftOSControlFormat.identity(
                    connection.handshake.hello.bootSessionID
                ),
                requestedStartingSequence: startingSequence,
                effectiveStartingSequence: nil,
                oldestAvailableSequence: oldest,
                newestAvailableSequence: newest,
                lostEntryCount: lost,
                moreAvailable: false,
                entries: []
            )
        }

        var effectiveStart = nextSequence
        let advertisedLimit = max(
            UInt32(1),
            UInt32(connection.handshake.capabilities.maximumLogEntriesPerResponse)
        )
        var reports: [SwiftOSLogEntryReport] = []
        reports.reserveCapacity(Int(maximumEntryCount))
        var moreAvailable = false
        var retriedRotatedDefaultCursor = false

        pageLoop: while reports.count < Int(maximumEntryCount) {
            let remaining = maximumEntryCount - UInt32(reports.count)
            let pageCount = min(remaining, advertisedLimit)
            let result = try connection.session.perform(
                .logSnapshot(
                    SDBGLogSnapshotRequest(
                        startingSequence: nextSequence,
                        maximumEntryCount: pageCount
                    )
                )
            )
            switch result {
            case .logSnapshot(let snapshot):
                oldest = snapshot.oldestAvailableSequence
                newest = snapshot.newestAvailableSequence
                lost = snapshot.lostEntryCount
                reports.append(contentsOf: snapshot.entries.map(SwiftOSLogEntryReport.init))
                moreAvailable = snapshot.flags.contains(.moreEntries)
                guard moreAvailable else { break pageLoop }
                guard snapshot.nextSequence != 0,
                      snapshot.nextSequence != nextSequence
                else {
                    throw SwiftOSRemoteRunError.logCursorDidNotAdvance(
                        nextSequence
                    )
                }
                nextSequence = snapshot.nextSequence
            case .remoteError(let error)
                    where startingSequence == nil
                        && error.status == .logSequenceLost
                        && error.detail0 != 0
                        && !retriedRotatedDefaultCursor:
                nextSequence = error.detail0
                effectiveStart = error.detail0
                retriedRotatedDefaultCursor = true
                continue
            case .remoteError(let error):
                throw SwiftOSRemoteRunError.remoteError(error)
            default:
                throw SwiftOSRemoteRunError.unexpectedResponse(
                    expected: "log snapshot"
                )
            }
        }

        return SwiftOSLogsReport(
            devicePath: connection.path,
            bootSessionID: SwiftOSControlFormat.identity(
                connection.handshake.hello.bootSessionID
            ),
            requestedStartingSequence: startingSequence,
            effectiveStartingSequence: effectiveStart,
            oldestAvailableSequence: oldest,
            newestAvailableSequence: newest,
            lostEntryCount: lost,
            moreAvailable: moreAvailable,
            entries: reports
        )
    }

    private func connect(
        _ options: SwiftOSRemoteOptions
    ) throws -> (
        path: String,
        session: SwiftOSSDBGSerialSession,
        handshake: SwiftOSSDBGSerialHandshake
    ) {
        let path = try resolveDevicePath(options.devicePath)
        let timeoutNanoseconds = UInt64(options.timeout * 1_000_000_000)
        guard let configuration = SwiftOSSDBGSerialSessionConfiguration(
            handshakeTimeoutNanoseconds: timeoutNanoseconds,
            requestTimeoutNanoseconds: timeoutNanoseconds,
            writeTimeoutNanoseconds: min(timeoutNanoseconds, 500_000_000),
            readPollNanoseconds: min(timeoutNanoseconds, 100_000_000),
            dtrLowNanoseconds: 10_000_000,
            maximumReadByteCount: SDBGProtocol.maximumFrameByteCount
        ) else {
            throw SwiftOSRemoteRunError.invalidSessionConfiguration
        }
        let session = try SwiftOSSDBGSerialSession(
            path: path,
            configuration: configuration
        )
        let handshake = try session.connect()
        return (path, session, handshake)
    }

    private func resolveDevicePath(_ requested: String?) throws -> String {
        if let requested {
            guard requested.hasPrefix("/dev/cu.")
                    || requested.hasPrefix("/dev/tty.")
            else { throw SwiftOSRemoteRunError.invalidDevicePath(requested) }
            return requested
        }

        let paths = Array(
            Set(
                try provider.snapshot().usbDevices
                    .filter(\.isSwiftOS)
                    .flatMap(\.ttyPaths)
            )
        ).sorted()
        guard !paths.isEmpty else { throw SwiftOSRemoteRunError.noDevice }
        guard paths.count == 1 else {
            throw SwiftOSRemoteRunError.ambiguousDevices(paths)
        }
        return paths[0]
    }
}

@main
private struct SwiftOSControlCLI {
    static func main() {
        do {
            let command = try SwiftOSControlArguments.parse(CommandLine.arguments)
            let provider = SwiftOSIOKitDiscoveryProvider()
            switch command {
            case .help:
                printHelp()
            case .discover(let json):
                let report = SwiftOSDoctor.report(from: try provider.snapshot())
                emit(report, json: json)
            case .doctor(let json):
                let report = SwiftOSDoctor.report(from: try provider.snapshot())
                emit(report, json: json)
                if !report.ready { exit(2) }
            case .waitReady(let json, let timeout):
                let deadline = Date().addingTimeInterval(timeout)
                var report: SwiftOSDoctorReport
                repeat {
                    report = SwiftOSDoctor.report(from: try provider.snapshot())
                    if report.ready {
                        emit(report, json: json)
                        return
                    }
                    if Date() >= deadline { break }
                    usleep(250_000)
                } while true
                emit(report, json: json)
                exit(2)
            case .identity(let options):
                let report = try SwiftOSRemoteRunner(provider: provider)
                    .identity(options)
                emit(report, json: options.json, text: report.text)
            case .status(let options):
                let report = try SwiftOSRemoteRunner(provider: provider)
                    .status(options)
                emit(report, json: options.json, text: report.text)
            case .ping(let options, let token):
                let report = try SwiftOSRemoteRunner(provider: provider)
                    .ping(options, token: token)
                emit(report, json: options.json, text: report.text)
            case .logs(let options, let startingSequence, let count):
                let report = try SwiftOSRemoteRunner(provider: provider)
                    .logs(
                        options,
                        startingSequence: startingSequence,
                        maximumEntryCount: count
                    )
                emit(report, json: options.json, text: report.text)
            }
        } catch let error as SwiftOSControlOptionError {
            fputs("swiftosctl: \(error)\n", stderr)
            exit(64)
        } catch {
            fputs("swiftosctl: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func emit<T: Encodable>(
        _ report: T,
        json: Bool,
        text: [String]
    ) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let bytes = try encoder.encode(report)
                guard let output = String(data: bytes, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                print(output)
            } catch {
                fputs("swiftosctl: could not encode report: \(error)\n", stderr)
                exit(70)
            }
            return
        }
        for line in text { print(line) }
    }

    private static func emit(_ report: SwiftOSDoctorReport, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let bytes = try? encoder.encode(report),
                  let output = String(data: bytes, encoding: .utf8)
            else {
                fputs("swiftosctl: could not encode report\n", stderr)
                exit(70)
            }
            print(output)
            return
        }

        print("stage: \(report.stage.rawValue)")
        print(report.summary)
        if report.devices.isEmpty {
            print("device: not found (VID \(report.expectedVendorID), PID \(report.expectedProductID))")
        } else {
            for device in report.devices {
                let product = device.productName ?? "unknown product"
                let serial = device.serialNumber ?? "no serial"
                let paths = device.ttyPaths.isEmpty
                    ? "no tty"
                    : device.ttyPaths.joined(separator: ", ")
                print("device: \(product); serial \(serial); \(paths)")
            }
        }
        print("next: \(report.remediation)")
    }

    private static func printHelp() {
        print("""
        Usage: swiftosctl <command> [options]

          discover [--json]                 Inspect SwiftOS USB and CDC devices
          doctor [--json]                   Diagnose readiness (exit 2 if not ready)
          wait-ready [--json] [--timeout S] Wait for one usable SwiftOS tty
          identity [remote options]          Read boot and build identity
          status [remote options]            Read kernel, CPU, memory, and display state
          ping [remote options] [--token N]  Verify the live SDBG control path
          logs [remote options] [--start N] [--count N]
                                            Read retained structured kernel logs

        Remote options:
          --device /dev/cu.usbmodem...       Select a CDC device explicitly
          --timeout S                        Bound handshake and each request
          --json                             Emit stable machine-readable JSON
        """)
    }
}
