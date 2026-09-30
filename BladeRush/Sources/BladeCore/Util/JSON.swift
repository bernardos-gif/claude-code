// JSON helpers: comment stripping, defaults merging and polling hot-reload.
import Foundation

public enum JSONUtil {
    /// Removes `//` line comments and `/* */` block comments outside of strings, plus
    /// trailing commas before `}` / `]`, so data files can be annotated by hand.
    public static func stripComments(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.utf8.count)
        let chars = Array(input.unicodeScalars)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.unicodeScalars.append(c)
                if c == "\\" && i + 1 < chars.count { out.unicodeScalars.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.unicodeScalars.append(c); i += 1; continue }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "," {
                // Drop trailing commas.
                var j = i + 1
                while j < chars.count && (chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r") { j += 1 }
                if j < chars.count && (chars[j] == "}" || chars[j] == "]") { i += 1; continue }
            }
            out.unicodeScalars.append(c)
            i += 1
        }
        return out
    }

    public static func parseObject(_ data: Data) throws -> Any {
        let text = String(decoding: data, as: UTF8.self)
        let cleaned = stripComments(text)
        return try JSONSerialization.jsonObject(with: Data(cleaned.utf8), options: [.fragmentsAllowed])
    }

    /// Recursively merges `overlay` on top of `base`. Dictionaries merge key-by-key;
    /// everything else (including arrays) is replaced.
    public static func deepMerge(_ base: Any, _ overlay: Any) -> Any {
        guard var b = base as? [String: Any], let o = overlay as? [String: Any] else { return overlay }
        for (k, v) in o {
            if let bv = b[k] { b[k] = deepMerge(bv, v) } else { b[k] = v }
        }
        return b
    }

    /// Decodes `T` from JSON where missing fields fall back to the values in `defaults`.
    public static func decodeMerged<T: Codable>(_ type: T.Type, from data: Data, defaults: T) throws -> T {
        let defData = try JSONEncoder().encode(defaults)
        let defObj = try JSONSerialization.jsonObject(with: defData)
        let userObj = try parseObject(data)
        let merged = deepMerge(defObj, userObj)
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(T.self, from: mergedData)
    }

    /// Decodes an array of `T` where each element is merged over `itemDefaults`.
    public static func decodeArrayMerged<T: Codable>(_ type: T.Type, from any: Any, itemDefaults: T) throws -> [T] {
        guard let arr = any as? [Any] else { throw NSError(domain: "JSON", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected array"]) }
        let defData = try JSONEncoder().encode(itemDefaults)
        let defObj = try JSONSerialization.jsonObject(with: defData)
        var result: [T] = []
        for (i, item) in arr.enumerated() {
            let merged = deepMerge(defObj, item)
            let d = try JSONSerialization.data(withJSONObject: merged)
            do {
                result.append(try JSONDecoder().decode(T.self, from: d))
            } catch {
                throw NSError(domain: "JSON", code: 2, userInfo: [NSLocalizedDescriptionKey: "item \(i): \(describe(error))"])
            }
        }
        return result
    }

    /// Decodes plain JSON (with comments allowed).
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let obj = try parseObject(data)
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: d)
    }

    public static func encodePretty<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(value)
    }

    /// Human-readable description of a DecodingError including the coding path.
    public static func describe(_ error: Error) -> String {
        if let e = error as? DecodingError {
            switch e {
            case .keyNotFound(let k, let ctx): return "missing key '\(k.stringValue)' at \(path(ctx.codingPath))"
            case .typeMismatch(let t, let ctx): return "type mismatch (\(t)) at \(path(ctx.codingPath)): \(ctx.debugDescription)"
            case .valueNotFound(let t, let ctx): return "null value (\(t)) at \(path(ctx.codingPath))"
            case .dataCorrupted(let ctx): return "corrupted at \(path(ctx.codingPath)): \(ctx.debugDescription)"
            @unknown default: return "\(e)"
            }
        }
        return error.localizedDescription
    }

    private static func path(_ p: [CodingKey]) -> String {
        p.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

/// Polls files for modification and invokes callbacks (used for hot reload of Data/*.json
/// and shader sources). Polling every half second is cheap and portable.
public final class FileWatcher {
    private struct Entry {
        var url: URL
        var lastModified: Date?
        var callback: (URL) -> Void
    }
    private var entries: [Entry] = []
    private var accumulator: Double = 0
    public var interval: Double = 0.5

    public init() {}

    public func watch(_ url: URL, callback: @escaping (URL) -> Void) {
        entries.append(Entry(url: url, lastModified: FileWatcher.modDate(url), callback: callback))
    }

    public func poll(dt: Double) {
        accumulator += dt
        guard accumulator >= interval else { return }
        accumulator = 0
        for i in entries.indices {
            let m = FileWatcher.modDate(entries[i].url)
            if let m = m, m != entries[i].lastModified {
                entries[i].lastModified = m
                entries[i].callback(entries[i].url)
            }
        }
    }

    public static func modDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
