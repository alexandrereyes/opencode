import AVFoundation
import Foundation
import OpenCodeKit

@MainActor protocol VoiceRecordingCapture: AnyObject {
  func authorize() async -> Bool
  func start(at file: URL) throws
  var elapsed: TimeInterval { get }
  var level: Float { get }
  func pause()
  func resume() throws
  func stop()
}

/// Continuous PCM, including pause/resume on the same recorder, as in Abacato.
@MainActor final class MicrophoneVoiceCapture: VoiceRecordingCapture {
  private var recorder: AVAudioRecorder?
  private var ownsSession = false
  func authorize() async -> Bool { await AVAudioApplication.requestRecordPermission() }
  func start(at file: URL) throws {
    do {
      try activate()
      let recorder = try AVAudioRecorder(url: file, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
      ])
      self.recorder = recorder
      recorder.isMeteringEnabled = true
      guard recorder.record() else { throw TranscriptionError.integrity }
    } catch { stop(); throw error }
  }
  private func activate() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
    try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    try session.setActive(true)
    ownsSession = true
  }
  var elapsed: TimeInterval { recorder?.currentTime ?? 0 }
  var level: Float {
    recorder?.updateMeters()
    return Self.displayLevel(decibels: recorder?.averagePower(forChannel: 0) ?? -160)
  }
  nonisolated static func displayLevel(decibels: Float) -> Float { min(1, max(0, (decibels + 50) / 50)) }
  func pause() { recorder?.pause(); releaseSession() }
  func resume() throws {
    guard let recorder else { throw TranscriptionError.integrity }
    try activate()
    guard recorder.record() else { releaseSession(); throw TranscriptionError.integrity }
  }
  func stop() { recorder?.stop(); recorder = nil; releaseSession() }
  private func releaseSession() {
    guard ownsSession else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    ownsSession = false
  }
}
