@_exported import Foundation
public enum MTLPixelFormat: UInt { case invalid = 0, r8Unorm = 10, rg16Float = 65, r32Float = 55, rgba8Unorm = 70, bgra8Unorm = 80, bgra8Unorm_srgb = 81, rgba16Float = 115, rg11b10Float = 92, depth32Float = 252 }
public struct MTLTextureUsage: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let shaderRead = MTLTextureUsage(rawValue: 1), shaderWrite = MTLTextureUsage(rawValue: 2), renderTarget = MTLTextureUsage(rawValue: 4) }
public enum MTLStorageMode: UInt { case shared = 0, managed, `private`, memoryless }
public struct MTLResourceOptions: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let storageModeShared = MTLResourceOptions(rawValue: 0), storageModePrivate = MTLResourceOptions(rawValue: 32) }
public enum MTLTextureType: UInt { case type2D = 2, type2DArray = 3, typeCube = 5 }
public enum MTLCompareFunction: UInt { case never = 0, less, equal, lessEqual, greater, notEqual, greaterEqual, always }
public enum MTLCullMode: UInt { case none = 0, front, back }
public enum MTLWinding: UInt { case clockwise = 0, counterClockwise }
public enum MTLPrimitiveType: UInt { case point = 0, line, lineStrip, triangle, triangleStrip }
public enum MTLIndexType: UInt { case uint16 = 0, uint32 }
public enum MTLBlendFactor: UInt { case zero = 0, one, sourceColor, oneMinusSourceColor, sourceAlpha, oneMinusSourceAlpha, destinationColor, oneMinusDestinationColor, destinationAlpha, oneMinusDestinationAlpha }
public enum MTLBlendOperation: UInt { case add = 0, subtract, reverseSubtract, min, max }
public struct MTLColorWriteMask: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }; public static let all = MTLColorWriteMask(rawValue: 15) }
public enum MTLLoadAction: UInt { case dontCare = 0, load, clear }
public enum MTLStoreAction: UInt { case dontCare = 0, store }
public enum MTLLanguageVersion: UInt { case version3_0 = 196608, version3_1 = 196609 }
public struct MTLClearColor { public var red, green, blue, alpha: Double; public init(red: Double, green: Double, blue: Double, alpha: Double) { self.red = red; self.green = green; self.blue = blue; self.alpha = alpha } }
public func MTLClearColorMake(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> MTLClearColor { MTLClearColor(red: r, green: g, blue: b, alpha: a) }
public struct MTLOrigin { public var x, y, z: Int; public init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }; public init() { x = 0; y = 0; z = 0 } }
public struct MTLSize { public var width, height, depth: Int; public init(width: Int, height: Int, depth: Int) { self.width = width; self.height = height; self.depth = depth }; public init() { width = 0; height = 0; depth = 0 } }
public struct MTLRegion { public var origin: MTLOrigin; public var size: MTLSize }
public func MTLRegionMake2D(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> MTLRegion { MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0), size: MTLSize(width: w, height: h, depth: 1)) }

public protocol MTLResource: NSObjectProtocol { var label: String? { get set } }
public protocol MTLBuffer: MTLResource { var length: Int { get }; func contents() -> UnsafeMutableRawPointer }
public protocol MTLTexture: MTLResource {
    var width: Int { get }; var height: Int { get }; var pixelFormat: MTLPixelFormat { get }
    func replace(region: MTLRegion, mipmapLevel: Int, withBytes pixelBytes: UnsafeRawPointer, bytesPerRow: Int)
}
public protocol MTLFunction: NSObjectProtocol {}
public protocol MTLLibrary: NSObjectProtocol { func makeFunction(name functionName: String) -> MTLFunction? }
public protocol MTLRenderPipelineState: NSObjectProtocol {}
public protocol MTLComputePipelineState: NSObjectProtocol {}
public protocol MTLDepthStencilState: NSObjectProtocol {}
public protocol MTLDrawable: NSObjectProtocol {}

open class MTLCompileOptions: NSObject { open var languageVersion: MTLLanguageVersion = .version3_0; open var preserveInvariance = false }
open class MTLTextureDescriptor: NSObject {
    open var textureType: MTLTextureType = .type2D; open var pixelFormat: MTLPixelFormat = .rgba8Unorm
    open var width = 1, height = 1, arrayLength = 1; open var usage: MTLTextureUsage = .shaderRead; open var storageMode: MTLStorageMode = .shared
    open class func texture2DDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int, mipmapped: Bool) -> MTLTextureDescriptor { MTLTextureDescriptor() }
    open class func textureCubeDescriptor(pixelFormat: MTLPixelFormat, size: Int, mipmapped: Bool) -> MTLTextureDescriptor { MTLTextureDescriptor() }
}
open class MTLRenderPipelineColorAttachmentDescriptor: NSObject {
    open var pixelFormat: MTLPixelFormat = .invalid; open var isBlendingEnabled = false
    open var sourceRGBBlendFactor: MTLBlendFactor = .one, destinationRGBBlendFactor: MTLBlendFactor = .zero
    open var sourceAlphaBlendFactor: MTLBlendFactor = .one, destinationAlphaBlendFactor: MTLBlendFactor = .zero
    open var rgbBlendOperation: MTLBlendOperation = .add, alphaBlendOperation: MTLBlendOperation = .add
    open var writeMask: MTLColorWriteMask = .all
}
open class MTLRenderPipelineColorAttachmentDescriptorArray: NSObject { open subscript(i: Int) -> MTLRenderPipelineColorAttachmentDescriptor! { get { nil } set {} } }
open class MTLRenderPipelineDescriptor: NSObject {
    open var label: String?; open var vertexFunction: MTLFunction?; open var fragmentFunction: MTLFunction?
    open var colorAttachments: MTLRenderPipelineColorAttachmentDescriptorArray { MTLRenderPipelineColorAttachmentDescriptorArray() }
    open var depthAttachmentPixelFormat: MTLPixelFormat = .invalid
}
open class MTLDepthStencilDescriptor: NSObject { open var depthCompareFunction: MTLCompareFunction = .always; open var isDepthWriteEnabled = false }
open class MTLRenderPassAttachmentDescriptor: NSObject { open var texture: MTLTexture?; open var level = 0; open var slice = 0; open var loadAction: MTLLoadAction = .dontCare; open var storeAction: MTLStoreAction = .dontCare }
open class MTLRenderPassColorAttachmentDescriptor: MTLRenderPassAttachmentDescriptor { open var clearColor = MTLClearColorMake(0, 0, 0, 1) }
open class MTLRenderPassDepthAttachmentDescriptor: MTLRenderPassAttachmentDescriptor { open var clearDepth: Double = 1 }
open class MTLRenderPassColorAttachmentDescriptorArray: NSObject { open subscript(i: Int) -> MTLRenderPassColorAttachmentDescriptor! { get { nil } set {} } }
open class MTLRenderPassDescriptor: NSObject {
    open var colorAttachments: MTLRenderPassColorAttachmentDescriptorArray { MTLRenderPassColorAttachmentDescriptorArray() }
    open var depthAttachment: MTLRenderPassDepthAttachmentDescriptor! { get { nil } set {} }
}

public protocol MTLCommandEncoder: NSObjectProtocol { var label: String? { get set }; func endEncoding() }
public protocol MTLRenderCommandEncoder: MTLCommandEncoder {
    func setRenderPipelineState(_ pipelineState: MTLRenderPipelineState)
    func setDepthStencilState(_ depthStencilState: MTLDepthStencilState?)
    func setCullMode(_ cullMode: MTLCullMode)
    func setFrontFacing(_ frontFacingWinding: MTLWinding)
    func setDepthBias(_ depthBias: Float, slopeScale: Float, clamp: Float)
    func setVertexBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setFragmentBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setFragmentTexture(_ texture: MTLTexture?, index: Int)
    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int)
    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int)
    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: MTLBuffer, indexBufferOffset: Int)
    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: MTLBuffer, indexBufferOffset: Int, instanceCount: Int)
}
public protocol MTLComputeCommandEncoder: MTLCommandEncoder {
    func setComputePipelineState(_ state: MTLComputePipelineState)
    func setBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setTexture(_ texture: MTLTexture?, index: Int)
    func dispatchThreadgroups(_ threadgroupsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize)
    func dispatchThreads(_ threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize)
}
public protocol MTLBlitCommandEncoder: MTLCommandEncoder {
    func generateMipmaps(for texture: MTLTexture)
    func fill(buffer: MTLBuffer, range: Range<Int>, value: UInt8)
    func copy(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture)
    func copy(from sourceTexture: MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize, to destinationBuffer: MTLBuffer,
              destinationOffset: Int, destinationBytesPerRow: Int, destinationBytesPerImage: Int)
}
public typealias MTLCommandBufferHandler = (MTLCommandBuffer) -> Void
public protocol MTLCommandBuffer: NSObjectProtocol {
    var label: String? { get set }
    var gpuStartTime: CFTimeInterval { get }
    var gpuEndTime: CFTimeInterval { get }
    func makeRenderCommandEncoder(descriptor renderPassDescriptor: MTLRenderPassDescriptor) -> MTLRenderCommandEncoder?
    func makeComputeCommandEncoder() -> MTLComputeCommandEncoder?
    func makeBlitCommandEncoder() -> MTLBlitCommandEncoder?
    func addCompletedHandler(_ block: @escaping MTLCommandBufferHandler)
    func present(_ drawable: MTLDrawable)
    func commit()
    func waitUntilCompleted()
}
public typealias CFTimeInterval = Double
public protocol MTLCommandQueue: NSObjectProtocol { var label: String? { get set }; func makeCommandBuffer() -> MTLCommandBuffer? }
public protocol MTLDevice: NSObjectProtocol {
    var name: String { get }
    func makeCommandQueue() -> MTLCommandQueue?
    func makeBuffer(length: Int, options: MTLResourceOptions) -> MTLBuffer?
    func makeBuffer(bytes pointer: UnsafeRawPointer, length: Int, options: MTLResourceOptions) -> MTLBuffer?
    func makeTexture(descriptor: MTLTextureDescriptor) -> MTLTexture?
    func makeDepthStencilState(descriptor: MTLDepthStencilDescriptor) -> MTLDepthStencilState?
    func makeLibrary(source: String, options: MTLCompileOptions?) throws -> MTLLibrary
    func makeRenderPipelineState(descriptor: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState
    func makeComputePipelineState(function computeFunction: MTLFunction) throws -> MTLComputePipelineState
}
public func MTLCreateSystemDefaultDevice() -> MTLDevice? { nil }
