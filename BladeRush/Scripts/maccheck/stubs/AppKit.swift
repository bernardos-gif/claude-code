@_exported import Foundation
@_exported import CoreGraphics
@_exported import CoreText
@_exported import QuartzCore
open class NSResponder: NSObject {
    open var acceptsFirstResponder: Bool { false }
    open func keyDown(with event: NSEvent) {}
    open func keyUp(with event: NSEvent) {}
    open func flagsChanged(with event: NSEvent) {}
    open func mouseDown(with event: NSEvent) {}
    open func mouseUp(with event: NSEvent) {}
    open func rightMouseDown(with event: NSEvent) {}
    open func rightMouseUp(with event: NSEvent) {}
    open func otherMouseDown(with event: NSEvent) {}
    open func otherMouseUp(with event: NSEvent) {}
    open func mouseMoved(with event: NSEvent) {}
    open func mouseDragged(with event: NSEvent) {}
    open func rightMouseDragged(with event: NSEvent) {}
    open func otherMouseDragged(with event: NSEvent) {}
    open func scrollWheel(with event: NSEvent) {}
}
public struct NSAutoresizingMaskOptions: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let width = NSAutoresizingMaskOptions(rawValue: 2), height = NSAutoresizingMaskOptions(rawValue: 16) }
open class NSTrackingArea: NSObject {
    public struct Options: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mouseMoved = Options(rawValue: 2), activeInKeyWindow = Options(rawValue: 32), inVisibleRect = Options(rawValue: 512) }
    public init(rect: NSRect, options: Options, owner: Any?, userInfo: [AnyHashable: Any]?) {}
}
open class NSView: NSResponder {
    public init(frame frameRect: NSRect) {}
    public required init?(coder: NSCoder) {}
    open var bounds: NSRect { .zero }
    open var window: NSWindow? { nil }
    open var layer: CALayer? { get { nil } set {} }
    open var autoresizingMask: NSAutoresizingMaskOptions = []
    open var trackingAreas: [NSTrackingArea] { [] }
    open func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    open func convert(_ point: NSPoint, from view: NSView?) -> NSPoint { point }
    open func updateTrackingAreas() {}
    open func addTrackingArea(_ t: NSTrackingArea) {}
    open func removeTrackingArea(_ t: NSTrackingArea) {}
}
open class NSEvent: NSObject {
    public struct ModifierFlags: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let shift = ModifierFlags(rawValue: 1 << 17), control = ModifierFlags(rawValue: 1 << 18), option = ModifierFlags(rawValue: 1 << 19), command = ModifierFlags(rawValue: 1 << 20) }
    open var keyCode: UInt16 { 0 }
    open var isARepeat: Bool { false }
    open var modifierFlags: ModifierFlags { [] }
    open var timestamp: TimeInterval { 0 }
    open var deltaX: CGFloat { 0 }
    open var deltaY: CGFloat { 0 }
    open var scrollingDeltaY: CGFloat { 0 }
    open var buttonNumber: Int { 0 }
    open var locationInWindow: NSPoint { .zero }
}
open class NSColor: NSObject { open class var black: NSColor { NSColor() } }
open class NSImage: NSObject { public init(cgImage: CGImage, size: NSSize) {} }
open class NSWindow: NSResponder {
    public struct StyleMask: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let titled = StyleMask(rawValue: 1), closable = StyleMask(rawValue: 2), miniaturizable = StyleMask(rawValue: 4), resizable = StyleMask(rawValue: 8) }
    public enum BackingStoreType: UInt { case buffered = 2 }
    public struct CollectionBehavior: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }; public static let fullScreenPrimary = CollectionBehavior(rawValue: 128) }
    public init(contentRect: NSRect, styleMask style: StyleMask, backing backingStoreType: BackingStoreType, defer flag: Bool) {}
    open var title = ""
    open var minSize = NSSize.zero
    open var backgroundColor: NSColor! = nil
    open var acceptsMouseMovedEvents = false
    open var collectionBehavior: CollectionBehavior = []
    open weak var delegate: NSWindowDelegate?
    open var contentView: NSView?
    open var isKeyWindow: Bool { false }
    open var backingScaleFactor: CGFloat { 2 }
    open func center() {}
    open func makeKeyAndOrderFront(_ sender: Any?) {}
    @discardableResult open func makeFirstResponder(_ r: NSResponder?) -> Bool { true }
    open func toggleFullScreen(_ sender: Any?) {}
    open func performMiniaturize(_ sender: Any?) {}
}
public protocol NSWindowDelegate: AnyObject {
    func windowDidResignKey(_ notification: Notification)
}
extension NSWindowDelegate { public func windowDidResignKey(_ notification: Notification) {} }
public protocol NSApplicationDelegate: AnyObject {
    func applicationDidFinishLaunching(_ notification: Notification)
    func applicationWillTerminate(_ notification: Notification)
    func applicationDidResignActive(_ notification: Notification)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool
}
extension NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {}
    public func applicationWillTerminate(_ notification: Notification) {}
    public func applicationDidResignActive(_ notification: Notification) {}
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
/// Stand-in for the Objective-C selector type (check_mac.sh rewrites #selector(...) to Selector("...")).
public struct Selector { public init(_ s: String) {} }
open class NSMenuItem: NSObject {
    public override init() {}
    open var submenu: NSMenu?
    open var keyEquivalentModifierMask: NSEvent.ModifierFlags = []
    open class func separator() -> NSMenuItem { NSMenuItem() }
}
open class NSMenu: NSObject {
    public override init() {}
    public init(title: String) {}
    open func addItem(_ item: NSMenuItem) {}
    @discardableResult open func addItem(withTitle string: String, action selector: Selector?, keyEquivalent charCode: String) -> NSMenuItem { NSMenuItem() }
}
open class NSApplication: NSResponder {
    public enum ActivationPolicy: Int { case regular = 0, accessory, prohibited }
    open class var shared: NSApplication { NSApplication() }
    open var delegate: NSApplicationDelegate?
    open var isActive: Bool { true }
    open var mainMenu: NSMenu?
    open var windowsMenu: NSMenu?
    open var applicationIconImage: NSImage!
    @discardableResult open func setActivationPolicy(_ p: ActivationPolicy) -> Bool { true }
    open func run() {}
    open func activate(ignoringOtherApps flag: Bool) {}
    open func terminate(_ sender: Any?) {}
    open func hide(_ sender: Any?) {}
    open func orderFrontStandardAboutPanel(_ sender: Any?) {}
}
public var NSApp: NSApplication! = nil
open class NSAlert: NSObject { open var messageText = ""; open var informativeText = ""; @discardableResult open func runModal() -> Int { 0 } }
open class NSCursor: NSObject { open class func hide() {}; open class func unhide() {} }
public typealias NSFontWeight = NSFont.Weight
open class NSFont: CTFont {
    public struct Weight: Equatable { public let rawValue: CGFloat; public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public static let regular = Weight(rawValue: 0), medium = Weight(rawValue: 0.23), bold = Weight(rawValue: 0.4) }
    public init?(name: String, size: CGFloat) { super.init() }
    open class func systemFont(ofSize: CGFloat, weight: Weight) -> NSFont { NSFont(name: "", size: 1)! }
    open class func boldSystemFont(ofSize: CGFloat) -> NSFont { NSFont(name: "", size: 1)! }
    open class func monospacedSystemFont(ofSize: CGFloat, weight: Weight) -> NSFont { NSFont(name: "", size: 1)! }
}
