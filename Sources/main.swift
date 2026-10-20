import AppKit

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

if arguments.contains("--dump") {
    // Prints every HID value from matched touch devices; useful to check a new panel.
    // Devices are not seized, so the system cursor keeps working while dumping.
    let reader = TouchReader()
    reader.dumpValues = true
    reader.exclusive = false
    reader.onSample = { print(String(format: "  -> u %.4f v %.4f touching %@", $0.u, $0.v, $0.touching ? "yes" : "no")) }
    reader.start()
    print("Listening for touch devices. Press Ctrl-C to stop.")
    setvbuf(stdout, nil, _IOLBF, 0)
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
