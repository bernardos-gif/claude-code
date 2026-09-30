// Application delegate: window, menu bar, icon and lifecycle.
import AppKit
import Metal
import BladeCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var engine: Engine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logInfo("Blade Rush starting (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))", "boot")
        NSApp.applicationIconImage = AppIcon.image(size: 512)
        buildMenu()
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalAlert("Metal is not available on this Mac.")
            return
        }
        let rect = NSRect(x: 0, y: 0, width: 1600, height: 900)
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Blade Rush"
        w.minSize = NSSize(width: 960, height: 540)
        w.backgroundColor = .black
        w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.fullScreenPrimary]
        w.delegate = self
        w.center()
        let view = GameView(frame: rect, device: device)
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        guard let e = Engine(view: view) else {
            fatalAlert("The renderer could not be created. See the log in ~/Library/Application Support/BladeRush/Logs.")
            return
        }
        engine = e
        window = w
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func fatalAlert(_ message: String) {
        logError(message, "boot")
        let a = NSAlert()
        a.messageText = "Blade Rush cannot start"
        a.informativeText = message
        a.runModal()
        NSApp.terminate(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Blade Rush", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Blade Rush", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Blade Rush", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.shutdown()
    }

    func applicationDidResignActive(_ notification: Notification) {
        engine?.windowLostFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        engine?.windowLostFocus()
    }
}
