// Signed-distance-field font atlas built at startup from system fonts (CoreText), so text
// stays crisp at every UI scale. Also provides real text metrics to the UI layout code.
import AppKit
import CoreText
import Metal
import BladeCore

final class FontAtlas: FontMetrics {
    struct Glyph {
        var uv: Vec4          // u0, v0, u1, v1
        var quadSize: Vec2    // reference pixels (with SDF padding)
        var offset: Vec2      // quad top-left relative to (pen x, baseline), y down, reference pixels
        var advance: Float
    }

    static let refSize: CGFloat = 48
    static let pad = 6
    static let atlasSize = 2048
    static let charset: [Character] = (32...126).compactMap { UnicodeScalar($0).map { Character($0) } } + ["·", "—", "•", "…", "←", "↑", "→", "↓"]

    private(set) var texture: MTLTexture?
    private var glyphs: [[Character: Glyph]] = [[:], [:], [:]]
    private var fallbackAdvance: [Float] = [26, 26, 26]

    init(device: MTLDevice) {
        let t0 = Date()
        let W = FontAtlas.atlasSize, H = FontAtlas.atlasSize
        var atlas = [UInt8](repeating: 0, count: W * H)
        var penX = 1, penY = 1, rowH = 0
        for (fi, font) in FontAtlas.fonts().enumerated() {
            for ch in FontAtlas.charset {
                guard var glyph = FontAtlas.glyphID(font, ch) else { continue }
                var adv = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &adv, 1)
                var bbox = CGRect.zero
                CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bbox, 1)
                if ch == "?" { fallbackAdvance[fi] = Float(adv.width) }
                if bbox.width < 0.5 || bbox.height < 0.5 {
                    glyphs[fi][ch] = Glyph(uv: .zero, quadSize: .zero, offset: .zero, advance: Float(adv.width))
                    continue
                }
                let pad = FontAtlas.pad
                let gw = Int(ceil(bbox.width)) + pad * 2
                let gh = Int(ceil(bbox.height)) + pad * 2
                let sdf = FontAtlas.renderSDF(font: font, glyph: glyph, bbox: bbox, width: gw, height: gh)
                if penX + gw + 1 > W { penX = 1; penY += rowH + 1; rowH = 0 }
                if penY + gh + 1 > H {
                    logWarn("Font atlas full; some glyphs are missing", "render")
                    break
                }
                for y in 0..<gh {
                    let dst = (penY + y) * W + penX
                    for x in 0..<gw { atlas[dst + x] = sdf[y * gw + x] }
                }
                let uv = Vec4(Float(penX) / Float(W), Float(penY) / Float(H), Float(penX + gw) / Float(W), Float(penY + gh) / Float(H))
                let off = Vec2(Float(bbox.origin.x) - Float(pad), -(Float(bbox.origin.y) + Float(ceil(bbox.height)) + Float(pad)))
                glyphs[fi][ch] = Glyph(uv: uv, quadSize: Vec2(Float(gw), Float(gh)), offset: off, advance: Float(adv.width))
                penX += gw + 1
                rowH = max(rowH, gh)
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: W, height: H, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        if let tex = device.makeTexture(descriptor: d) {
            atlas.withUnsafeBytes { raw in
                tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: W)
            }
            tex.label = "FontAtlas"
            texture = tex
        }
        logInfo(String(format: "Font atlas built in %.0f ms (%d glyphs)", Date().timeIntervalSince(t0) * 1000,
                       glyphs.reduce(0) { $0 + $1.count }), "render")
    }

    private static func fonts() -> [CTFont] {
        let size = refSize
        let ui = NSFont.systemFont(ofSize: size, weight: .medium)
        let title = NSFont(name: "Optima-ExtraBlack", size: size) ?? NSFont(name: "Optima-Bold", size: size)
            ?? NSFont(name: "Didot-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
        let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return [ui as CTFont, title as CTFont, mono as CTFont]
    }

    private static func glyphID(_ font: CTFont, _ ch: Character) -> CGGlyph? {
        let utf16 = Array(String(ch).utf16)
        var ids = [CGGlyph](repeating: 0, count: utf16.count)
        let ok = CTFontGetGlyphsForCharacters(font, utf16, &ids, utf16.count)
        return ok ? ids[0] : nil
    }

    /// Rasterizes one glyph (anti-aliased coverage) and converts it to an 8-bit SDF.
    private static func renderSDF(font: CTFont, glyph: CGGlyph, bbox: CGRect, width w: Int, height h: Int) -> [UInt8] {
        var coverage = [UInt8](repeating: 0, count: w * h)
        coverage.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setFillColor(gray: 1, alpha: 1)
            var g = glyph
            var pos = CGPoint(x: CGFloat(pad) - bbox.origin.x, y: CGFloat(pad) - bbox.origin.y)
            CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
        }
        var inside = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { inside[i] = coverage[i] > 127 }
        let distOut = edt(inside, w, h)                 // distance to the nearest inside pixel
        let distIn = edt(inside.map { !$0 }, w, h)      // distance to the nearest outside pixel
        var out = [UInt8](repeating: 0, count: w * h)
        let range = Float(pad)
        for i in 0..<(w * h) {
            var d = inside[i] ? distIn[i] - 0.5 : -(distOut[i] - 0.5)
            // Sub-pixel refinement from the anti-aliased coverage near the edge.
            if abs(d) < 1.5 { d += (Float(coverage[i]) / 255 - 0.5) * 0.8 }
            let v = 0.5 + d / (2 * range)
            out[i] = UInt8(max(0, min(255, v * 255 + 0.5)))
        }
        return out
    }

    /// 8SSEDT Euclidean distance transform: distance from each pixel to the nearest `true` pixel.
    private static func edt(_ mask: [Bool], _ w: Int, _ h: Int) -> [Float] {
        let far: Int32 = 9999
        var dx = [Int32](repeating: far, count: w * h)
        var dy = [Int32](repeating: far, count: w * h)
        for i in 0..<(w * h) where mask[i] { dx[i] = 0; dy[i] = 0 }
        func d2(_ i: Int) -> Int32 { dx[i] * dx[i] + dy[i] * dy[i] }
        func compare(_ x: Int, _ y: Int, _ ox: Int, _ oy: Int) {
            let nx = x + ox, ny = y + oy
            guard nx >= 0, ny >= 0, nx < w, ny < h else { return }
            let n = ny * w + nx
            guard dx[n] < far else { return }
            let cx = dx[n] + Int32(ox), cy = dy[n] + Int32(oy)
            let i = y * w + x
            if cx * cx + cy * cy < d2(i) { dx[i] = cx; dy[i] = cy }
        }
        for y in 0..<h {
            for x in 0..<w { compare(x, y, -1, 0); compare(x, y, 0, -1); compare(x, y, -1, -1); compare(x, y, 1, -1) }
            for x in stride(from: w - 1, through: 0, by: -1) { compare(x, y, 1, 0) }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) { compare(x, y, 1, 0); compare(x, y, 0, 1); compare(x, y, -1, 1); compare(x, y, 1, 1) }
            for x in 0..<w { compare(x, y, -1, 0) }
        }
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { out[i] = dx[i] >= far ? Float(far) : sqrt(Float(d2(i))) }
        return out
    }

    // MARK: - Metrics and layout

    private func glyph(_ ch: Character, _ font: UIFont) -> Glyph? { glyphs[font.rawValue][ch] ?? glyphs[font.rawValue]["?"] }

    func width(_ s: String, size: Float, font: UIFont) -> Float {
        let scale = size / Float(FontAtlas.refSize)
        var w: Float = 0
        for ch in s { w += (glyph(ch, font)?.advance ?? fallbackAdvance[font.rawValue]) * scale }
        return w
    }

    /// Appends glyph quads (and an optional drop shadow) for a text item.
    func append(_ t: UIText, to quads: inout [UIQuadGPU]) {
        let scale = t.size / Float(FontAtlas.refSize)
        let count = t.text.count
        let total = width(t.text, size: t.size, font: t.font) + t.tracking * Float(max(0, count - 1))
        var x0 = t.x
        switch t.align {
        case .left: break
        case .center: x0 -= total * 0.5
        case .right: x0 -= total
        }
        let baseline = t.y + t.size * 0.82
        func emit(_ dx: Float, _ dy: Float, _ color: Vec4) {
            var pen = x0
            for ch in t.text {
                guard let g = glyph(ch, t.font) else { pen += fallbackAdvance[t.font.rawValue] * scale + t.tracking; continue }
                if g.quadSize.x > 0 {
                    let rect = Vec4((pen + g.offset.x * scale + dx).rounded(), baseline + g.offset.y * scale + dy,
                                    g.quadSize.x * scale, g.quadSize.y * scale)
                    quads.append(UIQuadGPU(rect: rect, color: color, color2: color, params: Vec4(0, 0, 0, 3), extra: g.uv))
                }
                pen += g.advance * scale + t.tracking
            }
        }
        if t.shadow {
            let o = max(1, t.size * 0.06)
            emit(o, o, Vec4(0, 0, 0, 0.6 * t.color.w))
        }
        emit(0, 0, t.color)
    }
}
