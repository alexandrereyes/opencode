import Foundation

/// Presentation only: a call's audio and execution lifetimes belong to the voice engine.
public struct VoiceBarState: Equatable, Sendable {
  public enum Phase: String, CaseIterable, Sendable {
    case connecting, listening, speaking, thinking, reconnecting, interrupted, failed
  }

  public var phase: Phase
  public var elapsed: TimeInterval
  public var transcript: String?
  public var masterProgress: String?
  public var muted: Bool
  public var expanded: Bool
  public var error: String?
  public var busy: Bool

  public init(phase: Phase, elapsed: TimeInterval = 0, transcript: String? = nil,
              masterProgress: String? = nil, muted: Bool = false, expanded: Bool = false,
              error: String? = nil, busy: Bool = false) {
    self.phase = phase
    self.elapsed = elapsed
    self.transcript = transcript
    self.masterProgress = masterProgress
    self.muted = muted
    self.expanded = expanded
    self.error = error
    self.busy = busy
  }

  public init(voice: VoiceState, elapsed: TimeInterval, transcript: String? = nil,
              masterProgress: String? = nil, expanded: Bool = false, busy: Bool = false) {
    let phase: Phase = switch voice.phase {
    case .idle, .listening: voice.masterWorking ? .thinking : .listening
    case .connecting: .connecting
    case .speaking: .speaking
    case .reconnecting: .reconnecting
    case .interrupted: .interrupted
    case .failed: .failed
    }
    self.init(phase: phase, elapsed: elapsed, transcript: transcript,
              masterProgress: voice.masterWorking ? masterProgress : nil,
              muted: voice.muted, expanded: expanded, error: voice.error, busy: busy)
  }

  public var label: String {
    if muted && [.listening, .thinking].contains(phase) { return "Microfone desligado" }
    return switch phase {
    case .connecting: "Conectando…"
    case .listening: "Ouvindo"
    case .speaking: "Falando"
    case .thinking: "Pensando"
    case .reconnecting: "Reconectando…"
    case .interrupted: "Áudio pausado"
    case .failed: "Falha na conexão"
    }
  }

  public var animatesWaveform: Bool {
    !muted && [.listening, .speaking].contains(phase)
  }
  public var muteEnabled: Bool { !busy && ![.connecting, .failed, .interrupted].contains(phase) }
  public var seconds: Int {
    elapsed.isFinite ? Int(min(max(0, elapsed.rounded(.down)), Double(Int.max / 2))) : 0
  }
  public var time: String {
    let seconds = seconds
    if seconds >= 3600 {
      return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
  public var spokenTime: String {
    let hours = seconds / 3600
    let minutes = seconds / 60 % 60
    let seconds = seconds % 60
    return [(hours, "hora"), (minutes, "minuto"), (seconds, "segundo")]
      .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
      .joined(separator: " e ").nilIfEmpty ?? "0 segundos"
  }
  public var accessibilityLabel: String { "Conversa por voz, \(label.lowercased()), \(spokenTime)" }
  public var spokenLine: String? { (phase == .failed ? error : transcript)?.nilIfEmpty }
  public var progressLine: String? {
    masterProgress?.nilIfEmpty.map { "Sessão mestra · " + $0 }
  }
}

private extension String {
  var nilIfEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
