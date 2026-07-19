/// A noncapturing, synchronous consumer of canonical input events. The event
/// pointer is valid only for the duration of the call. The opaque context is
/// owned by the installer and is never dereferenced or retained here.
typealias SynchronousInputEventHandler = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeRawPointer
) -> Void

enum SynchronousInputEventDispatchResult: Equatable {
    case delivered
    case noHandler
    case invalidEvent
}

/// The transport-to-runtime crossing for canonical input. Transport drivers
/// continue to publish into InputEventSink queues; the owner draining such a
/// queue calls this dispatcher after decoding a complete InputEvent.
///
/// Registration and dispatch must be externally serialized. Dispatch itself
/// is allocation-free and completes the installed handler before returning.
/// Capturing the handler and context before the call makes it safe for a
/// handler to uninstall or replace itself for subsequent events.
enum SynchronousInputEventDispatcher {
    private nonisolated(unsafe) static var installedHandler:
        SynchronousInputEventHandler?
    private nonisolated(unsafe) static var installedContext:
        UnsafeMutableRawPointer?

    static var hasHandler: Bool {
        installedHandler != nil
    }

    static func install(
        _ handler: SynchronousInputEventHandler,
        context: UnsafeMutableRawPointer? = nil
    ) {
        // Publish the context before the callable endpoint. Callers serialize
        // installation against dispatch, but this ordering also avoids a new
        // handler observing an old context during simple bring-up code.
        installedContext = context
        installedHandler = handler
    }

    static func uninstall() {
        // Withdraw the callable endpoint before releasing its context.
        installedHandler = nil
        installedContext = nil
    }

    @discardableResult
    static func dispatch(
        _ event: InputEvent
    ) -> SynchronousInputEventDispatchResult {
        guard InputEventWireCodec.isWellFormed(event) else {
            return .invalidEvent
        }
        guard let handler = installedHandler else {
            return .noHandler
        }
        let context = installedContext
        withUnsafePointer(to: event) { eventPointer in
            handler(context, UnsafeRawPointer(eventPointer))
        }
        return .delivered
    }
}
