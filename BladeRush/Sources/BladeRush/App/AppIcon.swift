// Dock icon generated at runtime from the same code-drawn art the packager uses.
import AppKit
import BladeCore

enum AppIcon {
    static func image(size: Int) -> NSImage? {
        let art = IconArt.render(size: size)
        let bytesPerRow = size * 4
        guard let provider = CGDataProvider(data: Data(art.pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
