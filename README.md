# TouchDriver

A menu-bar app that makes a capacitive USB touchscreen work on macOS as a standard
pointer, with correct mapping when the screen is rotated.

- **Tap**: left click. Double and triple taps count as double and triple clicks.
- **Touch and drag**: left drag.
- **Touch and hold** (optional): right click.
- **The cursor is hidden** while you use the touchscreen. It shows again as soon as
  you move a real mouse or trackpad.
- **Rotation**: follows the rotation set in System Settings → Displays
  (0°, 90°, 180°, 270°) and updates instantly. Nothing needs restarting.
- **Screen selection**: by default, touches go to the main screen (the one with the
  menu bar). You can choose another screen from the menu.

It runs entirely in user space (IOKit HID + CGEvent), so it does not need a kernel
extension or a DriverKit entitlement.

## Install

1. Download `TouchDriver.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move `TouchDriver.app` to `/Applications`.
3. The app is ad-hoc signed and not notarized, so macOS blocks it the first time. Either
   right-click the app and choose **Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/TouchDriver.app
   ```
4. Start the app. When macOS asks, allow **Input Monitoring** and **Accessibility** in
   System Settings → Privacy & Security. If touches do nothing after you grant them,
   quit and reopen the app.

## Menu

| Item | What it does |
|------|--------------|
| Device line | The touchscreen in use. "shared" means exclusive access failed, so macOS may also move the cursor. |
| Enabled | Turns touch input on or off. |
| Screen | Main Screen (default) or a specific display. The choice is remembered by display UUID. |
| Rotation | Automatic (follows Displays), or a fixed 0/90/180/270° override. |
| Calibration | Swap X and Y, Flip X, Flip Y, for panels wired in an unusual orientation. |
| Hide Cursor While Touching | On by default. |
| Touch and Hold for Right-Click | On by default. When off, a touch presses the button immediately. |
| Start at Login | Registers the app as a login item. |

If touches land in the wrong place after you rotate the screen, first check that
**Rotation** is set to Automatic. Then use the Calibration toggles until touches line up.

## Supported hardware

- HID digitizers that report as **Touch Screen** (usage page `0x0D`, usage `0x04`),
  including multi-touch panels in hybrid reporting mode. Only the first contact is used.
- Panels in "mouse mode" that report **absolute** X/Y as a mouse or pointer.

Relative mice and trackpads are ignored.

The app opens each touchscreen with exclusive (seize) access. Without it, macOS would
also turn the same touches into its own unrotated cursor movement.

## Build

Requires Xcode command-line tools (Swift 5.9+), macOS 13 or later.

```bash
./build.sh
```

The script builds a universal `build/TouchDriver.app`, signs it ad-hoc and runs the
mapping self-test. macOS ties the privacy permissions to the signature, so after a
rebuild you may need to switch TouchDriver off and on again in Privacy & Security.

## Troubleshooting

To see the raw data a panel sends, run:

```bash
build/TouchDriver.app/Contents/MacOS/TouchDriver --dump
```

It lists the matched devices, the HID values and the resulting normalized touch
positions. Your terminal app may need Input Monitoring for this.

## Notes

- Hiding the cursor from a background app uses the private `SetsCursorInBackground`
  window-server property. It is not an official API, so a future macOS update could break it.
- Gestures (scroll, pinch) are not supported. Only standard mouse input is emitted.

## Layout

```
Sources/
  main.swift            entry point, --dump and --selftest modes
  AppDelegate.swift     menu-bar item and menu
  TouchReader.swift     IOHIDManager device discovery and report parsing
  TouchMapper.swift     calibration + rotation mapping, display lookup
  PointerInjector.swift tap / drag / long-press → CGEvent mouse events
  CursorHider.swift     hide cursor while touching, show on real mouse use
  Settings.swift        UserDefaults-backed preferences
  SelfTest.swift        mapping tests
Resources/Info.plist
build.sh
```

## License

MIT
