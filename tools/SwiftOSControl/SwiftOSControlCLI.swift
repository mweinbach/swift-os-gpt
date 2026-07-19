import Darwin
import Foundation

private enum SwiftOSControlCommand {
    case discover(json: Bool)
    case doctor(json: Bool)
    case waitReady(json: Bool, timeout: Double)
    case help
}

private enum SwiftOSControlOptionError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case invalidTimeout(String)

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
        guard ["discover", "doctor", "wait-ready"].contains(name) else {
            throw SwiftOSControlOptionError.unknownCommand(name)
        }

        var json = false
        var timeout = 30.0
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                json = true
            case "--timeout" where name == "wait-ready":
                index += 1
                guard index < arguments.count else {
                    throw SwiftOSControlOptionError.missingValue("--timeout")
                }
                guard let value = Double(arguments[index]),
                      value >= 0,
                      value <= 3_600
                else {
                    throw SwiftOSControlOptionError.invalidTimeout(
                        arguments[index]
                    )
                }
                timeout = value
            default:
                throw SwiftOSControlOptionError.unknownOption(arguments[index])
            }
            index += 1
        }

        switch name {
        case "discover": return .discover(json: json)
        case "doctor": return .doctor(json: json)
        default: return .waitReady(json: json, timeout: timeout)
        }
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
            }
        } catch {
            fputs("swiftosctl: \(error)\n", stderr)
            exit(64)
        }
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
        """)
    }
}
