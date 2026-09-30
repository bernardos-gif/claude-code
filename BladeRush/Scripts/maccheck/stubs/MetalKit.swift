@_exported import Metal
@_exported import AppKit
public protocol MTKViewDelegate: AnyObject {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    func draw(in view: MTKView)
}
open class MTKView: NSView {
    public init(frame frameRect: CGRect, device: MTLDevice?) { super.init(frame: frameRect) }
    public required init(coder: NSCoder) { super.init(frame: .zero) }
    open var device: MTLDevice?
    open weak var delegate: MTKViewDelegate?
    open var colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    open var depthStencilPixelFormat: MTLPixelFormat = .invalid
    open var framebufferOnly = true
    open var preferredFramesPerSecond = 60
    open var clearColor = MTLClearColorMake(0, 0, 0, 1)
    open var drawableSize: CGSize = .zero
    open var currentDrawable: CAMetalDrawable? { nil }
}
