import AVFoundation
import CoreAudio
@preconcurrency import WebRTC

/// GPT Live's audio when the call must not record from the default input. Recording from a Bluetooth headset's
/// microphone switches it to the call profile (HFP), where the assistant is barely audible, and WebRTC's own Mac
/// ADM only uses the default devices. This `RTCAudioDevice` records the input chosen in Ajustes → Voz with one
/// AVAudioEngine and plays to the default output with another; the system's default devices never change.
/// Echo is still cancelled by WebRTC's audio processing (AEC3), which sees this playout as its reference. Apple's
/// voice processing is not used: it drives the default devices and ducks other audio.
///
/// WebRTC calls every member on its audio device thread; device changes are handed to it with `dispatchAsync`.
/// The engines' realtime blocks only touch the preallocated sample buffers and the delegate's blocks, which are
/// set before an engine starts and cleared after it stops.
final class MacVoiceAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
  /// Only when the chosen input is not the default one; otherwise WebRTC's ADM keeps following the devices.
  static var needed: Bool {
    guard let chosen = MacMicrophone.recordingInput() else { return false }
    return chosen.device != MacMicrophone.defaultInput(among: MacMicrophone.inputs())?.device
  }

  private static let playoutFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
    interleaved: false)!
  private static let capacity = 16_384
  private let recorded = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)
  private let played = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)
  private var delegate: (any RTCAudioDeviceDelegate)?
  private var deliver: RTCAudioDeviceDeliverRecordedDataBlock?
  private var playout: RTCAudioDeviceGetPlayoutDataBlock?
  private var input: AVAudioEngine?
  private var output: AVAudioEngine?
  private var inputObserver: NSObjectProtocol?
  private var outputObserver: NSObjectProtocol?

  private(set) var deviceInputSampleRate: Double = 48_000
  let inputIOBufferDuration: TimeInterval = 0.01
  let inputNumberOfChannels = 1
  private(set) var inputLatency: TimeInterval = 0
  var deviceOutputSampleRate: Double { Self.playoutFormat.sampleRate }
  let outputIOBufferDuration: TimeInterval = 0.01
  let outputNumberOfChannels = 1
  private(set) var outputLatency: TimeInterval = 0
  var isInitialized: Bool { delegate != nil }
  private(set) var isPlayoutInitialized = false
  private(set) var isPlaying = false
  private(set) var isRecordingInitialized = false
  private(set) var isRecording = false

  deinit {
    recorded.deallocate()
    played.deallocate()
  }

  func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
    self.delegate = delegate
    deliver = delegate.deliverRecordedData
    playout = delegate.getPlayoutData
    // WebRTC reads the input sample rate right after this, before initializing the recording.
    return input != nil || makeInput()
  }

  func terminateDevice() -> Bool {
    _ = stopRecording()
    _ = stopPlayout()
    removeInput()
    removeOutput()
    isPlayoutInitialized = false
    isRecordingInitialized = false
    delegate = nil; deliver = nil; playout = nil
    return true
  }

  func initializePlayout() -> Bool {
    isPlayoutInitialized = output != nil || makeOutput()
    return isPlayoutInitialized
  }

  func startPlayout() -> Bool {
    guard let output else { return false }
    do { try output.start() } catch {
      VoiceTransport.log.error("phase=mac-audio-playout-failed error=\(error.localizedDescription, privacy: .public)")
      return false
    }
    isPlaying = true
    return true
  }

  func stopPlayout() -> Bool {
    output?.stop()
    isPlaying = false
    return true
  }

  func initializeRecording() -> Bool {
    isRecordingInitialized = input != nil || makeInput()
    return isRecordingInitialized
  }

  func startRecording() -> Bool {
    guard let input else { return false }
    do { try input.start() } catch {
      VoiceTransport.log.error("phase=mac-audio-record-failed error=\(error.localizedDescription, privacy: .public)")
      return false
    }
    isRecording = true
    return true
  }

  func stopRecording() -> Bool {
    input?.stop()
    isRecording = false
    return true
  }

  private func makeInput() -> Bool {
    let engine = AVAudioEngine()
    let node = engine.inputNode
    let chosen = MacMicrophone.recordingInput()
    if let chosen, let unit = node.audioUnit {
      var device = chosen.device
      let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &device, UInt32(MemoryLayout<AudioDeviceID>.size))
      if status != noErr { VoiceTransport.log.error("phase=mac-audio-input-unavailable status=\(status, privacy: .public)") }
    }
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { return false }
    let sink = AVAudioSinkNode { [unowned self] timestamp, frames, data in record(timestamp, frames, data) }
    engine.attach(sink)
    engine.connect(node, to: sink, format: format)
    deviceInputSampleRate = format.sampleRate
    inputLatency = node.presentationLatency
    input = engine
    inputObserver = observe(engine) { device in device.restartInput() }
    VoiceTransport.log.notice("phase=mac-audio-input device=\(chosen?.name ?? "default", privacy: .public) rate=\(format.sampleRate, privacy: .public)")
    return true
  }

  private func makeOutput() -> Bool {
    let engine = AVAudioEngine()
    let source = AVAudioSourceNode(format: Self.playoutFormat) { [unowned self] silence, timestamp, frames, data in
      play(silence, timestamp, frames, data)
    }
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: Self.playoutFormat)
    engine.prepare()
    outputLatency = engine.outputNode.presentationLatency
    output = engine
    outputObserver = observe(engine) { device in device.restartOutput() }
    return true
  }

  private func removeInput() {
    input?.stop()
    inputObserver.map(NotificationCenter.default.removeObserver)
    input = nil; inputObserver = nil
  }

  private func removeOutput() {
    output?.stop()
    outputObserver.map(NotificationCenter.default.removeObserver)
    output = nil; outputObserver = nil
  }

  /// A device lost or reconfigured stops the engine: rebuild it on WebRTC's thread and carry on.
  private func observe(_ engine: AVAudioEngine, restart: @escaping @Sendable (MacVoiceAudioDevice) -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) {
      [weak self, weak delegate] _ in
      delegate?.dispatchAsync { if let self { restart(self) } }
    }
  }

  private func restartInput() {
    guard let input, isRecording, !input.isRunning else { return }
    let rate = deviceInputSampleRate
    removeInput()
    isRecording = false
    guard makeInput() else { return }
    delegate?.notifyAudioInputInterrupted()
    if rate != deviceInputSampleRate { delegate?.notifyAudioInputParametersChange() }
    _ = startRecording()
  }

  private func restartOutput() {
    guard let output, isPlaying, !output.isRunning else { return }
    removeOutput()
    isPlaying = false
    guard makeOutput() else { return }
    delegate?.notifyAudioOutputInterrupted()
    _ = startPlayout()
  }

  /// The first input channel, as 16-bit mono PCM for WebRTC.
  private func record(_ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: AVAudioFrameCount,
                      _ data: UnsafePointer<AudioBufferList>) -> OSStatus {
    guard let deliver, data.pointee.mNumberBuffers > 0,
      let samples = data.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    var offset = 0
    while offset < Int(frames) {
      let count = min(Int(frames) - offset, Self.capacity)
      for index in 0..<count {
        recorded[index] = Int16(max(-1, min(1, samples[offset + index])) * Float(Int16.max))
      }
      var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
        mDataByteSize: UInt32(count * MemoryLayout<Int16>.size), mData: recorded))
      var flags = AudioUnitRenderActionFlags()
      _ = deliver(&flags, timestamp, 1, UInt32(count), &list, nil, nil)
      offset += count
    }
    return noErr
  }

  private func play(_ silence: UnsafeMutablePointer<ObjCBool>, _ timestamp: UnsafePointer<AudioTimeStamp>,
                    _ frames: AVAudioFrameCount, _ data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    guard data.pointee.mNumberBuffers > 0,
      let samples = data.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    guard let playout else {
      samples.update(repeating: 0, count: Int(frames))
      silence.pointee = true
      return noErr
    }
    var offset = 0
    while offset < Int(frames) {
      let count = min(Int(frames) - offset, Self.capacity)
      var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
        mDataByteSize: UInt32(count * MemoryLayout<Int16>.size), mData: played))
      var flags = AudioUnitRenderActionFlags()
      _ = playout(&flags, timestamp, 0, UInt32(count), &list)
      for index in 0..<count { samples[offset + index] = Float(played[index]) / 32_768 }
      offset += count
    }
    return noErr
  }
}
