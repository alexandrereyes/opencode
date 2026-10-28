import AppKit
import CoreAudio
import Observation
import OpenCodeKit
import SwiftUI

final class MacVoiceAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task { @MainActor in
      await MacRuntime.shared.audio.stop()
      for window in MacRuntime.shared.windows.values { await window.drafts.flush() }
      ReadAloudPlayer.stopCurrent()
      MacAudioDevices.shared.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

/// One call for the app. MacRuntime owns the event stream, including with every window closed.
@MainActor @Observable final class MacVoiceSession {
  let voice = VoiceController()
  func stop() async { await voice.end() }
}

struct MacVoiceWindow: ViewModifier {
  let runtime: MacWindowRuntime
  func body(content: Content) -> some View {
    content
      .environment(\.macWindowRuntime, runtime)
      .environment(\.floatingVoice, runtime.voicePresentation)
      .onChange(of: runtime.app.audio.voice.sessionID, initial: true) { _, id in runtime.voicePresentation.observe(id) }
      .modifier(MacMicrophonePermission(denied: Binding(
        get: { runtime.app.front === runtime && runtime.app.audio.voice.permissionDenied },
        set: { if !$0 { runtime.app.audio.voice.permissionDenied = false } })))
      .toastOverlay(runtime.app.audio.voice.toast)
  }
}

extension EnvironmentValues {
  @Entry var macWindowRuntime: MacWindowRuntime? = nil
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
        if runtime.audio.voice.state.visible { Text("Vale a partir da próxima chamada").font(.caption) }
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
        if let store = runtime.store { VoiceTranscriptView(memory: store.voiceMemory).macCancelable() }
      }
  }
}
