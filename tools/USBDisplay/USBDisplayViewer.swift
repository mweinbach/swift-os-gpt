import AppKit
import CoreGraphics
import Darwin
import Dispatch
import Foundation

private struct USBDisplayViewerOptions {
    let requestedDevicePath: String?
    let listDevices: Bool
    let showHelp: Bool

    static func parse(_ arguments: [String]) throws -> Self {
        var requestedDevicePath: String?
        var listDevices = false
        var showHelp = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--device":
                index += 1
                guard index < arguments.count else {
                    throw USBDisplayViewerOptionError.missingDevicePath
                }
                requestedDevicePath = arguments[index]
            case "--list":
                listDevices = true
            case "--help", "-h":
                showHelp = true
            default:
                throw USBDisplayViewerOptionError.unknownArgument(
                    arguments[index]
                )
            }
            index += 1
        }
        return Self(
            requestedDevicePath: requestedDevicePath,
            listDevices: listDevices,
            showHelp: showHelp
        )
    }
}

private enum USBDisplayViewerOptionError: Error, CustomStringConvertible {
    case missingDevicePath
    case unknownArgument(String)

    var description: String {
        switch self {
        case .missingDevicePath:
            return "--device requires a path"
        case .unknownArgument(let argument):
            return "unknown argument: \(argument)"
        }
    }
}

@MainActor
private final class USBDisplayCanvasView: NSView {
    private var image: NSImage?
    private var displayMode: USBDebugDisplayMode?
    private var statusText = "Waiting for /dev/cu.usbmodem*"

    override var isFlipped: Bool { true }

    func setStatus(_ status: String) {
        statusText = status
        needsDisplay = true
    }

    func show(_ frame: USBDisplayCompletedFrame) -> Bool {
        guard let cgImage = makeImage(frame) else { return false }
        image = NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: Int(frame.mode.width),
                height: Int(frame.mode.height)
            )
        )
        displayMode = frame.mode
        statusText = "Frame \(frame.frameID)"
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        if let image, let displayMode {
            let target = aspectFit(
                width: CGFloat(displayMode.width),
                height: CGFloat(displayMode.height),
                in: bounds
            )
            image.draw(
                in: target,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [
                    .interpolation: interpolation(for: target, mode: displayMode)
                ]
            )
        }
        drawStatusBadge()
    }

    private func makeImage(_ frame: USBDisplayCompletedFrame) -> CGImage? {
        let expected = UInt64(frame.mode.bytesPerRow)
            * UInt64(frame.mode.height)
        guard expected == UInt64(frame.pixels.count) else { return nil }
        let data = Data(frame.pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        let alphaInfo: CGImageAlphaInfo
        switch frame.mode.pixelFormat {
        case .b8g8r8x8:
            alphaInfo = .noneSkipFirst
        case .b8g8r8a8:
            alphaInfo = .premultipliedFirst
        }
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
            .union(.byteOrder32Little)
        return CGImage(
            width: Int(frame.mode.width),
            height: Int(frame.mode.height),
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: Int(frame.mode.bytesPerRow),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func aspectFit(
        width: CGFloat,
        height: CGFloat,
        in available: NSRect
    ) -> NSRect {
        guard width > 0, height > 0 else { return available }
        let scale = min(available.width / width, available.height / height)
        let size = NSSize(width: width * scale, height: height * scale)
        return NSRect(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
    }

    private func interpolation(
        for target: NSRect,
        mode: USBDebugDisplayMode
    ) -> NSImageInterpolation {
        let horizontal = target.width / CGFloat(mode.width)
        let vertical = target.height / CGFloat(mode.height)
        let nearestInteger = horizontal.rounded()
        let isIntegerScale = abs(horizontal - nearestInteger) < 0.0001
            && abs(vertical - nearestInteger) < 0.0001
        return isIntegerScale ? .none : .high
    }

    private func drawStatusBadge() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: statusText, attributes: attributes)
        let textSize = text.size()
        let badge = NSRect(
            x: 12,
            y: 12,
            width: textSize.width + 16,
            height: textSize.height + 10
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
        text.draw(at: NSPoint(x: badge.minX + 8, y: badge.minY + 5))
    }
}

private struct USBDisplayModePresentation {
    let mode: USBDebugDisplayMode

    var logicalSize: NSSize {
        let scale = CGFloat(mode.scaleNumerator)
            / CGFloat(mode.scaleDenominator)
        return NSSize(
            width: CGFloat(mode.width) / scale,
            height: CGFloat(mode.height) / scale
        )
    }

    var title: String {
        var fields = [
            "\(mode.width)×\(mode.height)",
            scaleDescription,
        ]
        if mode.refreshRateMilliHertz != 0 {
            fields.append(
                String(
                    format: "%.3f Hz",
                    Double(mode.refreshRateMilliHertz) / 1_000
                )
            )
        }
        if let ppiDescription { fields.append(ppiDescription) }
        return "SwiftOS USB Display — " + fields.joined(separator: " · ")
    }

    var frameInterval: TimeInterval? {
        guard mode.refreshRateMilliHertz != 0 else { return nil }
        let hertz = min(
            240.0,
            max(1.0, Double(mode.refreshRateMilliHertz) / 1_000.0)
        )
        return 1.0 / hertz
    }

    private var scaleDescription: String {
        if mode.scaleDenominator == 1 {
            return "\(mode.scaleNumerator)× scale"
        }
        return "\(mode.scaleNumerator)/\(mode.scaleDenominator)× scale"
    }

    private var ppiDescription: String? {
        let horizontal = mode.horizontalPixelsPerInchMilli
        let vertical = mode.verticalPixelsPerInchMilli
        guard horizontal != 0 || vertical != 0 else { return nil }
        let samples = (horizontal != 0 ? 1 : 0) + (vertical != 0 ? 1 : 0)
        let total = UInt64(horizontal) + UInt64(vertical)
        let average = Double(total) / Double(samples) / 1_000.0
        return String(format: "%.1f PPI", average)
    }
}

/// Coalesces frames to the refresh cadence advertised by the guest. The newest
/// complete frame wins when USB delivery is faster than that cadence.
@MainActor
private final class USBDisplayFramePresenter {
    typealias Presentation = (USBDisplayCompletedFrame) -> Void

    private let presentation: Presentation
    private var pending: USBDisplayCompletedFrame?
    private var scheduled: DispatchWorkItem?
    private var lastPresentationTime: TimeInterval = 0

    init(presentation: @escaping Presentation) {
        self.presentation = presentation
    }

    func submit(_ frame: USBDisplayCompletedFrame) {
        pending = frame
        guard scheduled == nil else { return }
        let interval = USBDisplayModePresentation(mode: frame.mode)
            .frameInterval ?? 0
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, interval - (now - lastPresentationTime))
        if delay == 0 {
            presentPending()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.presentPending() }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func presentPending() {
        scheduled = nil
        guard let frame = pending else { return }
        pending = nil
        lastPresentationTime = ProcessInfo.processInfo.systemUptime
        presentation(frame)
    }
}

@MainActor
private final class USBDisplayApplicationDelegate: NSObject,
    NSApplicationDelegate, NSWindowDelegate {
    private let requestedDevicePath: String?
    private let canvas = USBDisplayCanvasView(
        frame: NSRect(x: 0, y: 0, width: 960, height: 540)
    )
    private var window: NSWindow?
    private var connection: USBDisplayConnectionManager?
    private var presenter: USBDisplayFramePresenter?
    private var configuredMode: USBDebugDisplayMode?

    init(requestedDevicePath: String?) {
        self.requestedDevicePath = requestedDevicePath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwiftOS USB Display"
        window.contentView = canvas
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        presenter = USBDisplayFramePresenter { [weak self] frame in
            self?.present(frame)
        }
        connection = USBDisplayConnectionManager(
            requestedPath: requestedDevicePath,
            onStatus: { [weak self] status in self?.canvas.setStatus(status) },
            onMode: { [weak self] mode in self?.configureWindow(for: mode) },
            onFrame: { [weak self] frame in self?.presenter?.submit(frame) }
        )
        connection?.start()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        connection?.stop()
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }

    private func configureWindow(for mode: USBDebugDisplayMode) {
        guard let window else { return }
        let presentation = USBDisplayModePresentation(mode: mode)
        window.title = presentation.title
        window.contentAspectRatio = NSSize(
            width: Int(mode.width),
            height: Int(mode.height)
        )
        if configuredMode != mode {
            let available = window.screen?.visibleFrame.size
                ?? NSScreen.main?.visibleFrame.size
                ?? NSSize(width: 1_280, height: 720)
            let maximum = NSSize(
                width: available.width * 0.85,
                height: available.height * 0.80
            )
            let scale = min(
                1,
                maximum.width / presentation.logicalSize.width,
                maximum.height / presentation.logicalSize.height
            )
            let fitted = NSSize(
                width: max(320, presentation.logicalSize.width * scale),
                height: max(200, presentation.logicalSize.height * scale)
            )
            window.setContentSize(fitted)
            window.center()
            configuredMode = mode
        }
    }

    private func present(_ frame: USBDisplayCompletedFrame) {
        configureWindow(for: frame.mode)
        if !canvas.show(frame) {
            canvas.setStatus("Rejected frame \(frame.frameID): invalid image")
        }
    }
}

@main
struct USBDisplayViewerMain {
    @MainActor
    static func main() {
        let options: USBDisplayViewerOptions
        do {
            options = try USBDisplayViewerOptions.parse(CommandLine.arguments)
        } catch {
            fputs("swiftos-usb-display: \(error)\n\n", stderr)
            fputs(usage, stderr)
            exit(2)
        }

        if options.showHelp {
            print(usage, terminator: "")
            return
        }
        if options.listDevices {
            let devices = USBSerialDiscovery.devicePaths()
            if devices.isEmpty {
                print("No /dev/cu.usbmodem* devices found")
            } else {
                devices.forEach { print($0) }
            }
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = USBDisplayApplicationDelegate(
            requestedDevicePath: options.requestedDevicePath
        )
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }

    private static let usage = """
    Usage: swiftos-usb-display [--device /dev/cu.usbmodemNAME]
           swiftos-usb-display --list

    With no --device argument, the viewer waits for and reconnects to the first
    /dev/cu.usbmodem* device. The SwiftOS display stream uses CDC data endpoint 2.

    Options:
      --device PATH  Wait for and open exactly PATH
      --list         List currently enumerated USB modem devices and exit
      --help, -h     Show this help
    """ + "\n"
}
