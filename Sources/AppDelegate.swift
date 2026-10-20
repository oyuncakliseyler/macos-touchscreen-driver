import AppKit
import IOKit.hid
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let reader = TouchReader()
    private let cursor = CursorHider()
    private lazy var injector = PointerInjector(cursor: cursor)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        requestPermissions()
        applySettings()

        reader.onSample = { [weak self] sample in self?.handle(sample) }
        reader.onDevicesChanged = { [weak self] in self?.updateIcon() }
        reader.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        injector.reset()
        cursor.show()
        reader.stop()
    }

    // MARK: - Touch handling

    private func handle(_ sample: TouchSample) {
        guard Settings.enabled else { return }
        let display = DisplayInfo.resolve(uuid: Settings.displayUUID)
        let rotation = Settings.rotationOverride ?? Int(CGDisplayRotation(display).rounded())
        let mapper = TouchMapper(swapXY: Settings.swapXY, flipX: Settings.flipX, flipY: Settings.flipY)
        let point = mapper.point(u: sample.u, v: sample.v, rotation: rotation, bounds: CGDisplayBounds(display))
        injector.touch(at: point, touching: sample.touching)
    }

    private func applySettings() {
        cursor.enabled = Settings.hideCursor
        injector.longPressRightClick = Settings.longPressRightClick
    }

    // MARK: - Permissions

    private var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    private var hasAccessibility: Bool { CGPreflightPostEventAccess() }

    private func requestPermissions() {
        if !hasInputMonitoring { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        if !hasAccessibility { _ = CGRequestPostEventAccess() }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Menu

    private func updateIcon() {
        let symbol = reader.summaries.isEmpty ? "hand.point.up.left" : "hand.point.up.left.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TouchDriver")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !Settings.enabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Permissions granted while running need a fresh open of the devices.
        if reader.summaries.isEmpty || reader.openFailed { reader.start() }
        menu.removeAllItems()

        let devices = reader.summaries
        if devices.isEmpty {
            menu.addItem(info("No touchscreen found"))
        }
        for device in devices {
            menu.addItem(info(device.exclusive ? device.name : "\(device.name) (shared — may double-move)"))
        }
        if !hasInputMonitoring {
            menu.addItem(item("Grant Input Monitoring…") { [weak self] in self?.openPrivacyPane("Privacy_ListenEvent") })
        }
        if !hasAccessibility {
            menu.addItem(item("Grant Accessibility…") { [weak self] in self?.openPrivacyPane("Privacy_Accessibility") })
        }
        menu.addItem(.separator())

        menu.addItem(toggle("Enabled", Settings.enabled) { [weak self] in
            Settings.enabled.toggle()
            if !Settings.enabled { self?.injector.reset(); self?.cursor.show() }
            self?.updateIcon()
        })
        menu.addItem(submenu("Screen", screenItems()))
        menu.addItem(submenu("Rotation", rotationItems()))
        menu.addItem(submenu("Calibration", [
            toggle("Swap X and Y", Settings.swapXY) { Settings.swapXY.toggle() },
            toggle("Flip X", Settings.flipX) { Settings.flipX.toggle() },
            toggle("Flip Y", Settings.flipY) { Settings.flipY.toggle() },
        ]))
        menu.addItem(.separator())

        menu.addItem(toggle("Hide Cursor While Touching", Settings.hideCursor) { [weak self] in
            Settings.hideCursor.toggle()
            self?.applySettings()
        })
        menu.addItem(toggle("Touch and Hold for Right-Click", Settings.longPressRightClick) { [weak self] in
            Settings.longPressRightClick.toggle()
            self?.applySettings()
        })
        menu.addItem(toggle("Start at Login", SMAppService.mainApp.status == .enabled) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSLog("TouchDriver: login item change failed: %@", error.localizedDescription)
            }
        })
        menu.addItem(.separator())
        menu.addItem(item("Quit TouchDriver", key: "q") { NSApp.terminate(nil) })
    }

    private func screenItems() -> [NSMenuItem] {
        let selected = Settings.displayUUID
        let active = DisplayInfo.resolve(uuid: selected)
        var items = [toggle("Main Screen (with menu bar)", selected == nil) { Settings.displayUUID = nil }]
        items.append(.separator())
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let uuid = DisplayInfo.uuidString(for: id)
            let size = CGDisplayBounds(id).size
            let rotation = Int(CGDisplayRotation(id).rounded())
            var title = "\(screen.localizedName) — \(Int(size.width))×\(Int(size.height))"
            if rotation != 0 { title += ", rotated \(rotation)°" }
            items.append(toggle(title, selected != nil && id == active) { Settings.displayUUID = uuid })
        }
        return items
    }

    private func rotationItems() -> [NSMenuItem] {
        let current = Settings.rotationOverride
        let display = DisplayInfo.resolve(uuid: Settings.displayUUID)
        let system = Int(CGDisplayRotation(display).rounded())
        var items = [toggle("Automatic (currently \(system)°)", current == nil) { Settings.rotationOverride = nil }]
        items.append(.separator())
        for angle in [0, 90, 180, 270] {
            items.append(toggle("\(angle)°", current == angle) { Settings.rotationOverride = angle })
        }
        return items
    }

    // MARK: - Menu item helpers

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: "", action: action)
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }
}

/// NSMenuItem that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
