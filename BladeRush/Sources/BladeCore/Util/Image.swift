// Minimal RGBA8 image buffer with an uncompressed PNG encoder (stored deflate blocks).
// Used for CPU preview renders in BladeSim and for the generated app icon.
import Foundation

public struct ImageRGBA8 {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)) {
        self.width = width; self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = fill.0; pixels[i * 4 + 1] = fill.1; pixels[i * 4 + 2] = fill.2; pixels[i * 4 + 3] = fill.3
        }
    }

    @inlinable public mutating func set(_ x: Int, _ y: Int, _ c: Vec4) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = (y * width + x) * 4
        pixels[i] = UInt8(saturatef(c.x) * 255 + 0.5)
        pixels[i + 1] = UInt8(saturatef(c.y) * 255 + 0.5)
        pixels[i + 2] = UInt8(saturatef(c.z) * 255 + 0.5)
        pixels[i + 3] = UInt8(saturatef(c.w) * 255 + 0.5)
    }

    public func get(_ x: Int, _ y: Int) -> Vec4 {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return Vec4(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]), Float(pixels[i + 3])) / 255
    }

    public func pngData() -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height {
            raw.append(0) // filter: none
            raw.append(contentsOf: pixels[(y * width * 4)..<((y + 1) * width * 4)])
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = [UInt8]()
        ihdr += be32(UInt32(width)); ihdr += be32(UInt32(height))
        ihdr += [8, 6, 0, 0, 0] // 8-bit RGBA
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", []))
        return png
    }

    public func writePNG(to url: URL) throws { try pngData().write(to: url) }

    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }

    private func chunk(_ type: String, _ data: [UInt8]) -> Data {
        var d = Data(be32(UInt32(data.count)))
        let t = Array(type.utf8)
        d.append(contentsOf: t)
        d.append(contentsOf: data)
        d.append(contentsOf: be32(ImageRGBA8.crc32(t + data)))
        return d
    }

    private func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, data.count - i)
            let final: UInt8 = (i + n >= data.count) ? 1 : 0
            out.append(final)
            out.append(UInt8(n & 255)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 255)); out.append(UInt8((~n >> 8) & 255))
            out.append(contentsOf: data[i..<(i + n)])
            i += n
        } while i < data.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        out += be32((b << 16) | a)
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
