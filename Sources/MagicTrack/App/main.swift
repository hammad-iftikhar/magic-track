import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // also covers unbundled `swift run`; the bundle sets LSUIElement
app.run()
