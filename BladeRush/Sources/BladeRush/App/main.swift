// Blade Rush entry point.
import AppKit
import BladeCore

Paths.ensureDirectories()
Log.shared.open(directory: Paths.logs)
logInfo("Log file: \(Log.shared.fileURL?.path ?? "unavailable")", "boot")
logInfo("Data: \(Paths.dataDirectory.path)  Shaders: \(Paths.shaderDirectory.path)", "boot")
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
