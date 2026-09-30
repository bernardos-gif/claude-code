// Type-check stub of CoreGraphics (subset used by BladeRush). Not functional.
@_exported import Foundation
public typealias CGGlyph = UInt16
public typealias CGDirectDisplayID = UInt32
public struct CGError: Equatable { public let rawValue: Int32; public init(rawValue: Int32) { self.rawValue = rawValue }; public static let success = CGError(rawValue: 0) }
@discardableResult public func CGAssociateMouseAndMouseCursorPosition(_ connected: boolean_t) -> CGError { .success }
public typealias boolean_t = Int32
public final class CGColorSpace { }
public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { CGColorSpace() }
public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { CGColorSpace() }
public enum CGImageAlphaInfo: UInt32 { case none = 0, premultipliedLast, premultipliedFirst, last, first, noneSkipLast, noneSkipFirst, alphaOnly }
public struct CGBitmapInfo: OptionSet { public let rawValue: UInt32; public init(rawValue: UInt32) { self.rawValue = rawValue } }
public enum CGColorRenderingIntent: Int32 { case defaultIntent = 0, absoluteColorimetric, relativeColorimetric, perceptual, saturation }
public final class CGDataProvider { public init?(data: CFData) {} }
public final class CGImage {
    public init?(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int, space: CGColorSpace, bitmapInfo: CGBitmapInfo,
                 provider: CGDataProvider, decode: UnsafePointer<CGFloat>?, shouldInterpolate: Bool, intent: CGColorRenderingIntent) {}
}
public final class CGContext {
    public init?(data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int, space: CGColorSpace, bitmapInfo: UInt32) {}
    public func setAllowsAntialiasing(_ b: Bool) {}
    public func setShouldAntialias(_ b: Bool) {}
    public func setFillColor(gray: CGFloat, alpha: CGFloat) {}
}
public typealias CFData = NSData
public typealias CFIndex = Int
