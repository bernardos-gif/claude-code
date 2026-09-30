// The Metal view: forwards keyboard / mouse events to the InputManager.
import AppKit
import MetalKit
import BladeCore

final class GameView: MTKView {
    weak var input: InputManager?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func pixel(_ e: NSEvent) -> Vec2 {
        let p = convert(e.locationInWindow, from: nil)
        let scale = Float(window?.backingScaleFactor ?? 2)
        return Vec2(Float(p.x) * scale, Float(bounds.height - p.y) * scale)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        input?.keyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyUp(with: event); return }
        input?.keyUp(event)
    }

    override func flagsChanged(with event: NSEvent) { input?.flagsChanged(event) }

    override func mouseDown(with event: NSEvent) { input?.mouseMoved(event, pixel: pixel(event)); input?.mouseButton(0, down: true, event: event) }
    override func mouseUp(with event: NSEvent) { input?.mouseButton(0, down: false, event: event) }
    override func rightMouseDown(with event: NSEvent) { input?.mouseButton(1, down: true, event: event) }
    override func rightMouseUp(with event: NSEvent) { input?.mouseButton(1, down: false, event: event) }
    override func otherMouseDown(with event: NSEvent) { input?.mouseButton(event.buttonNumber, down: true, event: event) }
    override func otherMouseUp(with event: NSEvent) { input?.mouseButton(event.buttonNumber, down: false, event: event) }
    override func mouseMoved(with event: NSEvent) { input?.mouseMoved(event, pixel: pixel(event)) }
    override func mouseDragged(with event: NSEvent) { input?.mouseMoved(event, pixel: pixel(event)) }
    override func rightMouseDragged(with event: NSEvent) { input?.mouseMoved(event, pixel: pixel(event)) }
    override func otherMouseDragged(with event: NSEvent) { input?.mouseMoved(event, pixel: pixel(event)) }
    override func scrollWheel(with event: NSEvent) { input?.scroll(event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
}
