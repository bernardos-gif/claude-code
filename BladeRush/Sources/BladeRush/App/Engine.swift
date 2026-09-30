// Main loop: MTKView calls draw(in:) at the display rate (60 / 120 Hz ProMotion). Each tick
// collects input, advances the game (which runs its own fixed 240 Hz combat simulation),
// builds a RenderFrame and renders it.
import AppKit
import MetalKit
import QuartzCore
import BladeCore

final class Engine: NSObject, MTKViewDelegate {
    let game: GameApp
    let renderer: Renderer
    let input = InputManager()
    private(set) var audio: AudioOutput?
    private weak var view: GameView?
    private var lastTime = CACurrentMediaTime()
    private var fpsTime: Double = 0
    private var fpsFrames = 0
    private var appliedFPSCap = -1

    init?(view: GameView) {
        guard let device = view.device else { return nil }
        view.colorPixelFormat = Formats.output
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = false          // screenshots blit from the drawable
        view.preferredFramesPerSecond = 120
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let r = Renderer(device: device, outputFormat: Formats.output) else { return nil }
        renderer = r
        game = timed("game init", "boot") { GameApp() }
        self.view = view
        super.init()
        view.input = input
        view.delegate = self
        renderer.onScreenshot = { [weak self] url in
            self?.game.showToast(url != nil ? "Screenshot saved to the Desktop" : "Screenshot failed (see log)")
        }
        audio = AudioOutput(mixer: game.audio.mixer)
        game.loadAssetsAsync {
            logInfo("Sound bank ready", "boot")
        }
        applyFrameRate(view)
    }

    private func applyFrameRate(_ view: MTKView) {
        let cap = game.settings.fpsCap
        guard cap != appliedFPSCap else { return }
        appliedFPSCap = cap
        view.preferredFramesPerSecond = cap == 0 ? 240 : cap
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = cap != 0
        logInfo("Frame rate cap: \(cap == 0 ? "unlimited" : "\(cap)")", "render")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        var dt = now - lastTime
        lastTime = now
        dt = min(max(dt, 1.0 / 1000), 1.0 / 15)
        applyFrameRate(view)

        let active = NSApp.isActive && view.window?.isKeyWindow == true
        let wantCapture = game.screen == .fight && !game.paused
        let frameInput = input.collect(settings: game.settings, dt: dt, capture: game.captureRequested,
                                       wantMouseCapture: wantCapture, windowActive: active)
        game.update(dt: dt, input: frameInput)
        if game.quitRequested {
            game.quitRequested = false
            NSApp.terminate(nil)
            return
        }
        if game.screenshotRequested {
            game.screenshotRequested = false
            renderer.requestScreenshot()
        }

        let size = view.drawableSize
        let frame = game.buildFrame(width: Int(size.width), height: Int(size.height))
        renderer.render(frame, view: view)

        // Stats for the debug overlay.
        let st = renderer.stats
        game.debug.gpuPasses = st.gpuPasses
        game.debug.gpuTotal = st.gpuTotal
        game.debug.drawCalls = st.drawCalls
        game.debug.triangles = st.triangles
        game.debug.particles = st.particles
        game.debug.renderSize = st.renderSize
        fpsFrames += 1
        fpsTime += dt
        if fpsTime >= 0.5 {
            game.debug.fps = Double(fpsFrames) / fpsTime
            game.debug.frameMs = fpsTime / Double(fpsFrames) * 1000
            fpsFrames = 0
            fpsTime = 0
        }
    }

    func windowLostFocus() {
        input.releaseAll()
    }

    func shutdown() {
        input.setMouseCaptured(false)
        game.settings.save()
        game.save.save()
        audio?.stop()
        logInfo("Shutdown", "boot")
        Log.shared.flush()
    }
}
