// Keyboard, mouse and gamepad input. Raw device events are timestamped (NSEvent timestamps
// share the system uptime clock) and translated through the rebindable bindings into
// InputActions with sub-frame offsets, so the 240 Hz simulation sees presses when they
// actually happened.
import AppKit
import GameController
import BladeCore

final class InputManager {
    private struct RawEvent {
        var id: String
        var pressed: Bool
        var time: TimeInterval
        var isRepeat: Bool
    }

    private var raw: [RawEvent] = []
    private var heldKeys: Set<UInt16> = []
    private var heldCount: [InputAction: Int] = [:]
    private var activeByInput: [String: [InputAction]] = [:]
    private var mouseDelta = Vec2.zero
    private var mousePixel = Vec2.zero
    private var mouseMovedFlag = false
    private var clicked = false
    private var modifiers: NSEvent.ModifierFlags = []
    private var lastFrameTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var padState: [String: Bool] = [:]
    private var radialAccum = Vec2.zero
    private var bindingMap: [String: [InputAction]] = [:]
    private var bindingSnapshot: [String: [String]] = [:]
    private(set) var mouseCaptured = false
    private(set) var usingGamepad = false

    static let padButtons = ["buttonA", "buttonB", "buttonX", "buttonY", "leftShoulder", "rightShoulder", "leftTrigger", "rightTrigger",
                             "buttonMenu", "buttonOptions", "leftThumbstickButton", "rightThumbstickButton", "dpadUp", "dpadDown", "dpadLeft", "dpadRight"]

    init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
            if let c = n.object as? GCController { logInfo("Gamepad connected: \(c.vendorName ?? "controller")", "input") }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in
            logInfo("Gamepad disconnected", "input")
        }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    // MARK: - NSEvent feed (called by GameView)

    func keyDown(_ e: NSEvent) {
        modifiers = e.modifierFlags
        if !e.isARepeat { heldKeys.insert(e.keyCode) }
        raw.append(RawEvent(id: "key:\(e.keyCode)", pressed: true, time: e.timestamp, isRepeat: e.isARepeat))
        usingGamepad = false
    }

    func keyUp(_ e: NSEvent) {
        modifiers = e.modifierFlags
        heldKeys.remove(e.keyCode)
        raw.append(RawEvent(id: "key:\(e.keyCode)", pressed: false, time: e.timestamp, isRepeat: false))
    }

    func flagsChanged(_ e: NSEvent) {
        let old = modifiers
        modifiers = e.modifierFlags
        // Modifier keys as bindable keys (Shift 56, Ctrl 59, Option 58).
        let pairs: [(NSEvent.ModifierFlags, UInt16)] = [(.shift, 56), (.control, 59), (.option, 58)]
        for (flag, code) in pairs where old.contains(flag) != modifiers.contains(flag) {
            let down = modifiers.contains(flag)
            if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
            raw.append(RawEvent(id: "key:\(code)", pressed: down, time: e.timestamp, isRepeat: false))
        }
    }

    func mouseButton(_ button: Int, down: Bool, event e: NSEvent) {
        raw.append(RawEvent(id: "mouse:\(button)", pressed: down, time: e.timestamp, isRepeat: false))
        if down && button == 0 && !mouseCaptured { clicked = true }
        usingGamepad = false
    }

    func mouseMoved(_ e: NSEvent, pixel: Vec2) {
        if mouseCaptured {
            mouseDelta += Vec2(Float(e.deltaX), Float(e.deltaY))
        } else {
            mousePixel = pixel
            mouseMovedFlag = true
        }
        usingGamepad = false
    }

    func scroll(_ e: NSEvent) {
        let dy = e.scrollingDeltaY
        guard abs(dy) > 0.5 else { return }
        let id = dy > 0 ? "wheel:up" : "wheel:down"
        raw.append(RawEvent(id: id, pressed: true, time: e.timestamp, isRepeat: false))
        raw.append(RawEvent(id: id, pressed: false, time: e.timestamp, isRepeat: false))
    }

    /// Releases everything (window lost focus).
    func releaseAll() {
        let now = ProcessInfo.processInfo.systemUptime
        for code in heldKeys { raw.append(RawEvent(id: "key:\(code)", pressed: false, time: now, isRepeat: false)) }
        heldKeys.removeAll()
        for id in activeByInput.keys where !id.hasPrefix("key:") {
            raw.append(RawEvent(id: id, pressed: false, time: now, isRepeat: false))
        }
        setMouseCaptured(false)
    }

    // MARK: - Mouse capture

    func setMouseCaptured(_ on: Bool) {
        guard on != mouseCaptured else { return }
        mouseCaptured = on
        if on {
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
        mouseDelta = .zero
    }

    // MARK: - Per-frame collection

    private func rebuildBindings(_ settings: Settings) {
        guard settings.bindings != bindingSnapshot else { return }
        bindingSnapshot = settings.bindings
        var map: [String: [InputAction]] = [:]
        for (name, ids) in settings.bindings {
            guard let action = InputAction(rawValue: name) else { continue }
            for id in ids { map[id, default: []].append(action) }
        }
        bindingMap = map
    }

    private func modifierPrefix(_ flags: NSEvent.ModifierFlags) -> String {
        if flags.contains(.control) { return "ctrl+" }
        if flags.contains(.shift) { return "shift+" }
        if flags.contains(.option) { return "alt+" }
        return ""
    }

    private func pollGamepad(now: TimeInterval) -> (move: Vec2, look: Vec2) {
        guard let pad = GCController.current?.extendedGamepad ?? GCController.controllers().first?.extendedGamepad else { return (.zero, .zero) }
        let buttons: [String: GCControllerButtonInput?] = [
            "buttonA": pad.buttonA, "buttonB": pad.buttonB, "buttonX": pad.buttonX, "buttonY": pad.buttonY,
            "leftShoulder": pad.leftShoulder, "rightShoulder": pad.rightShoulder,
            "leftTrigger": pad.leftTrigger, "rightTrigger": pad.rightTrigger,
            "buttonMenu": pad.buttonMenu, "buttonOptions": pad.buttonOptions,
            "leftThumbstickButton": pad.leftThumbstickButton, "rightThumbstickButton": pad.rightThumbstickButton,
            "dpadUp": pad.dpad.up, "dpadDown": pad.dpad.down, "dpadLeft": pad.dpad.left, "dpadRight": pad.dpad.right,
        ]
        for (name, b) in buttons {
            guard let b = b else { continue }
            let down = b.isPressed
            if (padState[name] ?? false) != down {
                padState[name] = down
                raw.append(RawEvent(id: "pad:\(name)", pressed: down, time: now, isRepeat: false))
                if down { usingGamepad = true }
            }
        }
        func dead(_ v: Vec2, _ dz: Float) -> Vec2 {
            let l = vlength2(v)
            if l < dz { return .zero }
            return v / l * min(1, (l - dz) / (1 - dz))
        }
        let move = dead(Vec2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value), 0.18)
        let look = dead(Vec2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value), 0.15)
        if vlength2(move) > 0 || vlength2(look) > 0 { usingGamepad = true }
        return (move, look)
    }

    /// Builds this frame's input. `capture` = the game is waiting for a rebind key.
    func collect(settings: Settings, dt: Double, capture: Bool, wantMouseCapture: Bool, windowActive: Bool) -> FrameInput {
        rebuildBindings(settings)
        let now = ProcessInfo.processInfo.systemUptime
        setMouseCaptured(wantMouseCapture && windowActive)
        let (padMove, padLook) = pollGamepad(now: now)
        var input = FrameInput()
        let frameStart = lastFrameTime
        let span = max(1e-4, now - frameStart)
        lastFrameTime = now

        for r in raw {
            let offset = min(max(r.time - frameStart, 0), span) / span * dt
            if r.pressed { input.anyKey = true }
            if capture {
                if r.pressed && !r.isRepeat {
                    if r.id.hasPrefix("key:"), let code = UInt16(r.id.dropFirst(4)), [56, 58, 59].contains(code) { continue }
                    input.captured = r.id.hasPrefix("key:") && r.id != "key:53" ? modifierPrefix(modifiers) + r.id : r.id
                }
                continue
            }
            if r.pressed {
                if r.isRepeat {
                    // Key repeat only drives menu navigation.
                    for a in bindingMap[r.id] ?? [] where [.menuUp, .menuDown, .menuLeft, .menuRight].contains(a) {
                        input.events.append(InputEvent(action: a, pressed: true, offset: offset))
                    }
                    continue
                }
                var actions: [InputAction] = []
                let prefix = r.id.hasPrefix("key:") ? modifierPrefix(modifiers) : ""
                if !prefix.isEmpty, let m = bindingMap[prefix + r.id] { actions = m }
                if actions.isEmpty { actions = bindingMap[r.id] ?? [] }
                // Modifier combos only fire their own actions (Ctrl+1 must not also light-attack).
                if !prefix.isEmpty && bindingMap[prefix + r.id] == nil && prefix == "ctrl+" { actions = [] }
                if let prev = activeByInput[r.id] {
                    for a in prev { heldCount[a] = max(0, (heldCount[a] ?? 1) - 1) }
                }
                activeByInput[r.id] = actions
                for a in actions {
                    heldCount[a, default: 0] += 1
                    input.events.append(InputEvent(action: a, pressed: true, offset: offset))
                }
            } else {
                let actions = activeByInput.removeValue(forKey: r.id) ?? []
                for a in actions {
                    heldCount[a] = max(0, (heldCount[a] ?? 1) - 1)
                    input.events.append(InputEvent(action: a, pressed: false, offset: offset))
                }
            }
        }
        raw.removeAll(keepingCapacity: true)

        func held(_ a: InputAction) -> Float { (heldCount[a] ?? 0) > 0 ? 1 : 0 }
        var move = Vec2(held(.moveRight) - held(.moveLeft), held(.moveForward) - held(.moveBack))
        if vlength2(move) > 1 { move = vnormalize2(move) }
        if vlength2(padMove) > vlength2(move) { move = padMove }
        input.move = move

        // Look: mouse (captured) + right stick.
        let mouseScale: Float = 0.0022 * settings.mouseSensitivity
        let stickScale: Float = Float(dt) * 2.8 * settings.stickSensitivity
        var look: Vec2 = mouseDelta * mouseScale
        look += Vec2(padLook.x, -padLook.y) * stickScale
        if settings.invertY { look.y = -look.y }
        input.look = look

        // Radial weapon menu direction: accumulated while the swap button is held.
        if held(.swapNext) > 0 {
            radialAccum += mouseDelta * 0.012
            if vlength2(radialAccum) > 1 { radialAccum = vnormalize2(radialAccum) }
            if vlength2(padLook) > 0.3 { radialAccum = Vec2(padLook.x, -padLook.y) }
        } else {
            radialAccum = .zero
        }
        input.radial = radialAccum
        mouseDelta = .zero

        // Free camera: WASD + Space / Ctrl.
        let k = { (code: UInt16) -> Float in self.heldKeys.contains(code) ? 1 : 0 }
        input.freeMove = Vec3(k(2) - k(0), k(49) - k(59), k(13) - k(1))
        if vlength2(padMove) > 0 { input.freeMove.x = padMove.x; input.freeMove.z = padMove.y }

        input.mouse = mousePixel
        input.mouseMoved = mouseMovedFlag
        input.click = clicked
        input.gamepad = usingGamepad
        mouseMovedFlag = false
        clicked = false
        return input
    }
}
