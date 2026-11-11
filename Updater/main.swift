import AppKit

let app = NSApplication.shared
let delegate = UpdaterDelegate()
app.delegate = delegate
app.run()
