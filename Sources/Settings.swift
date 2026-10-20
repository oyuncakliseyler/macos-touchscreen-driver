import Foundation

/// User preferences, stored in UserDefaults.
struct Settings {
    private static let defaults = UserDefaults.standard

    @Stored("enabled", true) static var enabled: Bool
    /// UUID of the display touches go to; nil means the main display (the one with the menu bar).
    @Stored("displayUUID", nil) static var displayUUID: String?
    /// nil follows the rotation set in System Settings → Displays; otherwise 0/90/180/270.
    @Stored("rotationOverride", nil) static var rotationOverride: Int?
    @Stored("swapXY", false) static var swapXY: Bool
    @Stored("flipX", false) static var flipX: Bool
    @Stored("flipY", false) static var flipY: Bool
    @Stored("hideCursor", true) static var hideCursor: Bool
    @Stored("longPressRightClick", true) static var longPressRightClick: Bool

    @propertyWrapper
    struct Stored<Value> {
        let key: String
        let fallback: Value

        init(_ key: String, _ fallback: Value) {
            self.key = key
            self.fallback = fallback
        }

        var wrappedValue: Value {
            get { Settings.defaults.object(forKey: key) as? Value ?? fallback }
            set {
                if let optional = newValue as? AnyOptional, optional.isNil {
                    Settings.defaults.removeObject(forKey: key)
                } else {
                    Settings.defaults.set(newValue, forKey: key)
                }
            }
        }
    }
}

private protocol AnyOptional { var isNil: Bool { get } }
extension Optional: AnyOptional { var isNil: Bool { self == nil } }
