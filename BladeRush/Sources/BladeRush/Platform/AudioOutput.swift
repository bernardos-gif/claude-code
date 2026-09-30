// Audio output: an AVAudioSourceNode pulls stereo float samples from the procedural mixer
// on the real-time audio thread (the mixer is lock-free on that path; game code talks to it
// through a command queue).
import AVFoundation
import BladeCore

final class AudioOutput {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var running = false

    init(mixer: AudioMixer) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(kSampleRate), channels: 2) else {
            logError("Could not create the audio format", "audio")
            return
        }
        // Warm the mixer's scratch buffers so the audio thread never allocates.
        var warmL = [Float](repeating: 0, count: 4096)
        var warmR = [Float](repeating: 0, count: 4096)
        warmL.withUnsafeMutableBufferPointer { l in
            warmR.withUnsafeMutableBufferPointer { r in
                mixer.render(frames: 4096, left: l.baseAddress!, right: r.baseAddress!)
            }
        }
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            if abl.count >= 2, let l = abl[0].mData?.assumingMemoryBound(to: Float.self), let r = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                mixer.render(frames: frames, left: l, right: r)
            } else if abl.count == 1, let l = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                mixer.render(frames: frames, left: l, right: l)
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        start()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            logInfo("Audio configuration changed; restarting the engine", "audio")
            self?.start()
        }
    }

    func start() {
        do {
            engine.prepare()
            try engine.start()
            running = true
            logInfo("Audio engine running at \(engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz", "audio")
        } catch {
            running = false
            logError("Audio engine failed to start: \(error)", "audio")
        }
    }

    func stop() {
        engine.stop()
        running = false
    }
}
