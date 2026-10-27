import OpenCodeKit
import SwiftUI

/// The Mac's Settings scene: the server (address and password in the Keychain, with a connection test) and the
/// iPhone's themes. Nothing else in this first version.
struct MacSettingsView: View {
  let runtime: MacRuntime
  var body: some View {
    TabView {
      MacServerSettings(servers: runtime.servers)
        .tabItem { Label("Servidor", systemImage: "server.rack") }
      MacThemeSettings(appearance: runtime.appearance)
        .tabItem { Label("Tema", systemImage: "paintpalette") }
    }
    .frame(width: 520)
  }
}

private struct MacServerSettings: View {
  @Environment(\.appTheme) private var theme
  let servers: ServerStore
  @State private var address = ""
  @State private var password = ""
  @State private var status: (text: String, ok: Bool)?
  @State private var testing = false

  var body: some View {
    Form {
      Section {
        TextField("Endereço", text: $address, prompt: Text(MacRuntime.localURL.absoluteString))
        SecureField("Senha", text: $password, prompt: Text("opencode service get password"))
      } footer: {
        Text("O padrão é o servidor deste Mac. A senha fica nas Chaves do macOS.")
          .foregroundStyle(theme.color(.textSecondary))
      }
      if servers.launchOverride != nil {
        Text("Esta execução usa o servidor passado na linha de comando; as alterações valem para as próximas.")
          .font(.caption).foregroundStyle(theme.color(.warning))
      }
      HStack {
        if let status {
          Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .foregroundStyle(theme.color(status.ok ? .success : .error)).font(.callout)
        }
        Spacer()
        Button(testing ? "Testando…" : "Testar conexão") { Task { await test() } }.disabled(testing)
        Button("Salvar") { save() }.keyboardShortcut(.defaultAction)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      address = servers.active.url.absoluteString
      password = (try? servers.password(servers.active)) ?? ""
    }
  }

  private var configuration: ServerConfiguration? {
    ServerAddress.parse(address).map { ServerConfiguration(url: $0, password: password.isEmpty ? nil : password) }
  }

  private func test() async {
    guard let configuration else {
      status = ("Endereço inválido.", false)
      return
    }
    testing = true
    defer { testing = false }
    do {
      let info = try await OpenCodeClient(configuration: configuration).info()
      status = ("Conectado · OpenCode \(info.version ?? "")", true)
    } catch {
      status = (error.localizedDescription, false)
    }
  }

  /// The local server is the built-in entry (only its password changes); another address is saved as
  /// "Personalizado" and becomes the active server.
  private func save() {
    guard let url = ServerAddress.parse(address) else {
      status = ("Endereço inválido.", false)
      return
    }
    do {
      let secret = password.isEmpty ? nil : password
      let builtin = servers.servers[0]
      if url == builtin.url {
        try servers.edit(builtin.id, name: builtin.name, address: url.absoluteString, password: secret)
        try servers.select(builtin.id)
      } else if let custom = servers.servers.first(where: { !$0.builtIn }) {
        try servers.edit(custom.id, name: "Personalizado", address: url.absoluteString, password: secret)
        try servers.select(custom.id)
      } else {
        let custom = try servers.add(name: "Personalizado", address: url.absoluteString, password: secret)
        try servers.select(custom.id)
      }
      status = ("Salvo.", true)
    } catch {
      status = (error.localizedDescription, false)
    }
  }
}

private struct MacThemeSettings: View {
  @Bindable var appearance: AppearanceSettings
  var body: some View {
    Form {
      Picker("Tema", selection: $appearance.family) {
        ForEach(AppTheme.families) { Text($0.name).tag($0.id) }
      }
      Picker("Aparência", selection: $appearance.appearance) {
        ForEach(ThemeAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
    }
    .formStyle(.grouped)
  }
}
