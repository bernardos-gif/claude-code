// Per-frame upload ring (one per frame in flight) and the GPU mesh cache.
import Foundation
import Metal
import BladeCore

/// Bump allocator over a shared buffer. The renderer owns three (triple buffering) and only
/// resets one after the GPU has finished the frame that used it.
final class UploadRing {
    let device: MTLDevice
    private(set) var buffer: MTLBuffer
    private var offset = 0
    private var capacity: Int
    private var overflowed = false
    private(set) var peak = 0

    init(device: MTLDevice, capacity: Int, label: String) {
        self.device = device
        self.capacity = capacity
        buffer = device.makeBuffer(length: capacity, options: .storageModeShared)!
        buffer.label = label
    }

    func reset() {
        if overflowed {
            capacity *= 2
            if let b = device.makeBuffer(length: capacity, options: .storageModeShared) {
                b.label = buffer.label
                buffer = b
                logInfo("Upload ring grown to \(capacity / (1024 * 1024)) MB", "render")
            }
            overflowed = false
        }
        offset = 0
    }

    /// Copies raw bytes; returns (buffer, offset). Offsets are 256-byte aligned.
    func push(bytes: UnsafeRawPointer?, length: Int) -> (MTLBuffer, Int) {
        let len = max(length, 16)
        let aligned = (offset + 255) & ~255
        if aligned + len > capacity {
            overflowed = true
            let b = device.makeBuffer(length: len, options: .storageModeShared)!
            if let src = bytes, length > 0 { b.contents().copyMemory(from: src, byteCount: length) }
            return (b, 0)
        }
        if let src = bytes, length > 0 {
            (buffer.contents() + aligned).copyMemory(from: src, byteCount: length)
        }
        offset = aligned + len
        peak = max(peak, offset)
        return (buffer, aligned)
    }

    func push<T>(_ items: [T]) -> (MTLBuffer, Int) {
        items.withUnsafeBytes { raw in push(bytes: raw.baseAddress, length: raw.count) }
    }

    func push<T>(value: T) -> (MTLBuffer, Int) {
        var v = value
        return withUnsafeBytes(of: &v) { raw in push(bytes: raw.baseAddress, length: raw.count) }
    }
}

/// GPU copies of static meshes, keyed by MeshData.id; evicted when unused for a while.
final class MeshCache {
    struct Entry {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        var lastUsed: Int
        let bytes: Int
    }

    let device: MTLDevice
    private var entries: [Int: Entry] = [:]
    private(set) var totalBytes = 0

    init(device: MTLDevice) { self.device = device }

    func get(_ mesh: MeshData, frame: Int) -> Entry? {
        if var e = entries[mesh.id] {
            e.lastUsed = frame
            entries[mesh.id] = e
            return e
        }
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty else { return nil }
        let vb = mesh.vertices.withUnsafeBytes { raw in device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared) }
        let ib = mesh.indices.withUnsafeBytes { raw in device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared) }
        guard let v = vb, let i = ib else { return nil }
        v.label = mesh.name
        let bytes = v.length + i.length
        let e = Entry(vertices: v, indices: i, indexCount: mesh.indices.count, lastUsed: frame, bytes: bytes)
        entries[mesh.id] = e
        totalBytes += bytes
        return e
    }

    func evict(frame: Int, olderThan frames: Int = 600) {
        guard frame % 120 == 0 else { return }
        let stale = entries.filter { frame - $0.value.lastUsed > frames }
        for (k, e) in stale {
            entries.removeValue(forKey: k)
            totalBytes -= e.bytes
        }
    }

    var count: Int { entries.count }
}
