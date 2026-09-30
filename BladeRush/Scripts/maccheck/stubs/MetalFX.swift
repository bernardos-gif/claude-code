@_exported import Metal
public protocol MTLFXTemporalScaler: NSObjectProtocol {
    var colorTexture: MTLTexture? { get set }
    var depthTexture: MTLTexture? { get set }
    var motionTexture: MTLTexture? { get set }
    var outputTexture: MTLTexture? { get set }
    var inputContentWidth: Int { get set }
    var inputContentHeight: Int { get set }
    var jitterOffsetX: Float { get set }
    var jitterOffsetY: Float { get set }
    var motionVectorScaleX: Float { get set }
    var motionVectorScaleY: Float { get set }
    var reset: Bool { get set }
    var isDepthReversed: Bool { get set }
    func encode(commandBuffer: MTLCommandBuffer)
}
open class MTLFXTemporalScalerDescriptor: NSObject {
    open var colorTextureFormat: MTLPixelFormat = .invalid
    open var depthTextureFormat: MTLPixelFormat = .invalid
    open var motionTextureFormat: MTLPixelFormat = .invalid
    open var outputTextureFormat: MTLPixelFormat = .invalid
    open var inputWidth = 0, inputHeight = 0, outputWidth = 0, outputHeight = 0
    open var isAutoExposureEnabled = false
    open func makeTemporalScaler(device: MTLDevice) -> MTLFXTemporalScaler? { nil }
    open class func supportsDevice(_ device: MTLDevice) -> Bool { false }
}
