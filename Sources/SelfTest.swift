import CoreGraphics
import Foundation

/// Checks the touch-to-screen mapping for every rotation and calibration toggle.
enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func expect(_ got: (x: Double, y: Double), _ want: (Double, Double), _ label: String) {
            if abs(got.x - want.0) > 1e-9 || abs(got.y - want.1) > 1e-9 {
                print("FAIL \(label): got (\(got.x), \(got.y)), want \(want)")
                failures += 1
            }
        }

        let plain = TouchMapper()
        // Panel top-left corner (0, 0) and a point near the top edge, right of centre (0.75, 0.1).
        expect(plain.normalized(u: 0, v: 0, rotation: 0), (0, 0), "0° corner")
        expect(plain.normalized(u: 0.75, v: 0.1, rotation: 0), (0.75, 0.1), "0° point")
        // Monitor turned 90° clockwise: panel's top edge is now on the right of the desktop.
        expect(plain.normalized(u: 0.75, v: 0.1, rotation: 90), (0.9, 0.75), "90° point")
        expect(plain.normalized(u: 0, v: 1, rotation: 90), (0, 0), "90° desktop top-left")
        expect(plain.normalized(u: 0.75, v: 0.1, rotation: 180), (0.25, 0.9), "180° point")
        expect(plain.normalized(u: 0.75, v: 0.1, rotation: 270), (0.1, 0.25), "270° point")
        expect(plain.normalized(u: 1, v: 0, rotation: 270), (0, 0), "270° desktop top-left")
        expect(plain.normalized(u: 0.75, v: 0.1, rotation: -90), (0.1, 0.25), "-90° wraps to 270°")

        expect(TouchMapper(swapXY: true).normalized(u: 0.75, v: 0.1, rotation: 0), (0.1, 0.75), "swap")
        expect(TouchMapper(flipX: true).normalized(u: 0.75, v: 0.1, rotation: 0), (0.25, 0.1), "flip X")
        expect(TouchMapper(flipY: true).normalized(u: 0.75, v: 0.1, rotation: 0), (0.75, 0.9), "flip Y")

        // Point on a 1080×1920 portrait display placed right of a 1512-wide main display.
        let bounds = CGRect(x: 1512, y: 0, width: 1080, height: 1920)
        let p = plain.point(u: 1, v: 1, rotation: 0, bounds: bounds)
        if p != CGPoint(x: 2591, y: 1919) { print("FAIL bounds: got \(p)"); failures += 1 }
        let clamped = plain.point(u: -0.2, v: 1.4, rotation: 0, bounds: bounds)
        if clamped != CGPoint(x: 1512, y: 1919) { print("FAIL clamp: got \(clamped)"); failures += 1 }

        print(failures == 0 ? "All mapping tests passed" : "\(failures) mapping test(s) failed")
        return failures == 0
    }
}
