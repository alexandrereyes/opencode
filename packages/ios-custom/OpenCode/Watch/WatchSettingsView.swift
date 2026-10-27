import OpenCodeKit
import SwiftUI

/// "Você → Apple Watch": pair the watch with this server (`custom.watch` → `pair`, delivered over
/// WatchConnectivity), list the paired watches and remove them.
struct WatchSettingsView: View {
  @Environment(\.appTheme) private var theme
  let client: OpenCodeClient
  let voice: VoicePreferences
  @State private var link = PhoneWatchLink.shared
  @State private var devices: [WatchDevice] = []
  @State private var loading = true
  @State private var pairing = false
  @State private var message: (text: String, error: Bool)?
  @State private var removing: WatchDevice?

  var body: some View {
    List {
      Section {
        Label(watchStatus.text, systemImage: watchStatus.icon)
          .foregroundStyle(theme.color(watchStatus.ok ? .success : .textSecondary))
          .accessibilityIdentifier("watch-status")
        Button {
          Task { await pair() }
        } label: {
          HStack {
            Text("Parear Apple Watch")
            Spacer()
            if pairing { ProgressView() }
          }
        }
        .disabled(pairing)
        .accessibilityIdentifier("watch-pair")
        if let message {
          Text(message.text).appFont(.caption)
            .foregroundStyle(theme.color(message.error ? .error : .success))
            .accessibilityIdentifier("watch-pair-message")
        }
      } footer: {
        Text("O relógio recebe um acesso próprio a este servidor e funciona sem o iPhone por perto, pelo Wi-Fi ou pela rede celular. A voz usa a voz escolhida em Conversa por voz.")
      }.listRowBackground(theme.color(.surface))
      Section("Relógios pareados") {
        if loading {
          ProgressView()
        } else if devices.isEmpty {
          Text("Nenhum relógio pareado").foregroundStyle(theme.color(.textSecondary))
        }
        ForEach(devices) { device in
          VStack(alignment: .leading, spacing: 3) {
            Text(device.name).foregroundStyle(theme.color(.textStrong))
            Text(detail(device)).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
          }
          .swipeActions {
            Button("Remover", role: .destructive) { removing = device }
          }
          .contextMenu {
            Button("Remover", systemImage: "trash", role: .destructive) { removing = device }
          }
          .accessibilityIdentifier("watch-device-" + device.deviceID)
        }
      }.listRowBackground(theme.color(.surface))
    }
    .settingsList(theme).navigationTitle("Apple Watch").navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task {
      link.activate()
      await load()
    }
    .confirmationDialog("Remover \(removing?.name ?? "relógio")?", isPresented: Binding(
      get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible
    ) {
      Button("Remover relógio", role: .destructive) {
        if let device = removing { Task { await remove(device) } }
      }
    } message: {
      Text("O relógio perde o acesso ao servidor até ser pareado de novo.")
    }
  }

  private var watchStatus: (text: String, icon: String, ok: Bool) {
    if !link.activated { return ("Verificando o Apple Watch…", "applewatch", false) }
    if !link.paired { return ("Nenhum Apple Watch pareado com este iPhone", "applewatch.slash", false) }
    if !link.installed { return ("OpenCode não está instalado no relógio", "applewatch", false) }
    return ("Apple Watch pronto para parear", "applewatch.radiowaves.left.and.right", true)
  }

  private func detail(_ device: WatchDevice) -> String {
    let created = "Pareado " + device.created.formatted(.relative(presentation: .named))
    guard let seen = device.lastSeen else { return created }
    return created + " · visto " + seen.formatted(.relative(presentation: .named))
  }

  private func load() async {
    defer { loading = false }
    do {
      devices = try await client.watchDevices()
    } catch {
      message = (describe(error), true)
    }
  }

  private func pair() async {
    pairing = true
    message = nil
    defer { pairing = false }
    do {
      var result = try await client.watchPair(deviceName: "Apple Watch")
      // The iPhone's local voice preference wins over the server default.
      result.voice = .init(voiceID: voice.voice.rawValue)
      try await link.send(result)
      message = ("Enviado ao relógio. Abra o OpenCode no Apple Watch.", false)
      Haptics.play(.success)
      await load()
    } catch {
      message = (describe(error), true)
      Haptics.play(.warning)
    }
  }

  private func remove(_ device: WatchDevice) async {
    removing = nil
    do {
      try await client.watchRevoke(deviceID: device.deviceID)
      link.revoked(deviceID: device.deviceID)
      devices.removeAll { $0.deviceID == device.deviceID }
    } catch {
      message = (describe(error), true)
    }
  }

  private func describe(_ error: any Error) -> String {
    if AgentsSupport.unsupported(error) { return "Este servidor ainda não tem o gateway do Apple Watch." }
    return (error as? LocalizedError)?.errorDescription ?? "Não foi possível falar com o servidor."
  }
}
