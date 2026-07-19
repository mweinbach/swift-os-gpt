import Darwin
import Foundation

private struct USBUpdateOptions {
    let requestedDevicePath: String?
    let imagePath: String?
    let listDevices: Bool
    let dryRun: Bool
    let showHelp: Bool
    let chunkByteCount: Int
    let statusTimeoutSeconds: Double
    let connectTimeoutSeconds: Double
    let maximumReconnects: Int

    static func parse(_ arguments: [String]) throws -> Self {
        var devicePath: String?
        var imagePath: String?
        var listDevices = false
        var dryRun = false
        var showHelp = false
        var chunkByteCount = USBUpdateLimits.defaultChunkByteCount
        var statusTimeoutSeconds = 3.0
        var connectTimeoutSeconds = 30.0
        var maximumReconnects = 10

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--device":
                devicePath = try value(after: argument, in: arguments,
                                       index: &index)
            case "--image":
                imagePath = try value(after: argument, in: arguments,
                                      index: &index)
            case "--chunk-size":
                let raw = try value(after: argument, in: arguments,
                                    index: &index)
                guard let parsed = Int(raw) else {
                    throw USBUpdateOptionError.invalidValue(argument, raw)
                }
                chunkByteCount = parsed
            case "--status-timeout":
                let raw = try value(after: argument, in: arguments,
                                    index: &index)
                guard let parsed = Double(raw), parsed > 0 else {
                    throw USBUpdateOptionError.invalidValue(argument, raw)
                }
                statusTimeoutSeconds = parsed
            case "--connect-timeout":
                let raw = try value(after: argument, in: arguments,
                                    index: &index)
                guard let parsed = Double(raw), parsed > 0 else {
                    throw USBUpdateOptionError.invalidValue(argument, raw)
                }
                connectTimeoutSeconds = parsed
            case "--reconnects":
                let raw = try value(after: argument, in: arguments,
                                    index: &index)
                guard let parsed = Int(raw), parsed >= 0, parsed <= 100 else {
                    throw USBUpdateOptionError.invalidValue(argument, raw)
                }
                maximumReconnects = parsed
            case "--list":
                listDevices = true
            case "--dry-run":
                dryRun = true
            case "--help", "-h":
                showHelp = true
            default:
                throw USBUpdateOptionError.unknownArgument(argument)
            }
            index += 1
        }
        return Self(
            requestedDevicePath: devicePath,
            imagePath: imagePath,
            listDevices: listDevices,
            dryRun: dryRun,
            showHelp: showHelp,
            chunkByteCount: chunkByteCount,
            statusTimeoutSeconds: statusTimeoutSeconds,
            connectTimeoutSeconds: connectTimeoutSeconds,
            maximumReconnects: maximumReconnects
        )
    }

    private static func value(
        after option: String,
        in arguments: [String],
        index: inout Int
    ) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw USBUpdateOptionError.missingValue(option)
        }
        return arguments[index]
    }
}

private enum USBUpdateOptionError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)

    var description: String {
        switch self {
        case .missingValue(let option):
            return "\(option) requires a value"
        case .invalidValue(let option, let value):
            return "invalid value for \(option): \(value)"
        case .unknownArgument(let argument):
            return "unknown argument: \(argument)"
        }
    }
}

private enum USBUpdateRunError: Error, CustomStringConvertible {
    case imageRequired
    case imageNotRegularFile(String)
    case imageTooLarge(UInt64)
    case deviceSelectionRequired([String])
    case deviceWaitTimedOut(String)
    case reconnectLimitReached(Int, String)
    case missingDataFrame(UInt64)

    var description: String {
        switch self {
        case .imageRequired:
            return "--image is required unless --list or --help is used"
        case .imageNotRegularFile(let path):
            return "image is not a readable regular file: \(path)"
        case .imageTooLarge(let count):
            return "image is \(count) bytes; maximum is \(USBUpdateLimits.maximumArtifactByteCount)"
        case .deviceSelectionRequired(let paths):
            return "multiple USB modem devices found; pass --device with one of: \(paths.joined(separator: ", "))"
        case .deviceWaitTimedOut(let description):
            return "timed out waiting for \(description)"
        case .reconnectLimitReached(let count, let reason):
            return "update did not complete after \(count) reconnects: \(reason)"
        case .missingDataFrame(let offset):
            return "cannot construct a data frame at offset \(offset)"
        }
    }
}

private final class USBUpdateRunner {
    private let artifact: USBUpdateArtifact
    private let options: USBUpdateOptions

    init(artifact: USBUpdateArtifact, options: USBUpdateOptions) {
        self.artifact = artifact
        self.options = options
    }

    func run() throws {
        var reconnectCount = 0
        var lastFailure = "device was not opened"

        while reconnectCount <= options.maximumReconnects {
            do {
                let path = try waitForDevice()
                printStatus("connecting to \(path)")
                let connection = try USBUpdateSerialConnection(path: path)
                let finished = try transfer(over: connection)
                if finished { return }
            } catch let error as USBUpdateStatusValidationError {
                // A protocol or remote rejection is deterministic. Retrying
                // cannot make the exact same artifact safe to install.
                throw error
            } catch let error as USBUpdateRunError {
                switch error {
                case .deviceSelectionRequired, .missingDataFrame,
                     .imageRequired, .imageNotRegularFile, .imageTooLarge:
                    throw error
                case .deviceWaitTimedOut, .reconnectLimitReached:
                    lastFailure = error.description
                }
            } catch {
                lastFailure = String(describing: error)
            }

            reconnectCount += 1
            guard reconnectCount <= options.maximumReconnects else { break }
            printStatus(
                "transport interrupted (\(lastFailure)); reconnect \(reconnectCount)/\(options.maximumReconnects)"
            )
            usleep(250_000)
        }
        throw USBUpdateRunError.reconnectLimitReached(
            reconnectCount,
            lastFailure
        )
    }

    private func transfer(over connection: USBUpdateSerialConnection) throws
        -> Bool
    {
        let begin = artifact.beginFrame()
        let beginResponse = try connection.exchange(
            begin,
            timeoutSeconds: options.statusTimeoutSeconds
        )
        let beginStatus = try artifact.validateStatus(beginResponse)
        if beginStatus.code == .committed,
           beginStatus.phase == .committed
        {
            printStatus("device reports this image is already committed")
            return true
        }

        let negotiatedChunkByteCount: Int
        if beginStatus.acceptedChunkByteCount == 0 {
            negotiatedChunkByteCount = artifact.chunkByteCount
        } else {
            negotiatedChunkByteCount = Int(
                beginStatus.acceptedChunkByteCount
            )
        }
        var offset = beginStatus.nextOffset
        printStatus(
            "device accepted \(negotiatedChunkByteCount)-byte chunks; resuming at \(offset)/\(artifact.bytes.count)"
        )

        while offset < UInt64(artifact.bytes.count) {
            guard let data = artifact.dataFrame(
                at: offset,
                chunkByteCount: negotiatedChunkByteCount
            ) else {
                throw USBUpdateRunError.missingDataFrame(offset)
            }
            let dataByteCount = data.payload.count
                - USBUpdateLimits.dataPrefixByteCount
            let expectedOffset = offset + UInt64(dataByteCount)
            let response = try connection.exchange(
                data,
                timeoutSeconds: options.statusTimeoutSeconds,
                acceptingStatus: { frame in
                    statusReaches(frame, offset: expectedOffset)
                }
            )
            _ = try artifact.validateStatus(
                response,
                expectedNextOffset: expectedOffset,
                effectiveChunkByteCount: negotiatedChunkByteCount
            )
            offset = expectedOffset
            reportProgress(offset: offset)
        }

        let commit = artifact.commitFrame(
            chunkByteCount: negotiatedChunkByteCount
        )
        printStatus("all bytes acknowledged; requesting SHA-256 commit")
        do {
            let response = try connection.exchange(
                commit,
                timeoutSeconds: options.statusTimeoutSeconds,
                acceptingStatus: { frame in
                    statusIsCommitOrFailure(frame)
                }
            )
            _ = try artifact.validateStatus(
                response,
                expectedNextOffset: UInt64(artifact.bytes.count),
                effectiveChunkByteCount: negotiatedChunkByteCount,
                commit: true
            )
        } catch let error as USBUpdateStatusValidationError {
            connection.sendBestEffort(
                abortFrame(reason: 1),
                timeoutSeconds: min(options.statusTimeoutSeconds, 1)
            )
            throw error
        }
        printStatus("device verified and committed the update")
        return true
    }

    private func waitForDevice() throws -> String {
        let deadline = Date().addingTimeInterval(
            options.connectTimeoutSeconds
        )
        while Date() < deadline {
            if let requested = options.requestedDevicePath {
                if FileManager.default.fileExists(atPath: requested) {
                    return requested
                }
            } else {
                let paths = USBUpdateSerialDiscovery.devicePaths()
                if paths.count == 1 { return paths[0] }
                if paths.count > 1 {
                    throw USBUpdateRunError.deviceSelectionRequired(paths)
                }
            }
            usleep(250_000)
        }
        throw USBUpdateRunError.deviceWaitTimedOut(
            options.requestedDevicePath ?? "/dev/cu.usbmodem*"
        )
    }

    private func abortFrame(reason: UInt32) -> USBUpdateFrame {
        var payload: [UInt8] = [
            UInt8(truncatingIfNeeded: reason),
            UInt8(truncatingIfNeeded: reason >> 8),
            UInt8(truncatingIfNeeded: reason >> 16),
            UInt8(truncatingIfNeeded: reason >> 24),
        ]
        // Keep this mutable construction explicit so the wire payload cannot
        // accidentally become a platform-sized integer.
        payload.reserveCapacity(4)
        return USBUpdateFrame(
            kind: .abort,
            transferID: artifact.transferID,
            sequence: 0,
            payload: payload
        )
    }

    private func reportProgress(offset: UInt64) {
        let total = UInt64(artifact.bytes.count)
        let percent = total == 0 ? 100 : Int(offset * 100 / total)
        printStatus("uploaded \(offset)/\(total) bytes (\(percent)%)")
    }
}

@main
struct USBUpdateMain {
    static func main() {
        do {
            let options = try USBUpdateOptions.parse(CommandLine.arguments)
            if options.showHelp {
                print(usage)
                return
            }
            if options.listDevices {
                let paths = USBUpdateSerialDiscovery.devicePaths()
                if paths.isEmpty {
                    print("No /dev/cu.usbmodem* devices found")
                } else {
                    paths.forEach { print($0) }
                }
                return
            }
            guard let imagePath = options.imagePath else {
                throw USBUpdateRunError.imageRequired
            }
            let imageBytes = try readBoundedImage(at: imagePath)
            let artifact = try USBUpdateArtifact(
                validatingRaspberryPi5Image: imageBytes,
                chunkByteCount: options.chunkByteCount
            )
            printValidation(artifact: artifact, path: imagePath)
            if options.dryRun {
                print("Dry run complete; no USB device was opened")
                return
            }
            try USBUpdateRunner(artifact: artifact, options: options).run()
        } catch {
            fputs("swiftos-usb-update: \(error)\n\n\(usage)\n", stderr)
            Darwin.exit(2)
        }
    }

    private static func readBoundedImage(at path: String) throws -> [UInt8] {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else {
            throw USBUpdateRunError.imageNotRegularFile(path)
        }
        let byteCount = size.uint64Value
        guard byteCount <= UInt64(USBUpdateLimits.maximumArtifactByteCount)
        else {
            throw USBUpdateRunError.imageTooLarge(byteCount)
        }
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path),
                                options: .mappedIfSafe))
    }

    private static func printValidation(
        artifact: USBUpdateArtifact,
        path: String
    ) {
        print("Validated Raspberry Pi 5 AArch64 image: \(path)")
        print("  bytes: \(artifact.bytes.count)")
        print("  requested chunk bytes: \(artifact.chunkByteCount)")
        print("  requested chunks: \(artifact.totalChunkCount)")
        print("  transfer ID: \(hex32(artifact.transferID))")
        print("  image CRC32: \(hex32(artifact.imageCRC32))")
        print("  SHA-256: \(artifact.sha256.map { String(format: "%02x", $0) }.joined())")
    }

    private static let usage = """
    Usage: swiftos-usb-update --image PATH [options]
           swiftos-usb-update --list

    Options:
      --device PATH          Use one explicit /dev/cu.usbmodem* device.
      --image PATH           Raspberry Pi 5 kernel8.img to stage and commit.
      --dry-run              Validate and hash the image without opening USB.
      --chunk-size BYTES     Request 64...4096 bytes (default 456).
      --status-timeout SEC   Per-request status deadline (default 3).
      --connect-timeout SEC  Device discovery deadline per attempt (default 30).
      --reconnects COUNT     Reconnect/resume attempts, 0...100 (default 10).
      --list                 List candidate CDC ACM tty paths.
      --help                 Show this help.

    The device stages exact-offset chunks, verifies the complete SHA-256, and
    must acknowledge COMMIT before this command reports success. Transport
    interruptions restart with idempotent BEGIN and resume at the device's
    acknowledged offset.
    """
}

private func printStatus(_ message: String) {
    fputs("swiftos-usb-update: \(message)\n", stderr)
}

private func hex32(_ value: UInt32) -> String {
    "0x" + String(value, radix: 16)
}

private func statusReaches(_ frame: USBUpdateFrame, offset: UInt64) -> Bool {
    guard let status = USBUpdateStatus(payload: frame.payload) else {
        return true
    }
    return status.code.isFailure || status.phase == .rejected
        || status.nextOffset >= offset
}

private func statusIsCommitOrFailure(_ frame: USBUpdateFrame) -> Bool {
    guard let status = USBUpdateStatus(payload: frame.payload) else {
        return true
    }
    return status.code.isFailure || status.phase == .rejected
        || (status.code == .committed && status.phase == .committed)
}
