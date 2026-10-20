import AppKit
import CoreGraphics

/// Hides the cursor while the touchscreen is in use and shows it again as soon as a
/// real mouse or trackpad moves.
///
/// macOS only lets the frontmost app hide the cursor. A background helper has to set
/// the private "SetsCursorInBackground" connection property first; this is the same
/// trick other cursor utilities use and is not an official API.
final class CursorHider {
    /// Marks events we post ourselves, so the mouse monitor can tell them apart.
    static let eventMarker: Int64 = 0x544F_5543 // "TOUC"

    var enabled = true {
        didSet { if !enabled { show() } }
    }
    private(set) var hidden = false
    private var monitor: Any?

    init() {
        allowBackgroundCursorControl()
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                       .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, self.hidden else { return }
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == CursorHider.eventMarker { return }
            self.show()
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        show()
    }

    func hide() {
        guard enabled, !hidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }

    private func allowBackgroundCursorControl() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else {
            NSLog("TouchDriver: background cursor hiding unavailable")
            return
        }
        let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
        let setProperty = unsafeBitCast(setSym, to: SetProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
