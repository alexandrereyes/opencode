import AVFoundation
import OpenCodeKit

enum VoiceRecordingSnapshot {
  struct Preview: Sendable { let duration: TimeInterval; let waveform: [Float] }
  // AVAudioRecorder leaves data=-1 in an open CAF; finalize only the preview copy.
  static func copy(pcm: URL, to target: URL) throws {
    try FileManager.default.copyItem(at: pcm, to: target)
    do {
      let file = try FileHandle(forUpdating: target)
      defer { try? file.close() }
      let length = try file.seekToEnd()
      try file.seek(toOffset: 0)
      guard try file.read(upToCount: 8)?.prefix(4) == Data("caff".utf8) else { throw TranscriptionError.integrity }
      var offset: UInt64 = 8
      while offset + 12 <= length {
        try file.seek(toOffset: offset)
        guard let header = try file.read(upToCount: 12), header.count == 12 else { throw TranscriptionError.integrity }
        let size = header.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        if header.prefix(4) == Data("data".utf8) {
          let available = length - offset - 12
          guard available >= 4 else { throw TranscriptionError.integrity }
          if size == UInt64.max {
            let complete = 4 + (available - 4) / 4 * 4
            var bigEndian = complete.bigEndian
            try file.seek(toOffset: offset + 4)
            try withUnsafeBytes(of: &bigEndian) { try file.write(contentsOf: $0) }
            try file.truncate(atOffset: offset + 12 + complete)
          } else if size < 4 || size > available { throw TranscriptionError.integrity }
          return
        }
        guard size <= length - offset - 12 else { throw TranscriptionError.integrity }
        offset += 12 + size
      }
      throw TranscriptionError.integrity
    } catch { try? FileManager.default.removeItem(at: target); throw error }
  }
  static func inspect(_ file: URL) throws -> Preview {
    let source = try AVAudioFile(forReading: file)
    guard source.processingFormat.sampleRate == 48_000, source.processingFormat.channelCount == 1,
      let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096) else { throw TranscriptionError.integrity }
    var energy = [Double](repeating: 0, count: 64)
    var counts = [Int](repeating: 0, count: 64)
    var position: Int64 = 0
    while source.framePosition < source.length {
      try Task.checkCancellation()
      try source.read(into: buffer)
      guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { throw TranscriptionError.integrity }
      for sample in UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)) {
        let bin = min(63, Int(position * 64 / max(1, source.length)))
        let value = sample.isFinite ? Double(min(1, max(-1, sample))) : 0
        energy[bin] += value * value; counts[bin] += 1; position += 1
      }
    }
    let rms = zip(energy, counts).map { $1 > 0 ? sqrt($0 / Double($1)) : 0 }
    let maximum = rms.max() ?? 0
    return Preview(duration: Double(source.length) / 48_000,
      waveform: rms.map { maximum > 0 ? Float($0 / maximum) : 0 })
  }
}
