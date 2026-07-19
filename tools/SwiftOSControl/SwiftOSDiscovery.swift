import Foundation
import IOKit

struct SwiftOSUSBDevice: Codable, Equatable {
    let registryID: UInt64
    let vendorID: Int
    let productID: Int
    let productName: String?
    let serialNumber: String?
    let ttyPaths: [String]

    var isSwiftOS: Bool {
        vendorID == SwiftOSUSBIdentity.vendorID
            && productID == SwiftOSUSBIdentity.productID
    }
}

struct SwiftOSHostSnapshot: Codable, Equatable {
    let usbDevices: [SwiftOSUSBDevice]
    let cdcTTYPaths: [String]
}

protocol SwiftOSDiscoveryProvider {
    func snapshot() throws -> SwiftOSHostSnapshot
}

enum SwiftOSUSBIdentity {
    static let vendorID = 0x1209
    static let productID = 0x5a17
}

enum SwiftOSDiagnosticStage: String, Codable {
    case absent
    case enumerated
    case noTTY
    case ready
}

struct SwiftOSDoctorReport: Codable, Equatable {
    let stage: SwiftOSDiagnosticStage
    let ready: Bool
    let expectedVendorID: String
    let expectedProductID: String
    let devices: [SwiftOSUSBDevice]
    let cdcTTYPaths: [String]
    let summary: String
    let remediation: String
}

enum SwiftOSDoctor {
    static func report(from snapshot: SwiftOSHostSnapshot) -> SwiftOSDoctorReport {
        let devices = snapshot.usbDevices
            .filter(\.isSwiftOS)
            .sorted {
                if $0.serialNumber != $1.serialNumber {
                    return ($0.serialNumber ?? "") < ($1.serialNumber ?? "")
                }
                return $0.registryID < $1.registryID
            }
        let associatedTTYs = Array(
            Set(devices.flatMap(\.ttyPaths))
        ).sorted()

        let stage: SwiftOSDiagnosticStage
        let summary: String
        let remediation: String
        if devices.isEmpty {
            stage = .absent
            summary = "SwiftOS USB device is absent."
            remediation = "Confirm the Pi is booting with separate supported power, leave its USB-C OTG port dedicated to a data-capable cable, and inspect HDMI or UART10. No macOS driver is involved before USB enumeration."
        } else if associatedTTYs.isEmpty {
            stage = .noTTY
            summary = "SwiftOS USB enumerated, but no associated CDC tty exists."
            remediation = "Wait a few seconds and reconnect the data cable. If the tty remains absent, inspect SwiftOS DWC2/CDC configuration and the Pi boot log."
        } else if devices.count != 1 || associatedTTYs.count != 1 {
            stage = .enumerated
            summary = "SwiftOS USB enumerated, but the control endpoint is ambiguous."
            remediation = "Disconnect extra SwiftOS devices or select one by its serial number and tty path."
        } else {
            stage = .ready
            summary = "SwiftOS USB control transport is ready."
            remediation = "None. The built-in macOS CDC driver exposes the device without a custom driver."
        }

        return SwiftOSDoctorReport(
            stage: stage,
            ready: stage == .ready,
            expectedVendorID: String(format: "0x%04x", SwiftOSUSBIdentity.vendorID),
            expectedProductID: String(format: "0x%04x", SwiftOSUSBIdentity.productID),
            devices: devices,
            cdcTTYPaths: snapshot.cdcTTYPaths.sorted(),
            summary: summary,
            remediation: remediation
        )
    }
}

/// Reads the macOS I/O Registry directly. The SwiftOS gadget uses USB CDC ACM,
/// which is handled by Apple's built-in driver; no kernel extension is needed.
struct SwiftOSIOKitDiscoveryProvider: SwiftOSDiscoveryProvider {
    func snapshot() throws -> SwiftOSHostSnapshot {
        var recordsByRegistryID: [UInt64: SwiftOSUSBDevice] = [:]
        for service in services(matching: "IOUSBHostDevice") {
            defer { IOObjectRelease(service) }
            guard let vendorID = integerProperty(service, "idVendor"),
                  let productID = integerProperty(service, "idProduct")
            else { continue }

            let registryID = entryID(service)
            recordsByRegistryID[registryID] = SwiftOSUSBDevice(
                registryID: registryID,
                vendorID: vendorID,
                productID: productID,
                productName: stringProperty(service, "USB Product Name"),
                serialNumber: stringProperty(service, "USB Serial Number"),
                ttyPaths: []
            )
        }

        var allCDCPaths: [String] = []
        var associatedPaths: [UInt64: [String]] = [:]
        for service in services(matching: "IOSerialBSDClient") {
            defer { IOObjectRelease(service) }
            guard let path = stringProperty(service, "IOCalloutDevice"),
                  path.hasPrefix("/dev/cu.usbmodem")
            else { continue }
            allCDCPaths.append(path)

            guard let ancestor = swiftOSUSBAncestor(of: service) else {
                continue
            }
            associatedPaths[ancestor.registryID, default: []].append(path)
            if recordsByRegistryID[ancestor.registryID] == nil {
                recordsByRegistryID[ancestor.registryID] = ancestor.device
            }
        }

        let devices = recordsByRegistryID.values.map { device in
            SwiftOSUSBDevice(
                registryID: device.registryID,
                vendorID: device.vendorID,
                productID: device.productID,
                productName: device.productName,
                serialNumber: device.serialNumber,
                ttyPaths: Array(
                    Set(associatedPaths[device.registryID] ?? [])
                ).sorted()
            )
        }.sorted { $0.registryID < $1.registryID }

        return SwiftOSHostSnapshot(
            usbDevices: devices,
            cdcTTYPaths: Array(Set(allCDCPaths)).sorted()
        )
    }

    private func services(matching className: String) -> [io_object_t] {
        guard let matching = IOServiceMatching(className) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [io_object_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            result.append(service)
        }
        return result
    }

    private func swiftOSUSBAncestor(
        of entry: io_registry_entry_t
    ) -> (registryID: UInt64, device: SwiftOSUSBDevice)? {
        var current = entry
        var ownsCurrent = false
        defer {
            if ownsCurrent { IOObjectRelease(current) }
        }

        for _ in 0..<16 {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0,
               integerProperty(current, "idVendor")
                    == SwiftOSUSBIdentity.vendorID,
               integerProperty(current, "idProduct")
                    == SwiftOSUSBIdentity.productID
            {
                let id = entryID(current)
                return (
                    id,
                    SwiftOSUSBDevice(
                        registryID: id,
                        vendorID: SwiftOSUSBIdentity.vendorID,
                        productID: SwiftOSUSBIdentity.productID,
                        productName: stringProperty(
                            current,
                            "USB Product Name"
                        ),
                        serialNumber: stringProperty(
                            current,
                            "USB Serial Number"
                        ),
                        ttyPaths: []
                    )
                )
            }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(
                current,
                kIOServicePlane,
                &parent
            ) == KERN_SUCCESS else { return nil }
            if ownsCurrent { IOObjectRelease(current) }
            current = parent
            ownsCurrent = true
        }
        return nil
    }

    private func entryID(_ entry: io_registry_entry_t) -> UInt64 {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &identifier)
                == KERN_SUCCESS
        else { return 0 }
        return identifier
    }

    private func integerProperty(
        _ entry: io_registry_entry_t,
        _ key: String
    ) -> Int? {
        property(entry, key) as? Int
    }

    private func stringProperty(
        _ entry: io_registry_entry_t,
        _ key: String
    ) -> String? {
        property(entry, key) as? String
    }

    private func property(
        _ entry: io_registry_entry_t,
        _ key: String
    ) -> Any? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }
}
