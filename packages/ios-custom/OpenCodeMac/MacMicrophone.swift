import AVFoundation
import CoreAudio
import Foundation
import OpenCodeKit
import os

/// Which input dictation records from. Automático follows the system's default input unless it is a Bluetooth
/// headset: recording from its microphone switches it to the call profile (HFP), which turns the music in it into
/// phone-quality audio, so the Mac's built-in microphone records instead. The system default input never changes.
enum MacMicrophone {
  static let key = "OpenCodeMacMicrophone"
  static let automatic = "automatic"
  static let system = "system"
  static let pausesMediaKey = "OpenCodeMacDictationPausesMedia"
  static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "dictation")

  struct Input: Identifiable, Hashable {
    /// The Core Audio UID, which survives reconnecting and restarting, unlike the device ID.
    let id: String
    let name: String
    let device: AudioDeviceID
    let transport: UInt32
    var bluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var builtIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
  }

  static func inputs() -> [Input] {
    devices().compactMap { device in
      guard channels(device) > 0, let uid = string(device, kAudioDevicePropertyDeviceUID) else { return nil }
      return Input(id: uid, name: string(device, kAudioObjectPropertyName) ?? uid, device: device,
        transport: value(device, kAudioDevicePropertyTransportType) ?? 0)
    }
  }

  /// The saved choice, or Automático when it is unset or its device is gone.
  static func choice(among inputs: [Input]) -> String {
    let saved = UserDefaults.standard.string(forKey: key) ?? automatic
    return saved == system || inputs.contains(where: { $0.id == saved }) ? saved : automatic
  }

  /// The device to record from; nil follows the system default input.
  static func recordingInput() -> Input? {
    let inputs = inputs()
    switch choice(among: inputs) {
    case system: return nil
    case automatic:
      guard defaultInput(among: inputs)?.bluetooth == true else { return nil }
      return inputs.first(where: \.builtIn)
    case let uid: return inputs.first { $0.id == uid }
    }
  }

  static func defaultInput(among inputs: [Input]) -> Input? {
    let device = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) as AudioDeviceID?
    return inputs.first { $0.device == device }
  }

  private static func devices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
    return devices
  }

  private static func channels(_ device: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { list.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
      .reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString>.size)
    var text = "" as CFString
    // The property returns a +1 reference, which this variable then owns.
    let status = withUnsafeMutablePointer(to: &text) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
    return status == noErr ? text as String : nil
  }

  private static func value<Value: FixedWidthInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Value? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Value>.size)
    var result = Value.zero
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
  }
}

/// Continuous PCM from the chosen input, with pause/resume on the same file, as AVAudioRecorder did on iOS.
@MainActor final class MicrophoneVoiceCapture: VoiceRecordingCapture {
  private var recording: MacMicrophoneRecording?
  private var pausedMedia = false
  /// stop() advances it without waiting for an opening in flight. The audio queue checks it under the lock right
  /// before recording, so a stopped opening never records and stop() waits at most for that engine start.
  private let epoch = OSAllocatedUnfairLock(initialState: 0)
  var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
  func authorize() async -> Bool { authorized ? true : await AVCaptureDevice.requestAccess(for: .audio) }
  func start(at file: URL) async throws {
    let epoch = epoch, ticket = epoch.withLock { $0 }
    let opened = try await DictationAudioSession.activate(.playAndRecord) {
      try epoch.withLock { current in
        guard current == ticket else { throw CancellationError() }
        let recording = try MacMicrophoneRecording(file: file)
        try recording.record()
        return QueuedAudio(value: recording)
      }
    }
    guard epoch.withLock({ $0 }) == ticket else {
      // stop() came after this opening began recording: none of it may remain or look like pending audio.
      opened.value.stop()
      try? FileManager.default.removeItem(at: file)
      throw CancellationError()
    }
    recording = opened.value
    pauseMedia()
  }
  var elapsed: TimeInterval { recording?.elapsed ?? 0 }
  var level: Float { Self.displayLevel(decibels: recording?.decibels ?? -160) }
  nonisolated static func displayLevel(decibels: Float) -> Float { min(1, max(0, (decibels + 50) / 50)) }
  func pause() { recording?.pause(); resumeMedia() }
  func resume() async throws {
    guard let recording else { throw TranscriptionError.integrity }
    let epoch = epoch, ticket = epoch.withLock { $0 }, queued = QueuedAudio(value: recording)
    try await DictationAudioSession.activate(.playAndRecord) {
      try epoch.withLock { current in
        guard current == ticket else { throw CancellationError() }
        try queued.value.record()
      }
    }
    // stop() after the engine restarted already stopped it.
    guard epoch.withLock({ $0 }) == ticket else { throw CancellationError() }
    pauseMedia()
  }
  func stop() {
    epoch.withLock { $0 += 1 }
    recording?.stop(); recording = nil; resumeMedia()
  }
  private func pauseMedia() {
    guard !pausedMedia, UserDefaults.standard.object(forKey: MacMicrophone.pausesMediaKey) as? Bool ?? true else { return }
    pausedMedia = true
    MacMediaPause.pause()
  }
  private func resumeMedia() {
    guard pausedMedia else { return }
    pausedMedia = false
    MacMediaPause.resume()
  }
}

/// 48 kHz mono Float32 CAF, the format AVAudioRecorder wrote and the preview and transcription read. Each
/// record() opens a new engine on the current choice of input and appends to the same open file; pause() stops it.
final class MacMicrophoneRecording: @unchecked Sendable {
  private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
    interleaved: false)!
  private let lock = NSLock()
  private var file: AVAudioFile?
  private var engine: AVAudioEngine?
  private var converter: AVAudioConverter?
  private var observer: NSObjectProtocol?
  private var frames: AVAudioFramePosition = 0
  private var level: Float = -160

  init(file url: URL) throws {
    file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
  }

  var elapsed: TimeInterval { lock.withLock { Double(frames) / Self.format.sampleRate } }
  var decibels: Float { lock.withLock { level } }

  /// Opening the device blocks; it runs on the dictation audio queue.
  func record() throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let chosen = MacMicrophone.recordingInput()
    if let chosen, let unit = input.audioUnit {
      var device = chosen.device
      let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &device, UInt32(MemoryLayout<AudioDeviceID>.size))
      if status != noErr { MacMicrophone.log.error("phase=input-unavailable status=\(status, privacy: .public)") }
    }
    MacMicrophone.log.notice("phase=input device=\(chosen?.name ?? "padrão do sistema", privacy: .public)")
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw TranscriptionError.integrity }
    lock.withLock { level = -160 }
    input.installTap(onBus: 0, bufferSize: 4_800, format: nil) { [weak self] buffer, _ in self?.write(buffer) }
    do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    // A device lost or reconfigured stops the engine: pause into a draft, as the default device changes do.
    let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
      queue: .main) { [weak self] _ in
        guard let self, !lock.withLock({ self.engine?.isRunning ?? true }) else { return }
        NotificationCenter.default.post(name: .macAudioDeviceChanged, object: nil)
      }
    lock.withLock { self.engine = engine; self.observer = observer }
  }

  func pause() {
    let (engine, observer) = lock.withLock {
      defer { self.engine = nil; self.observer = nil }
      return (self.engine, self.observer)
    }
    observer.map(NotificationCenter.default.removeObserver)
    // Outside the lock: the tap writes under it until the engine stops.
    engine?.stop()
    engine?.inputNode.removeTap(onBus: 0)
  }

  func stop() {
    pause()
    lock.withLock { file?.close(); file = nil; converter = nil }
  }

  private func write(_ buffer: AVAudioPCMBuffer) {
    lock.withLock {
      guard let file else { return }
      if converter?.inputFormat != buffer.format {
        converter = AVAudioConverter(from: buffer.format, to: Self.format)
        converter?.downmix = true
      }
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.format.sampleRate / buffer.format.sampleRate) + 64
      guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
      let source = OneBuffer(buffer)
      let status = converter.convert(to: converted, error: nil) { _, input in source.next(input) }
      guard status != .error, converted.frameLength > 0, let samples = converted.floatChannelData?[0],
        (try? file.write(from: converted)) != nil else { return }
      frames += AVAudioFramePosition(converted.frameLength)
      let count = Int(converted.frameLength)
      let power = (0..<count).reduce(Float(0)) { $0 + samples[$1] * samples[$1] } / Float(count)
      level = power > 0 ? 10 * log10(power) : -160
    }
  }
}

/// Hands one tap buffer to the converter, then reports no more data until the next tap.
private final class OneBuffer: @unchecked Sendable {
  private var buffer: AVAudioPCMBuffer?
  init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
  func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    defer { buffer = nil }
    status.pointee = buffer == nil ? .noDataNow : .haveData
    return buffer
  }
}

/// Pauses the media playing when dictation starts and resumes only what it paused, like VoiceInk's "Pause media".
/// Since macOS 15.4 MediaRemote answers only Apple-signed processes, so `osascript` (JavaScript for Automation)
/// loads it: `MRNowPlayingRequest` reads the state and `MRNowPlayingController` sends explicit pause/play
/// commands, never a toggle. No Apple Events or permission are involved.
enum MacMediaPause {
  private static let queue = DispatchQueue(label: "br.com.alexandrem.opencode.media-pause", qos: .userInitiated)
  /// The player this app paused; only touched on the queue.
  nonisolated(unsafe) private static var paused: String?

  static func pause() {
    queue.async {
      guard paused == nil else { return }
      let player = run("pause")
      paused = player.isEmpty ? nil : player
      if let paused { MacMicrophone.log.notice("phase=media-paused player=\(paused, privacy: .public)") }
    }
  }

  /// Plays again only the player paused here, if it is still the one in front and still paused.
  static func resume() {
    queue.async {
      guard let player = paused else { return }
      paused = nil
      MacMicrophone.log.notice("phase=media-resume player=\(player, privacy: .public) result=\(run("resume", player), privacy: .public)")
    }
  }

  /// Quit waits for a pending resume.
  static func flush() { queue.sync {} }

  private static func run(_ arguments: String...) -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", script] + arguments + [Bundle.main.bundleIdentifier ?? ""]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let timeout = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `pause <own bundle>` prints the player it paused, or nothing; `resume <player> <own bundle>` plays it only when
  /// it is still the now-playing player and paused. This app's own read-aloud is left to the app itself.
  private static let script = """
    function run(argv) {
      ObjC.import('Foundation')
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load
      const request = $.NSClassFromString('MRNowPlayingRequest')
      const player = () => {
        const client = request.localNowPlayingPlayerPath.client
        if (client.isNil()) return ''
        return ObjC.unwrap(client.parentApplicationBundleIdentifier) || ObjC.unwrap(client.bundleIdentifier) || ''
      }
      const send = (command) => $.NSClassFromString('MRNowPlayingController').localRouteController
        .sendCommandOptionsCompletion(command, $.NSDictionary.dictionary, null)
      const settle = (playing) => {
        for (let i = 0; i < 20 && request.localIsPlaying !== playing; i++)
          $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05))
      }
      const own = argv[argv.length - 1]
      if (argv[0] === 'pause') {
        const app = player()
        if (!request.localIsPlaying || app === '' || app === own) return ''
        send(1)
        settle(false)
        return app
      }
      if (request.localIsPlaying) return 'already-playing'
      if (player() !== argv[1]) return 'other-player'
      send(0)
      settle(true)
      return 'played'
    }
    """
}
