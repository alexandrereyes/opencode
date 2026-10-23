import Observation
import OpenCodeKit
import SwiftUI

@MainActor @Observable final class FloatingVoicePresentation {
  var expanded = false
  private var callID: UUID?
  var presentations: [UUID] = []
  #if DEBUG
  var fixture: VoiceBarState? = VoiceBarFixtures.launchState
  private var fixtureEnded = false
  #endif

  func visible(_ voice: VoiceController?) -> Bool {
    #if DEBUG
    if fixture != nil { return !fixtureEnded }
    #endif
    return voice?.state.visible == true
  }
  func observe(_ id: UUID?) {
    guard callID != id else { return }
    callID = id
    expanded = false
  }
  func snapshot(_ voice: VoiceController?, now: Date) -> VoiceBarState {
    #if DEBUG
    if var fixture { fixture.expanded = expanded; return fixture }
    #endif
    guard let voice else { return .init(phase: .connecting) }
    return VoiceBarState(voice: voice.state, elapsed: voice.connectedAt.map { now.timeIntervalSince($0) } ?? 0,
      transcript: voice.currentSpokenLine, masterProgress: voice.masterProgressLine,
      expanded: expanded, busy: voice.busy)
  }
  func toggle(_ voice: VoiceController?, sessions: SessionStore) {
    #if DEBUG
    if fixture != nil { fixtureEnded.toggle(); expanded = false; return }
    #endif
    voice?.toggle(sessions: sessions)
  }
  func mute(_ voice: VoiceController?) {
    #if DEBUG
    if fixture != nil { fixture?.muted.toggle(); return }
    #endif
    voice?.mute()
  }
  func end(_ voice: VoiceController?) {
    #if DEBUG
    if fixture != nil { fixtureEnded = true; expanded = false; return }
    #endif
    Task { await voice?.end() }
  }
  func retry(_ voice: VoiceController?, sessions: SessionStore) {
    #if DEBUG
    if fixture != nil { fixture?.phase = .listening; fixture?.error = nil; return }
    #endif
    Task { await voice?.retry(sessions: sessions) }
  }
  func resume(_ voice: VoiceController?) {
    #if DEBUG
    if fixture != nil { fixture?.phase = .listening; return }
    #endif
    voice?.resume()
  }
}

private struct FloatingVoiceKey: EnvironmentKey {
  static let defaultValue: FloatingVoicePresentation? = nil
}
extension EnvironmentValues {
  @Entry var voicePresentationID: UUID? = nil
  var floatingVoice: FloatingVoicePresentation? {
    get { self[FloatingVoiceKey.self] }
    set { self[FloatingVoiceKey.self] = newValue }
  }
}

struct FloatingVoiceHost: View {
  @Environment(\.voiceController) private var voice
  @Environment(\.voiceSessionStore) private var contextSessions
  @Environment(\.floatingVoice) private var presentation
  @Environment(\.voicePresentationID) private var presentationID
  var sessions: SessionStore? = nil
  @State private var transcript = false
  var body: some View {
    Group {
      if let presentation, let sessions = sessions ?? contextSessions, presentation.visible(voice),
        presentation.presentations.last == presentationID {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          FloatingVoiceBar(state: presentation.snapshot(voice, now: context.date),
            mute: { presentation.mute(voice) }, end: { presentation.end(voice) },
            retry: { presentation.retry(voice, sessions: sessions) }, resume: { presentation.resume(voice) },
            expand: { presentation.expanded = $0 }, transcript: { transcript = true })
        }
      }
    }.sheet(isPresented: $transcript) {
      if let sessions = sessions ?? contextSessions { VoiceTranscriptView(memory: sessions.voiceMemory) }
    }
  }
}

private struct FloatingVoiceInset: ViewModifier {
  @Environment(\.voiceController) private var voice
  @Environment(\.floatingVoice) private var presentation
  @Environment(\.voicePresentationID) private var presentationID
  let sessions: SessionStore?
  let enabled: Bool
  func body(content: Content) -> some View {
    content.safeAreaInset(edge: .bottom, spacing: 0) {
      if enabled && presentation?.visible(voice) == true && presentation?.presentations.last == presentationID {
        FloatingVoiceHost(sessions: sessions).padding(.horizontal, 21).padding(.vertical, 8)
      }
    }
  }
}

struct FloatingVoiceScope: ViewModifier {
  @Environment(\.floatingVoice) private var presentation
  @State private var id = UUID()
  var enabled = true
  func body(content: Content) -> some View {
    if enabled {
      content.environment(\.voicePresentationID, id)
        .onAppear {
          guard presentation?.presentations.contains(id) == false else { return }
          presentation?.presentations.append(id)
        }
        .onDisappear { presentation?.presentations.removeAll { $0 == id } }
    } else { content }
  }
}
extension View {
  func floatingVoiceInset(sessions: SessionStore? = nil, enabled: Bool = true) -> some View {
    modifier(FloatingVoiceInset(sessions: sessions, enabled: enabled))
  }
}
