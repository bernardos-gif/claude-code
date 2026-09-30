// Runtime shader compilation. Each .metal file is compiled as its own library with
// Common.metal prepended, so one broken effect never takes down the others: its pipelines
// simply fail to build and the renderer skips that pass. Files are watched for hot reload.
import Foundation
import Metal
import BladeCore

final class ShaderLibrary {
    static let files = ["Mesh", "Sky", "Lighting", "SSAO", "Fog", "SSR", "TAA", "Post", "Particles", "Trails", "Decals", "UI"]

    let device: MTLDevice
    private(set) var libraries: [String: MTLLibrary] = [:]
    private(set) var version = 0
    private(set) var errors: [String: String] = [:]
    private let watcher = FileWatcher()
    private var dirty = false

    init(device: MTLDevice) {
        self.device = device
        compileAll()
        let dir = Paths.shaderDirectory
        watcher.watch(dir.appendingPathComponent("Common.metal")) { [weak self] _ in self?.dirty = true }
        for f in ShaderLibrary.files {
            watcher.watch(dir.appendingPathComponent("\(f).metal")) { [weak self] _ in self?.dirty = true }
        }
    }

    /// Polls the shader sources; returns true when the libraries were recompiled.
    func poll(dt: Double) -> Bool {
        watcher.poll(dt: dt)
        guard dirty else { return false }
        dirty = false
        compileAll()
        return true
    }

    func compileAll() {
        let dir = Paths.shaderDirectory
        guard let common = try? String(contentsOf: dir.appendingPathComponent("Common.metal"), encoding: .utf8) else {
            logError("Common.metal not found in \(dir.path)", "shaders")
            return
        }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        options.preserveInvariance = true
        var ok = 0
        for f in ShaderLibrary.files {
            let url = dir.appendingPathComponent("\(f).metal")
            guard let body = try? String(contentsOf: url, encoding: .utf8) else {
                errors[f] = "missing file"
                logError("Shader \(f).metal missing", "shaders")
                continue
            }
            let source = common + "\n// ---- \(f).metal\n" + body
            do {
                let t0 = Date()
                let lib = try device.makeLibrary(source: source, options: options)
                libraries[f] = lib
                errors[f] = nil
                ok += 1
                logDebug(String(format: "Compiled %@.metal in %.0f ms", f, Date().timeIntervalSince(t0) * 1000), "shaders")
            } catch {
                errors[f] = "\(error)"
                logError("Shader \(f).metal failed to compile (keeping the previous version if any):\n\(error)", "shaders")
            }
        }
        version += 1
        logInfo("Shaders compiled: \(ok)/\(ShaderLibrary.files.count) (version \(version))", "shaders")
    }

    func function(_ name: String, in file: String) -> MTLFunction? {
        guard let lib = libraries[file] else { return nil }
        let f = lib.makeFunction(name: name)
        if f == nil { logError("Shader function \(name) not found in \(file).metal", "shaders") }
        return f
    }
}
