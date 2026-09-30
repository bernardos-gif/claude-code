@_exported import Foundation
open class GCControllerElement: NSObject {}
open class GCControllerButtonInput: GCControllerElement { open var isPressed: Bool { false }; open var value: Float { 0 } }
open class GCControllerAxisInput: GCControllerElement { open var value: Float { 0 } }
open class GCControllerDirectionPad: GCControllerElement {
    open var xAxis: GCControllerAxisInput { GCControllerAxisInput() }
    open var yAxis: GCControllerAxisInput { GCControllerAxisInput() }
    open var up: GCControllerButtonInput { GCControllerButtonInput() }
    open var down: GCControllerButtonInput { GCControllerButtonInput() }
    open var left: GCControllerButtonInput { GCControllerButtonInput() }
    open var right: GCControllerButtonInput { GCControllerButtonInput() }
}
open class GCExtendedGamepad: NSObject {
    open var buttonA: GCControllerButtonInput { GCControllerButtonInput() }
    open var buttonB: GCControllerButtonInput { GCControllerButtonInput() }
    open var buttonX: GCControllerButtonInput { GCControllerButtonInput() }
    open var buttonY: GCControllerButtonInput { GCControllerButtonInput() }
    open var leftShoulder: GCControllerButtonInput { GCControllerButtonInput() }
    open var rightShoulder: GCControllerButtonInput { GCControllerButtonInput() }
    open var leftTrigger: GCControllerButtonInput { GCControllerButtonInput() }
    open var rightTrigger: GCControllerButtonInput { GCControllerButtonInput() }
    open var buttonMenu: GCControllerButtonInput { GCControllerButtonInput() }
    open var buttonOptions: GCControllerButtonInput? { nil }
    open var leftThumbstickButton: GCControllerButtonInput? { nil }
    open var rightThumbstickButton: GCControllerButtonInput? { nil }
    open var dpad: GCControllerDirectionPad { GCControllerDirectionPad() }
    open var leftThumbstick: GCControllerDirectionPad { GCControllerDirectionPad() }
    open var rightThumbstick: GCControllerDirectionPad { GCControllerDirectionPad() }
}
open class GCController: NSObject {
    open class var current: GCController? { nil }
    open class func controllers() -> [GCController] { [] }
    open class func startWirelessControllerDiscovery(completionHandler: (() -> Void)? = nil) {}
    open var extendedGamepad: GCExtendedGamepad? { nil }
    open var vendorName: String? { nil }
}
extension NSNotification.Name {
    public static let GCControllerDidConnect = NSNotification.Name("GCControllerDidConnectNotification")
    public static let GCControllerDidDisconnect = NSNotification.Name("GCControllerDidDisconnectNotification")
}
