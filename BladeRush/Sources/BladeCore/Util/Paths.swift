// Filesystem locations: save data, logs, caches, data files and shader sources.
import Foundation

public enum Paths {
    /// Package root, derived from this source file's compile-time location
    /// (Sources/BladeCore/Util/Paths.swift). Used in development so edits to Data/*.json
    /// and shader sources hot-reload without rebuilding the .app.
    public static let sourceRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Util
            .deletingLastPathComponent() // BladeCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // package root
    }()

    /// ~/Library/Application Support/BladeRush (macOS) or ~/.local/share/BladeRush (Linux).
    public static let appSupport: URL = {
        if let override = ProcessInfo.processInfo.environment["BLADERUSH_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BladeRush", isDirectory: true)
    }()

    public static var logs: URL { appSupport.appendingPathComponent("Logs", isDirectory: true) }
    public static var cache: URL { appSupport.appendingPathComponent("Cache", isDirectory: true) }
    public static var saveFile: URL { appSupport.appendingPathComponent("save.json") }
    public static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }

    public static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Bundle resources directory (inside the .app), if running from a bundle.
    public static var bundleResources: URL? { Bundle.main.resourceURL }

    /// Directory containing the JSON data files (tuning, weapons, bosses, ...).
    /// Priority: $BLADERUSH_DATA, the source tree (dev, enables hot reload), then the app bundle.
    public static let dataDirectory: URL = {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["BLADERUSH_DATA"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let dev = sourceRoot.appendingPathComponent("Data", isDirectory: true)
        let preferBundle = ProcessInfo.processInfo.environment["BLADERUSH_USE_BUNDLE"] == "1"
        if !preferBundle, fm.fileExists(atPath: dev.appendingPathComponent("tuning.json").path) { return dev }
        if let res = bundleResources?.appendingPathComponent("Data", isDirectory: true),
           fm.fileExists(atPath: res.appendingPathComponent("tuning.json").path) { return res }
        return dev
    }()

    /// Directory containing Metal shader sources (compiled at runtime).
    public static let shaderDirectory: URL = {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["BLADERUSH_SHADERS"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let dev = sourceRoot.appendingPathComponent("Sources/BladeRush/Shaders", isDirectory: true)
        let preferBundle = ProcessInfo.processInfo.environment["BLADERUSH_USE_BUNDLE"] == "1"
        if !preferBundle, fm.fileExists(atPath: dev.path) { return dev }
        if let res = bundleResources?.appendingPathComponent("Shaders", isDirectory: true),
           fm.fileExists(atPath: res.path) { return res }
        return dev
    }()

    public static func ensureDirectories() {
        for d in [appSupport, logs, cache] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    public static func dataFile(_ name: String) -> URL { dataDirectory.appendingPathComponent(name) }
}
