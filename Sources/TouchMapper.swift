import ColorSync
import CoreGraphics
import Foundation

/// Converts a normalized touch-panel position (0...1 on both axes, in the panel's
/// native orientation) into a global screen point on the target display.
struct TouchMapper {
    var swapXY = false
    var flipX = false
    var flipY = false

    /// Applies calibration toggles, then display rotation.
    /// `rotation` is the display rotation in degrees as reported by CGDisplayRotation
    /// (0, 90, 180, 270). Returns a normalized point in the rotated desktop space.
    func normalized(u: Double, v: Double, rotation: Int) -> (x: Double, y: Double) {
        var u = u, v = v
        if swapXY { swap(&u, &v) }
        if flipX { u = 1 - u }
        if flipY { v = 1 - v }

        switch ((rotation % 360) + 360) % 360 {
        case 90:  return (1 - v, u)
        case 180: return (1 - u, 1 - v)
        case 270: return (v, 1 - u)
        default:  return (u, v)
        }
    }

    /// Maps into global CoreGraphics coordinates (top-left origin), clamped inside `bounds`.
    func point(u: Double, v: Double, rotation: Int, bounds: CGRect) -> CGPoint {
        let n = normalized(u: clamp(u), v: clamp(v), rotation: rotation)
        // Keep the point strictly inside the display so it never lands on a neighbour.
        let x = bounds.minX + CGFloat(n.x) * (bounds.width - 1)
        let y = bounds.minY + CGFloat(n.y) * (bounds.height - 1)
        return CGPoint(x: x, y: y)
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

enum DisplayInfo {
    /// Active displays, excluding the secondary members of mirror sets.
    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    static func uuidString(for display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Resolves a saved display UUID; nil (or a display that is gone) means the main display.
    static func resolve(uuid: String?) -> CGDirectDisplayID {
        if let uuid {
            for id in activeDisplays() where uuidString(for: id) == uuid { return id }
        }
        return CGMainDisplayID()
    }
}
