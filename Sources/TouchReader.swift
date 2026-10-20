import Foundation
import IOKit
import IOKit.hid

/// One frame of the primary contact, normalized to 0...1 in the panel's native orientation.
struct TouchSample {
    var u: Double
    var v: Double
    var touching: Bool
}

/// Reads USB touchscreens through IOHIDManager.
///
/// Matches HID digitizer touch screens (usage page 0x0D, usage 0x04) and pointer/mouse
/// interfaces that report absolute X/Y (the "mouse mode" many cheap panels expose).
/// Each device is opened with exclusive (seize) access when possible, so macOS does not
/// also move the cursor from the same touches.
final class TouchReader {
    var onSample: ((TouchSample) -> Void)?
    var onDevicesChanged: (() -> Void)?
    /// When set, every raw HID value is printed (used by `--dump`).
    var dumpValues = false
    /// Seize devices so the system driver stops reacting to them.
    var exclusive = true

    struct DeviceSummary {
        var name: String
        var exclusive: Bool
    }

    private(set) var openFailed = false
    private var manager: IOHIDManager?
    private var devices: [UInt: DeviceState] = [:]
    private var flushScheduled = false

    var summaries: [DeviceSummary] {
        devices.values.map { DeviceSummary(name: $0.name, exclusive: $0.seized) }
            .sorted { $0.name < $1.name }
    }

    func start() {
        stop()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 0x04], // Digitizer / Touch Screen
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x02], // Generic Desktop / Mouse
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x01], // Generic Desktop / Pointer
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<TouchReader>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<TouchReader>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)
        // The manager is only used to find devices. It is never opened, because opening it
        // would open every matched mouse; touch devices are opened one by one in deviceAdded.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        openFailed = false
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        for state in devices.values { close(state) }
        devices.removeAll()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
        onDevicesChanged?()
    }

    private func close(_ state: DeviceState) {
        IOHIDDeviceUnscheduleFromRunLoop(state.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(state.device, IOOptionBits(state.seized ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
    }

    // MARK: - Devices

    private func key(_ device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        guard devices[key(device)] == nil else { return }
        guard let state = DeviceState(device: device) else {
            if dumpValues {
                let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
                print("Skipping \(name): no absolute X/Y with a tip switch or button")
            }
            return
        }

        // Seize so the system stops turning these touches into its own cursor moves.
        var result = kIOReturnError
        if exclusive {
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            state.seized = result == kIOReturnSuccess
            if !state.seized { NSLog("TouchDriver: no exclusive access to %@ (0x%08x)", state.name, result) }
        }
        if !state.seized {
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard result == kIOReturnSuccess else {
            NSLog("TouchDriver: cannot open %@ (0x%08x)", state.name, result)
            openFailed = true
            onDevicesChanged?()
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<TouchReader>.fromOpaque(context).takeUnretainedValue().valueArrived(value)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        devices[key(device)] = state
        NSLog("TouchDriver: using %@ (%@, exclusive: %@)", state.name, state.mode, state.seized ? "yes" : "no")
        if dumpValues { state.printElements() }
        onDevicesChanged?()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let state = devices.removeValue(forKey: key(device)) else { return }
        close(state)
        if state.committed.touching {
            onSample?(TouchSample(u: state.committed.u, v: state.committed.v, touching: false))
        }
        onDevicesChanged?()
    }

    // MARK: - Values

    private func valueArrived(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let integer = IOHIDValueGetIntegerValue(value)

        if dumpValues {
            print(String(format: "page 0x%02X usage 0x%02X cookie %3u value %ld",
                         IOHIDElementGetUsagePage(element), IOHIDElementGetUsage(element),
                         IOHIDElementGetCookie(element), integer))
        }
        guard let state = devices[key(device)] else { return }
        if state.record(cookie: IOHIDElementGetCookie(element), value: integer) {
            scheduleFlush()
        }
    }

    /// All values of one HID report are delivered back to back; process them together
    /// once the run loop gets back to us.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            for state in self.devices.values {
                if let sample = state.flush() { self.onSample?(sample) }
            }
        }
    }
}

// MARK: - Per-device parsing

private final class DeviceState {
    let device: IOHIDDevice
    let name: String
    let mode: String
    var seized = false

    private let xCookie: IOHIDElementCookie
    private let yCookie: IOHIDElementCookie
    private let tipCookie: IOHIDElementCookie?
    private let countCookie: IOHIDElementCookie?
    private let xRange: (min: Double, max: Double)
    private let yRange: (min: Double, max: Double)

    private struct Pending { var x: Int?; var y: Int?; var tip: Int?; var count: Int? }
    private var pending = Pending()
    private var dirty = false
    private var rawX = 0, rawY = 0, tip = false
    private(set) var committed = TouchSample(u: 0, v: 0, touching: false)

    /// Returns nil for devices that are not absolute-position touch devices.
    init?(device: IOHIDDevice) {
        guard let all = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone))
                as? [IOHIDElement] else { return nil }
        let elements = all.sorted { IOHIDElementGetCookie($0) < IOHIDElementGetCookie($1) }
        let inputs = elements.filter {
            let type = IOHIDElementGetType($0)
            return type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Button
                || type == kIOHIDElementTypeInput_Axis
        }

        func usage(_ element: IOHIDElement, _ page: Int, _ usage: Int) -> Bool {
            Int(IOHIDElementGetUsagePage(element)) == page && Int(IOHIDElementGetUsage(element)) == usage
        }
        func parentCookie(_ element: IOHIDElement) -> IOHIDElementCookie? {
            IOHIDElementGetParent(element).map { IOHIDElementGetCookie($0) }
        }

        // Multi-touch digitizers put each contact in a Finger collection (0x0D/0x22).
        // Only the first one is used: it always carries the primary contact.
        let finger = elements.first {
            IOHIDElementGetType($0) == kIOHIDElementTypeCollection && usage($0, 0x0D, 0x22)
        }
        let scope: [IOHIDElement]
        if let finger {
            let fingerCookie = IOHIDElementGetCookie(finger)
            scope = inputs.filter { parentCookie($0) == fingerCookie }
            mode = "multi-touch digitizer"
        } else {
            scope = inputs
            mode = "absolute pointer"
        }

        guard let x = scope.first(where: { usage($0, 0x01, 0x30) && !IOHIDElementIsRelative($0) }),
              let y = scope.first(where: { usage($0, 0x01, 0x31) && !IOHIDElementIsRelative($0) })
        else { return nil } // Relative mice and trackpads end up here and are ignored.

        let tipElement = scope.first { usage($0, 0x0D, 0x42) }   // Tip Switch
            ?? scope.first { usage($0, 0x09, 0x01) }             // Button 1
            ?? inputs.first { usage($0, 0x0D, 0x42) }
            ?? inputs.first { usage($0, 0x09, 0x01) }
        guard let tipElement else { return nil }

        self.device = device
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Touchscreen"
        xCookie = IOHIDElementGetCookie(x)
        yCookie = IOHIDElementGetCookie(y)
        tipCookie = IOHIDElementGetCookie(tipElement)
        countCookie = inputs.first { usage($0, 0x0D, 0x54) }.map { IOHIDElementGetCookie($0) } // Contact Count
        xRange = (Double(IOHIDElementGetLogicalMin(x)), Double(IOHIDElementGetLogicalMax(x)))
        yRange = (Double(IOHIDElementGetLogicalMin(y)), Double(IOHIDElementGetLogicalMax(y)))
    }

    /// Buffers a value for the current report. Returns true if it is one we use.
    func record(cookie: IOHIDElementCookie, value: Int) -> Bool {
        switch cookie {
        case xCookie: pending.x = value
        case yCookie: pending.y = value
        case tipCookie: pending.tip = value
        case countCookie: pending.count = value
        default: return false
        }
        dirty = true
        return true
    }

    /// Commits the buffered report and returns the resulting sample, if any.
    func flush() -> TouchSample? {
        guard dirty else { return nil }
        defer { pending = Pending(); dirty = false }

        // "Hybrid" panels split many contacts over several reports; follow-up reports have
        // a contact count of 0 and put another finger in the first slot. Skip those, but
        // still accept a count-0 report whose first slot is lifted (that is the release).
        if pending.count == 0, pending.tip.map({ $0 != 0 }) ?? true { return nil }

        if let x = pending.x { rawX = x }
        if let y = pending.y { rawY = y }
        if let t = pending.tip { tip = t != 0 }

        committed = TouchSample(u: normalize(rawX, xRange), v: normalize(rawY, yRange), touching: tip)
        return committed
    }

    private func normalize(_ value: Int, _ range: (min: Double, max: Double)) -> Double {
        guard range.max > range.min else { return 0 }
        return (Double(value) - range.min) / (range.max - range.min)
    }

    func printElements() {
        print("Device: \(name) [\(mode)] x \(xRange) y \(yRange) tip cookie \(tipCookie.map(String.init) ?? "-")"
              + " count cookie \(countCookie.map(String.init) ?? "-")")
    }
}
