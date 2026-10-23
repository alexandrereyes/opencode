import AVFoundation
import CoreML
@preconcurrency import FluidAudio
import Foundation
import OpenCodeKit

protocol TranscriptionEngine: Sendable {
  func load(from directory: URL) async throws
  func transcribe(_ samples: [Float]) async throws -> String
  func unload() async
}

actor ParakeetUltraEngine: TranscriptionEngine {
  private var manager: AsrManager?
  func load(from directory: URL) async throws {
    guard manager == nil else { return }
    let configuration = AsrModels.defaultConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    // loadLocal cannot download. Same no-VAD, automatic-language setup as Abacato.
    let models = try AsrModels.loadLocal(from: directory, version: .ultra, configuration: configuration)
    let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
    try await manager.loadModels(models)
    self.manager = manager
  }
  func transcribe(_ samples: [Float]) async throws -> String {
    guard let manager else { throw TranscriptionError.notReady }
    var state = try TdtDecoderState()
    return try await manager.transcribe(samples, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func unload() async { await manager?.cleanup(); manager = nil }
}

enum TranscriptionAudio {
  static func samples(_ url: URL) throws -> [Float] {
    let source = try AVAudioFile(forReading: url)
    guard let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
      let converter = AVAudioConverter(from: source.processingFormat, to: target),
      let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096),
      let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { throw TranscriptionError.integrity }
    var result: [Float] = []
    var finished = false
    var decodingFailure: (any Error)?
    while !finished {
      try Task.checkCancellation()
      var failure: NSError?
      let status = converter.convert(to: output, error: &failure) { _, state in
        do {
          guard source.framePosition < source.length else { state.pointee = .endOfStream; return nil }
          try source.read(into: input, frameCount: AVAudioFrameCount(min(Int64(input.frameCapacity), source.length - source.framePosition)))
          if input.frameLength == 0 { state.pointee = .endOfStream; return nil }
          state.pointee = .haveData
          return input
        } catch { decodingFailure = error; state.pointee = .endOfStream; return nil }
      }
      if let decodingFailure { throw decodingFailure }
      if let failure { throw failure }
      guard status != .error else { throw TranscriptionError.integrity }
      if let samples = output.floatChannelData?[0] { result.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(output.frameLength))) }
      finished = status == .endOfStream
    }
    return result
  }
}
