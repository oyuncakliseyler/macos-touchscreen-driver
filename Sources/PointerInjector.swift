import AppKit
import CoreGraphics

/// Turns touch-down / move / up into standard mouse events.
///
/// - Tap: left click (double and triple clicks are counted like a real mouse).
/// - Touch and move: left drag.
/// - Touch and hold without moving (if enabled): right click.
final class PointerInjector {
    var longPressRightClick = true
    var longPressDelay: TimeInterval = 0.7
    /// Movement (in points) that turns a touch into a drag rather than a tap.
    var dragSlop: CGFloat = 8

    let cursor: CursorHider

    private enum State {
        case idle
        case pending(start: CGPoint, last: CGPoint)   // finger down, not yet a drag
        case dragging(last: CGPoint)
        case rightClicked                            // long press fired; wait for lift
    }
    private var state = State.idle
    private var longPressTimer: Timer?
    private var clickCount = 0
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private let source: CGEventSource?

    init(cursor: CursorHider) {
        self.cursor = cursor
        source = CGEventSource(stateID: .hidSystemState)
        source?.userData = CursorHider.eventMarker
    }

    func touch(at point: CGPoint, touching: Bool) {
        switch (state, touching) {
        case (.idle, true):
            cursor.hide()
            post(.mouseMoved, at: point, button: .left)
            if longPressRightClick {
                state = .pending(start: point, last: point)
                startLongPressTimer()
            } else {
                post(.leftMouseDown, at: point, button: .left, clicks: nextClickCount(at: point))
                state = .dragging(last: point)
            }

        case (.pending(let start, _), true):
            if hypot(point.x - start.x, point.y - start.y) > dragSlop {
                cancelLongPress()
                post(.leftMouseDown, at: start, button: .left, clicks: nextClickCount(at: start))
                post(.leftMouseDragged, at: point, button: .left)
                state = .dragging(last: point)
            } else {
                state = .pending(start: start, last: point)
            }

        case (.pending(let start, _), false):
            cancelLongPress()
            let clicks = nextClickCount(at: start)
            post(.leftMouseDown, at: start, button: .left, clicks: clicks)
            post(.leftMouseUp, at: start, button: .left, clicks: clicks)
            state = .idle

        case (.dragging(let last), true):
            if point != last { post(.leftMouseDragged, at: point, button: .left) }
            state = .dragging(last: point)

        case (.dragging, false):
            post(.leftMouseUp, at: point, button: .left, clicks: clickCount)
            state = .idle

        case (.rightClicked, false):
            state = .idle

        case (.idle, false), (.rightClicked, true):
            break
        }
    }

    /// Releases anything still held, e.g. when the driver is switched off mid-touch.
    func reset() {
        cancelLongPress()
        if case .dragging(let last) = state {
            post(.leftMouseUp, at: last, button: .left, clicks: clickCount)
        }
        state = .idle
    }

    // MARK: - Helpers

    private func startLongPressTimer() {
        cancelLongPress()
        let timer = Timer(timeInterval: longPressDelay, repeats: false) { [weak self] _ in
            guard let self, case .pending(let start, _) = self.state else { return }
            self.post(.rightMouseDown, at: start, button: .right)
            self.post(.rightMouseUp, at: start, button: .right)
            self.clickCount = 0
            self.state = .rightClicked
        }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func nextClickCount(at point: CGPoint) -> Int {
        let now = ProcessInfo.processInfo.systemUptime
        let near = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < 20
        clickCount = (now - lastClickTime <= NSEvent.doubleClickInterval && near) ? min(clickCount + 1, 3) : 1
        lastClickTime = now
        lastClickPoint = point
        return clickCount
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clicks: Int = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clicks, 1)))
        event.setIntegerValueField(.eventSourceUserData, value: CursorHider.eventMarker)
        event.post(tap: .cghidEventTap)
    }
}
