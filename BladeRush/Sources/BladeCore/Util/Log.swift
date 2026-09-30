// File + console logger. The log file path is printed at startup; paste its contents
// back when reporting bugs. The last lines are also mirrored into the debug overlay.
import Foundation

public enum LogLevel: Int, Comparable {
    case debug = 0, info, warn, error
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warn: return "WARN "
        case .error: return "ERROR"
        }
    }
}

public final class Log {
    public static let shared = Log()

    private let lock = NSLock()
    private var handle: FileHandle?
    public private(set) var fileURL: URL?
    public var minLevel: LogLevel = .info
    public var echoToConsole = true
    /// Recent lines for the in-game debug overlay (ring buffer).
    public private(set) var recent: [String] = []
    private let startTime = Date()
    private let maxRecent = 14

    private init() {}

    /// Opens (truncates) the log file in the given directory.
    public func open(directory: URL, fileName: String = "bladerush.log") {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        // Keep the previous session's log for comparison.
        let prev = directory.appendingPathComponent("bladerush.previous.log")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        fileURL = url
    }

    public func write(_ level: LogLevel, _ category: String, _ message: String) {
        guard level >= minLevel else { return }
        let t = Date().timeIntervalSince(startTime)
        let line = String(format: "[%9.3f] %@ [%@] %@", t, level.tag, category, message)
        lock.lock()
        recent.append(line)
        if recent.count > maxRecent { recent.removeFirst(recent.count - maxRecent) }
        if let h = handle, let d = (line + "\n").data(using: .utf8) { h.write(d) }
        lock.unlock()
        if echoToConsole { print(line) }
    }

    public func flush() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.synchronize()
    }

    public func recentLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recent
    }
}

@inlinable public func logDebug(_ msg: @autoclosure () -> String, _ cat: String = "game") {
    if Log.shared.minLevel <= .debug { Log.shared.write(.debug, cat, msg()) }
}
public func logInfo(_ msg: String, _ cat: String = "game") { Log.shared.write(.info, cat, msg) }
public func logWarn(_ msg: String, _ cat: String = "game") { Log.shared.write(.warn, cat, msg) }
public func logError(_ msg: String, _ cat: String = "game") { Log.shared.write(.error, cat, msg) }

/// Measures wall time of a closure and logs it (used for load-time profiling).
@discardableResult
public func timed<T>(_ label: String, _ cat: String = "perf", _ body: () throws -> T) rethrows -> T {
    let t0 = Date()
    let r = try body()
    let ms = Date().timeIntervalSince(t0) * 1000
    logInfo(String(format: "%@: %.1f ms", label, ms), cat)
    return r
}

/// Lightweight CPU section profiler for the debug overlay.
public final class CPUProfiler {
    public private(set) var sections: [(String, Double)] = []
    private var current: [String: Double] = [:]
    private var order: [String] = []
    private var smoothed: [String: Double] = [:]

    public init() {}

    public func begin() { current.removeAll(keepingCapacity: true); order.removeAll(keepingCapacity: true) }

    public func measure<T>(_ name: String, _ body: () -> T) -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = body()
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        if current[name] == nil { order.append(name) }
        current[name, default: 0] += dt
        return r
    }

    public func end() {
        for (k, v) in current { smoothed[k] = (smoothed[k] ?? v) * 0.9 + v * 0.1 }
        sections = order.map { ($0, smoothed[$0] ?? 0) }
    }
}
