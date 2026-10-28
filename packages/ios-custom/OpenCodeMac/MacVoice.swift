import AppKit
import CoreAudio
import Observation
import OpenCodeKit
import SwiftUI

final class MacVoiceAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task { @MainActor in
      await MacRuntime.shared.audio.stop()
      ReadAloudPlayer.stopCurrent()
      MacAudioDevices.shared.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

/// One call and one event-stream owner for all windows. Minimizing/closing the last window does not stop a call.
@MainActor @Observable final class MacVoiceSession {
  let voice = VoiceController()
  let presentation = FloatingVoicePresentation()
  @ObservationIgnored private var activity = VoiceWindowActivity()
  @ObservationIgnored private var sessions: SessionStore?
  @ObservationIgnored private var events: Task<Void, Never>?

  init() {
    voice.stateChanged = { [weak self] in self?.update() }
  }

  func window(_ id: UUID, visible: Bool, sessions: SessionStore) {
    // A disappearing window from the previous server must not replace the new stream owner.
    if visible || self.sessions == nil { self.sessions = sessions }
    activity.window(id, visible: visible)
    update()
  }

  private func update() {
    presentation.observe(voice.sessionID)
    guard activity.requiresEvents(calling: voice.sessionID != nil) else {
      events?.cancel(); events = nil
      return
    }
    guard events == nil, let sessions else { return }
    events = Task { await sessions.run() }
  }

  func stop() async {
    await voice.end()
    events?.cancel()
    await sessions?.stop()
    await events?.value
    events = nil; sessions = nil; activity = VoiceWindowActivity()
  }
}

struct MacVoiceWindow: ViewModifier {
  let audio: MacVoiceSession
  let sessions: SessionStore
  @Environment(\.scenePhase) private var phase
  @State private var id = UUID()
  func body(content: Content) -> some View {
    content
      .onChange(of: phase, initial: true) { _, value in audio.window(id, visible: value != .background, sessions: sessions) }
      .onDisappear { audio.window(id, visible: false, sessions: sessions) }
      .modifier(MacMicrophonePermission(denied: Binding(get: { audio.voice.permissionDenied }, set: { audio.voice.permissionDenied = $0 })))
      .toastOverlay(audio.voice.toast)
  }
}

struct MacMicrophonePermission: ViewModifier {
  @Binding var denied: Bool
  func body(content: Content) -> some View {
    content.alert("Permita o microfone", isPresented: $denied) {
      Button("Abrir Ajustes do Sistema") { MacMicrophonePermission.openSettings() }
      Button("Agora não", role: .cancel) {}
    } message: {
      Text("Autorize o OpenCode em Ajustes do Sistema › Privacidade e Segurança › Microfone para conversar por voz ou ditar.")
    }
  }
  static func openSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
  }
}

/// WebRTC follows these devices itself. Local recording and spoken playback pause on a change, as on iOS.
@MainActor final class MacAudioDevices {
  static let shared = MacAudioDevices()
  private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  func start() {
    guard listeners.isEmpty else { return }
    for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
      var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      let listener: AudioObjectPropertyListenerBlock = { _, _ in
        NotificationCenter.default.post(name: .macAudioDeviceChanged, object: nil)
      }
      if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
        listeners.append((address, listener))
      }
    }
  }
  func stop() {
    for (var address, listener) in listeners {
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
    listeners = []
  }
}

extension Notification.Name {
  static let macAudioDeviceChanged = Notification.Name("OpenCodeMacAudioDeviceChanged")
}

extension View {
  func settingsList(_ theme: AppTheme) -> some View {
    scrollContentBackground(.hidden).background(theme.color(.background)).foregroundStyle(theme.color(.text))
  }
}

/// The same voice catalog and rolling memory as Você, arranged as a native Mac settings form.
struct MacVoiceSettings: View {
  let runtime: MacRuntime
  @State private var transcript = false
  var body: some View {
    Form {
      Section("Conversa por voz · GPT Live") {
        Picker("Voz", selection: Binding(get: { runtime.audio.voice.preferences.voice },
          set: { runtime.audio.voice.preferences.voice = $0 })) {
          Section("Brasileiras") { ForEach(GPTLiveVoice.brazilian) { Text($0.title).tag($0) } }
          Section("Outras vozes") { ForEach(GPTLiveVoice.others) { Text($0.title).tag($0) } }
        }
        if runtime.audio.presentation.visible(runtime.audio.voice) { Text("Vale a partir da próxima chamada").font(.caption) }
        Text("A conversa usa o serviço privado pelo WARP e delega seus pedidos à Sessão mestra.").font(.caption)
        Button("Abrir permissão do microfone") { MacMicrophonePermission.openSettings() }
      }
      Section("Memória da voz") {
        Button("Ver transcrição") { transcript = true }.disabled(runtime.store == nil)
        Text("Resumo e falas recentes, compartilhados com o iPhone pelo mesmo servidor. Não é um arquivo ilimitado.").font(.caption)
      }
      Section("Leitura em voz alta") {
        Text("Usa a voz de leitura do servidor, como no iPhone. A escolha de GPT Live acima vale somente para chamadas.").font(.caption)
      }
    }.formStyle(.grouped)
      .sheet(isPresented: $transcript) {
        if let store = runtime.store { VoiceTranscriptView(memory: store.voiceMemory) }
      }
  }
}
