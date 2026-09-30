// Immediate-mode UI draw list. Menus and HUD are laid out in BladeCore and rendered by the
// platform layer (SDF rounded rects + SDF text atlas). Coordinates are pixels, origin at
// the top-left of the drawable.
import Foundation

/// GPU UI quad (80 bytes, mirrored in UI.metal).
public struct UIQuadGPU {
    public var rect: Vec4        // x, y, w, h (pixels)
    public var color: Vec4       // top color (linear, premultiplied in shader)
    public var color2: Vec4      // bottom color (gradient)
    public var params: Vec4      // x corner radius, y border width, z glow, w kind (0 rect, 1 ring arc, 2 diamond, 3 glyph)
    public var extra: Vec4       // border color rgb + a / arc (start, end, thickness) / glyph uv rect
    public init(rect: Vec4, color: Vec4, color2: Vec4, params: Vec4, extra: Vec4) {
        self.rect = rect; self.color = color; self.color2 = color2; self.params = params; self.extra = extra
    }
}

public enum UIFont: Int { case ui = 0, title = 1, mono = 2 }

public enum UIAlign { case left, center, right }

/// Text measurement provided by the platform (real font metrics); defaults approximate.
public protocol FontMetrics: AnyObject {
    func width(_ s: String, size: Float, font: UIFont) -> Float
}

final class ApproxMetrics: FontMetrics {
    func width(_ s: String, size: Float, font: UIFont) -> Float {
        Float(s.count) * size * (font == .title ? 0.62 : (font == .mono ? 0.6 : 0.52))
    }
}

public enum UIMetrics {
    public static var provider: FontMetrics = ApproxMetrics()
}

public struct UIText {
    public var text: String
    public var x: Float
    public var y: Float          // baseline-ish top of line
    public var size: Float
    public var color: Vec4
    public var font: UIFont
    public var align: UIAlign
    public var shadow: Bool
    public var tracking: Float
}

public enum UIItem {
    case quad(UIQuadGPU)
    case text(UIText)
}

public struct UIDrawList {
    public var items: [UIItem] = []
    public var width: Float = 1920
    public var height: Float = 1080
    public init() {}

    /// UI scale relative to 1080p.
    public var s: Float { height / 1080 }

    public mutating func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ c: Vec4, c2: Vec4? = nil, radius: Float = 0,
                              border: Float = 0, borderColor: Vec4 = .zero, glow: Float = 0) {
        items.append(.quad(UIQuadGPU(rect: Vec4(x, y, w, h), color: c, color2: c2 ?? c, params: Vec4(radius, border, glow, 0),
                                     extra: borderColor)))
    }

    public mutating func diamond(_ cx: Float, _ cy: Float, _ r: Float, _ c: Vec4, border: Float = 0, borderColor: Vec4 = .zero, glow: Float = 0) {
        items.append(.quad(UIQuadGPU(rect: Vec4(cx - r, cy - r, r * 2, r * 2), color: c, color2: c, params: Vec4(0, border, glow, 2), extra: borderColor)))
    }

    /// Ring arc: angles in radians (0 = up, clockwise), thickness in pixels.
    public mutating func arc(_ cx: Float, _ cy: Float, _ r: Float, start: Float, end: Float, thickness: Float, _ c: Vec4, glow: Float = 0) {
        items.append(.quad(UIQuadGPU(rect: Vec4(cx - r - 2, cy - r - 2, r * 2 + 4, r * 2 + 4), color: c, color2: c,
                                     params: Vec4(r, 0, glow, 1), extra: Vec4(start, end, thickness, 0))))
    }

    public mutating func text(_ t: String, _ x: Float, _ y: Float, size: Float, _ c: Vec4, font: UIFont = .ui, align: UIAlign = .left,
                              shadow: Bool = true, tracking: Float = 0) {
        guard !t.isEmpty else { return }
        items.append(.text(UIText(text: t, x: x, y: y, size: size, color: c, font: font, align: align, shadow: shadow, tracking: tracking)))
    }

    public func measure(_ t: String, size: Float, font: UIFont = .ui) -> Float {
        UIMetrics.provider.width(t, size: size, font: font)
    }

    /// Horizontal bar with background, fill and optional delayed "damage" fill.
    public mutating func bar(_ x: Float, _ y: Float, _ w: Float, _ h: Float, fill: Float, color: Vec4, back: Vec4 = Vec4(0, 0, 0, 0.55),
                             trail: Float? = nil, trailColor: Vec4 = Vec4(1, 0.9, 0.7, 0.8), centered: Bool = false, radius: Float = 2) {
        rect(x - 1, y - 1, w + 2, h + 2, back, radius: radius + 1, border: 1, borderColor: Vec4(1, 1, 1, 0.12))
        let f = saturatef(fill)
        if centered {
            let fw = w * f
            if let t = trail, t > f { rect(x + (w - w * t) / 2, y, w * t, h, trailColor, radius: radius) }
            rect(x + (w - fw) / 2, y, fw, h, color, c2: color * Vec4(0.7, 0.7, 0.7, 1), radius: radius, glow: 0.4)
        } else {
            if let t = trail, t > f { rect(x, y, w * saturatef(t), h, trailColor, radius: radius) }
            rect(x, y, w * f, h, color, c2: color * Vec4(0.65, 0.65, 0.65, 1), radius: radius, glow: 0.3)
        }
    }
}

/// Palette used by all menus and the HUD.
public enum UIColors {
    public static let text = Vec4(0.93, 0.9, 0.84, 1)
    public static let dim = Vec4(0.6, 0.58, 0.55, 1)
    public static let accent = Vec4(0.86, 0.22, 0.16, 1)
    public static let gold = Vec4(1.0, 0.78, 0.35, 1)
    public static let panel = Vec4(0.04, 0.035, 0.04, 0.78)
    public static let panelBorder = Vec4(0.9, 0.75, 0.5, 0.18)
    public static let health = Vec4(0.72, 0.08, 0.07, 1)
    public static let posture = Vec4(1.0, 0.62, 0.12, 1)
    public static let stamina = Vec4(0.55, 0.75, 0.25, 1)
    public static let selected = Vec4(0.95, 0.35, 0.2, 0.22)

    public static func telegraph(_ t: Telegraph) -> Vec4 {
        switch t {
        case .white, .none: return Vec4(1, 1, 1, 1)
        case .red: return Vec4(1, 0.12, 0.08, 1)
        case .purple: return Vec4(0.72, 0.35, 1, 1)
        case .gold: return Vec4(1, 0.8, 0.25, 1)
        }
    }
}
