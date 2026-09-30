@_exported import Foundation
public typealias OSStatus = Int32
public let noErr: OSStatus = 0
public typealias AVAudioFrameCount = UInt32
public struct AudioTimeStamp {}
public struct AudioBuffer { public var mNumberChannels: UInt32 = 0; public var mDataByteSize: UInt32 = 0; public var mData: UnsafeMutableRawPointer? }
public struct AudioBufferList { public var mNumberBuffers: UInt32 = 0; public var mBuffers: AudioBuffer = AudioBuffer() }
public struct UnsafeMutableAudioBufferListPointer: RandomAccessCollection, MutableCollection {
    public init(_ p: UnsafeMutablePointer<AudioBufferList>) {}
    public var startIndex: Int { 0 }
    public var endIndex: Int { 0 }
    public subscript(i: Int) -> AudioBuffer { get { AudioBuffer() } set {} }
}
open class AVAudioFormat: NSObject { public init?(standardFormatWithSampleRate: Double, channels: UInt32) {}; open var sampleRate: Double { 48000 } }
open class AVAudioNode: NSObject { open func outputFormat(forBus bus: Int) -> AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)! } }
open class AVAudioMixerNode: AVAudioNode { open var outputVolume: Float = 1 }
open class AVAudioOutputNode: AVAudioNode {}
public typealias AVAudioSourceNodeRenderBlock = (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, AVAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> OSStatus
open class AVAudioSourceNode: AVAudioNode { public init(format: AVAudioFormat, renderBlock block: @escaping AVAudioSourceNodeRenderBlock) {} }
open class AVAudioEngine: NSObject {
    open var mainMixerNode: AVAudioMixerNode { AVAudioMixerNode() }
    open var outputNode: AVAudioOutputNode { AVAudioOutputNode() }
    open func attach(_ node: AVAudioNode) {}
    open func connect(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) {}
    open func prepare() {}
    open func start() throws {}
    open func stop() {}
}
extension NSNotification.Name { public static let AVAudioEngineConfigurationChange = NSNotification.Name("AVAudioEngineConfigurationChangeNotification") }
