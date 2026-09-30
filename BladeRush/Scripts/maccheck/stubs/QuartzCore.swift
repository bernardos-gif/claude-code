@_exported import CoreGraphics
import Metal
public func CACurrentMediaTime() -> CFTimeInterval { 0 }
open class CALayer: NSObject {}
open class CAMetalLayer: CALayer { open var displaySyncEnabled = true; open var device: MTLDevice? }
public protocol CAMetalDrawable: MTLDrawable { var texture: MTLTexture { get } }
