@_exported import CoreGraphics
open class CTFont: NSObject {}
public enum CTFontOrientation: UInt32 { case `default` = 0, horizontal = 1, vertical = 2 }
public func CTFontGetGlyphsForCharacters(_ font: CTFont, _ characters: UnsafePointer<UInt16>, _ glyphs: UnsafeMutablePointer<CGGlyph>, _ count: CFIndex) -> Bool { true }
public func CTFontGetAdvancesForGlyphs(_ font: CTFont, _ orientation: CTFontOrientation, _ glyphs: UnsafePointer<CGGlyph>, _ advances: UnsafeMutablePointer<CGSize>?, _ count: CFIndex) -> Double { 0 }
public func CTFontGetBoundingRectsForGlyphs(_ font: CTFont, _ orientation: CTFontOrientation, _ glyphs: UnsafePointer<CGGlyph>, _ boundingRects: UnsafeMutablePointer<CGRect>?, _ count: CFIndex) -> CGRect { .zero }
public func CTFontDrawGlyphs(_ font: CTFont, _ glyphs: UnsafePointer<CGGlyph>, _ positions: UnsafePointer<CGPoint>, _ count: Int, _ context: CGContext) {}
