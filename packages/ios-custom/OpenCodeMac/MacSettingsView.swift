import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// The Mac's Ajustes (⌘,): the iPhone's Você in tabs. Servidores (saved servers, add, edit, remove, pair and switch),
/// Aparência (the shared theme list), Leitura, Modelos (the shared "Gerenciar modelos"), Assinaturas (the LLM proxy
/// summary), Voz, Transcrição and Sobre. Dados do iPhone and Apple Watch stay on the iPhone.
struct MacSettingsView: View {
  let runtime: MacRuntime
  /// The tab shown last; the window reopens on it.
  @AppStorage("OpenCodeMacSettingsTab") private var tab = "servidores"
  var body: some View {
    TabView(selection: $tab) {
      MacServerSettings(runtime: runtime)
        .tabItem { Label("Servidores", systemImage: "server.rack") }.tag("servidores")
      MacAppearanceSettings(appearance: runtime.appearance)
        .tabItem { Label("Aparência", systemImage: "paintpalette") }.tag("aparencia")
      MacReadingSettings()
        .tabItem { Label("Leitura", systemImage: "text.alignleft") }.tag("leitura")
      MacVoiceSettings(runtime: runtime)
        .tabItem { Label("Voz", systemImage: "waveform") }.tag("voz")
      NavigationStack { TranscriptionSettingsView(transcription: .shared) }
        .tabItem { Label("Transcrição", systemImage: "mic") }.tag("transcricao")
      MacModelSettings(runtime: runtime)
        .tabItem { Label("Modelos", systemImage: "cpu") }.tag("modelos")
      MacSubscriptionSettings(runtime: runtime)
        .tabItem { Label("Assinaturas", systemImage: "gauge.with.dots.needle.67percent") }.tag("assinaturas")
      MacAboutSettings(runtime: runtime)
        .tabItem { Label("Sobre", systemImage: "info.circle") }.tag("sobre")
    }
    .frame(width: 600, height: 540)
  }
}

// MARK: - Servers

private struct MacServerSettings: View {
  @Environment(\.appTheme) private var theme
  let runtime: MacRuntime
  @State private var editing: MacServerEditor.Route?
  @State private var pairing = false
  @State private var removing: SavedServer?
  @State private var error: String?

  private var servers: ServerStore { runtime.servers }

  var body: some View {
    Form {
      Section("Servidor ativo") {
        VStack(alignment: .leading, spacing: 4) {
          Text(servers.active.title).font(.headline)
          Text(servers.active.url.absoluteString).font(.caption).foregroundStyle(theme.color(.textSecondary))
            .textSelection(.enabled)
          if let store = runtime.store {
            Label(store.connected ? "Conectado" : (store.error == nil ? "Conectando…" : "Desconectado"),
              systemImage: store.connected ? "checkmark.circle.fill" : "network.slash")
              .font(.caption).foregroundStyle(theme.color(store.connected ? .success : .textSecondary))
            if let version = store.serverVersion {
              Text("Versão \(version)").font(.caption).foregroundStyle(theme.color(.textSecondary))
            }
          }
        }
        if servers.launchOverride != nil {
          Text("Esta execução usa o servidor passado na linha de comando; as alterações valem para as próximas.")
            .font(.caption).foregroundStyle(theme.color(.warning))
        }
      }
      Section("Servidores salvos") {
        ForEach(servers.servers) { server in
          HStack(spacing: 10) {
            Image(systemName: server.id == servers.activeID ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(theme.color(server.id == servers.activeID ? .primary : .icon))
            VStack(alignment: .leading, spacing: 2) {
              Text(server.title)
              Text(server.url.absoluteString).font(.caption).foregroundStyle(theme.color(.textSecondary))
              if server.builtIn { Text("Padrão · não pode ser removido").font(.caption2).foregroundStyle(theme.color(.textWeak)) }
            }
            Spacer()
            if server.id != servers.activeID {
              Button("Usar") { select(server) }
            }
            Button("Editar…") { editing = .init(server: server) }
            if !server.builtIn {
              Button("Remover…", role: .destructive) { removing = server }
            }
          }
          .contextMenu {
            Button("Usar este servidor") { select(server) }.disabled(server.id == servers.activeID)
            Button("Editar…") { editing = .init(server: server) }
            if !server.builtIn { Button("Remover…", role: .destructive) { removing = server } }
          }
        }
      }
      Section {
        HStack {
          Button("Adicionar servidor…", systemImage: "plus") { editing = .init(server: nil) }
          Button("Parear com código…", systemImage: "link") { pairing = true }
        }
      } footer: {
        Text("Senhas e tokens ficam nas Chaves deste Mac. Trocar de servidor recarrega a janela; o servidor padrão é o deste Mac.")
          .foregroundStyle(theme.color(.textSecondary))
      }
    }
    .formStyle(.grouped)
    .sheet(item: $editing) { route in MacServerEditor(servers: servers, server: route.server) }
    .sheet(isPresented: $pairing) { MacPairingSheet(servers: servers) }
    .confirmationDialog("Remover \(removing?.title ?? "servidor")?", isPresented: Binding(
      get: { removing != nil }, set: { if !$0 { removing = nil } })
    ) {
      Button("Remover servidor", role: .destructive) {
        if let removing { attempt { try servers.remove(removing.id) } }
        removing = nil
      }
      Button("Cancelar", role: .cancel) { removing = nil }
    } message: { Text("A credencial será apagada deste Mac. As sessões no servidor não serão removidas.") }
    .alert("Não foi possível alterar o servidor", isPresented: Binding(
      get: { error != nil }, set: { if !$0 { error = nil } })
    ) { Button("OK") { error = nil } } message: { Text(error ?? "") }
  }

  private func select(_ server: SavedServer) { attempt { try servers.select(server.id) } }

  private func attempt(_ action: () throws -> Void) {
    do { try action() } catch { self.error = error.localizedDescription }
  }
}

/// Add or edit a server: name, address and password, with the iPhone's "Testar conexão" (`/api/info` only).
private struct MacServerEditor: View {
  struct Route: Identifiable {
    let id = UUID()
    let server: SavedServer?
  }
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let servers: ServerStore
  let server: SavedServer?
  @State private var name = ""
  @State private var address = ""
  @State private var password = ""
  @State private var tested: (text: String, ok: Bool)?
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(server == nil ? "Adicionar servidor" : "Editar servidor").font(.title3.bold())
      Form {
        TextField("Nome", text: $name, prompt: Text("Opcional"))
        TextField("Endereço", text: $address, prompt: Text("http://servidor:4096"))
          .pathInput().disabled(server?.builtIn == true)
        SecureField("Senha", text: $password, prompt: Text("Opcional"))
      }
      .formStyle(.grouped)
      HStack {
        Button(busy ? "Testando…" : "Testar conexão") { Task { await test() } }
          .disabled(busy || ServerAddress.parse(address) == nil)
        if let tested {
          Label(tested.text, systemImage: tested.ok ? "checkmark.circle.fill" : "exclamationmark.triangle")
            .font(.caption).foregroundStyle(theme.color(tested.ok ? .success : .error)).lineLimit(2)
        }
      }
      Text("O teste consulta apenas /api/info. Nenhuma sessão é criada ou executada.")
        .font(.caption).foregroundStyle(theme.color(.textSecondary))
      if let error { Text(error).font(.caption).foregroundStyle(theme.color(.error)) }
      HStack {
        Spacer()
        Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Salvar") { save() }.keyboardShortcut(.defaultAction).disabled(busy || tested == nil)
      }
    }
    .padding(20).frame(width: 480)
    .onAppear {
      name = server?.name ?? ""
      address = server?.url.absoluteString ?? ""
      password = (try? server.flatMap { try servers.password($0) }) ?? ""
    }
    .onChange(of: address) { tested = nil }
    .onChange(of: password) { tested = nil }
  }

  private func test() async {
    guard let url = ServerAddress.parse(address) else { return }
    busy = true
    defer { busy = false }
    do {
      try servers.validate(url)
      let info = try await PairingClient().test(.init(url: url, password: password.isEmpty ? nil : password))
      tested = ("Conectado · versão \(info.version ?? "")", true)
    } catch {
      tested = ("Falha na conexão. \(error.localizedDescription)", false)
    }
  }

  private func save() {
    do {
      let secret = password.isEmpty ? nil : password
      if let server { try servers.edit(server.id, name: name, address: address, password: secret) }
      else { try servers.add(name: name, address: address, password: secret) }
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

/// `opencode pair`: the link or the QR code's JSON pasted here, redeemed like the iPhone does (every address in
/// parallel, the first one preferred), then saved under a name. The Mac has no camera scanner.
private struct MacPairingSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let servers: ServerStore
  @State private var payload = ""
  @State private var name = ""
  @State private var busy = false
  @State private var result: ServerConfiguration?
  @State private var version: String?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Parear com código").font(.title3.bold())
      Text("Cole o link ou o JSON do QR code gerado por `opencode pair`. O código é de uso único.")
        .font(.callout).foregroundStyle(theme.color(.textSecondary))
      TextEditor(text: $payload).font(.system(size: 12, design: .monospaced)).frame(height: 90)
        .scrollContentBackground(.hidden).padding(6)
        .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border)) }
        .disabled(busy || result != nil)
      if let result {
        Label(version.map { "Conectado · versão \($0)" } ?? "Pareado · conexão indisponível",
          systemImage: "checkmark.circle.fill").foregroundStyle(theme.color(.success))
        Text(result.url.absoluteString).font(.caption).foregroundStyle(theme.color(.textSecondary))
        TextField("Nome (opcional)", text: $name).textFieldStyle(.roundedBorder)
      }
      if let error { Text(error).font(.caption).foregroundStyle(theme.color(.error)) }
      HStack {
        Spacer()
        Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        if let result {
          Button("Salvar servidor") { save(result) }.keyboardShortcut(.defaultAction)
        } else {
          Button(busy ? "Resgatando…" : "Resgatar código") { Task { await redeem() } }
            .keyboardShortcut(.defaultAction)
            .disabled(payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        }
      }
    }
    .padding(20).frame(width: 480)
  }

  private func redeem() async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      let link = try PairingLink(payload)
      try link.urls.forEach { try servers.validate($0) }
      let configuration = try await PairingClient().redeem(link)
      result = configuration
      version = try? await PairingClient().test(configuration).version
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func save(_ result: ServerConfiguration) {
    do {
      try servers.add(name: name, address: result.url.absoluteString, password: result.password)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

// MARK: - Appearance and reading

private struct MacAppearanceSettings: View {
  @Environment(\.appTheme) private var theme
  @Bindable var appearance: AppearanceSettings
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Aparência", selection: $appearance.appearance) {
        ForEach(ThemeAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      if appearance.override != nil {
        Text("O tema desta execução foi definido na inicialização.").font(.caption)
          .foregroundStyle(theme.color(.textSecondary))
      }
      ThemePicker(settings: appearance)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .padding(16)
  }
}

private struct MacReadingSettings: View {
  @AppStorage("OpenCodeCollapsibleUserMessages") private var collapsibleUserMessages = true
  var body: some View {
    Form {
      Section {
        Toggle("Recolher mensagens longas do usuário", isOn: $collapsibleUserMessages)
      } footer: {
        Text("Mensagens com mais de duas linhas mostram “Mostrar mensagem completa”, como no iPhone.")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Models

private struct MacModelSettings: View {
  let runtime: MacRuntime
  @State private var catalog: MacModelCatalog?
  var body: some View {
    Group {
      if let catalog {
        ModelVisibilityView(store: catalog)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: runtime.identity) {
      guard let store = runtime.store else { return }
      let next = MacModelCatalog(sessions: store)
      catalog = next
      await next.load()
    }
  }
}

/// The server's whole catalog for "Gerenciar modelos": its models and providers at the default Location and the
/// `model.visibility` preferences shared with the web and the iPhone.
@MainActor @Observable final class MacModelCatalog: ModelVisibilitySource {
  let sessions: SessionStore
  let toast = ToastCenter()
  private(set) var models: [ModelInfo] = []
  private(set) var providers: [ProviderInfo] = []
  private(set) var preferences: Preferences?
  private(set) var acting: Set<String> = []

  init(sessions: SessionStore) { self.sessions = sessions }

  func load() async {
    let client = sessions.client
    do {
      let directory = try await client.defaultDirectory()
      async let models = client.models(directory: directory)
      async let providers = client.providers(directory: directory)
      async let preferences = client.preferences()
      (self.models, self.providers, self.preferences) = try await (models, providers, preferences)
    } catch {
      toast.show("Não foi possível carregar os modelos. \(error.localizedDescription)", kind: .error)
    }
  }

  func providerName(_ id: String) -> String { providers.first { $0.id == id }?.name ?? id }

  func updateModels(_ intents: [PreferenceIntent], success: String) async {
    guard acting.insert("models").inserted else { return }
    defer { acting.remove("models") }
    do {
      for intent in intents {
        let updated = try await sessions.client.mutate(intent)
        if updated.revision >= (preferences?.revision ?? -1) { preferences = updated }
      }
      toast.show(success)
      await sessions.reload()
    } catch {
      toast.show("Não foi possível atualizar os modelos. \(error.localizedDescription)", kind: .error)
    }
  }
}

// MARK: - Subscriptions and about

private struct MacSubscriptionSettings: View {
  @Environment(\.appTheme) private var theme
  let runtime: MacRuntime
  var body: some View {
    Form {
      if let store = runtime.store {
        Section {
          ForEach(store.quota.providers) { provider in
            Button {
              // Over the front main window, which comes forward with it.
              guard let front = runtime.front ?? runtime.windows.values.first else { return }
              front.window?.makeKeyAndOrderFront(nil)
              front.showProxy(.provider(provider))
            } label: {
              SubscriptionCompactRow(store: store.quota, provider: provider)
            }
            .buttonStyle(.plain)
          }
          if store.quota.providers.isEmpty {
            Text("O LLM proxy deste servidor não informou assinaturas.").foregroundStyle(theme.color(.textSecondary))
          }
        } header: {
          Text("LLM proxy")
        } footer: {
          HStack {
            Text("Contas, limites, renovações e redefinições no LLM proxy (⇧⌘L).")
            Spacer()
            Button("Atualizar") { Task { await store.quota.refresh() } }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { await runtime.store?.quota.refresh(ifDue: true) }
  }
}

private struct MacAboutSettings: View {
  let runtime: MacRuntime
  var body: some View {
    Form {
      Section("OpenCode para Mac") {
        LabeledContent("Versão e build", value: version)
        LabeledContent("Commit", value: commit)
        LabeledContent("Versão do servidor", value: runtime.store?.serverVersion ?? "Indisponível")
        LabeledContent("Servidor", value: runtime.servers.active.url.absoluteString)
      }
      Section {
        Link("README no GitHub",
          destination: URL(string: "https://github.com/alexandrereyes/opencode/tree/custom/packages/ios-custom")!)
      }
    }
    .formStyle(.grouped)
  }

  private var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
  }

  private var commit: String {
    let value = Bundle.main.object(forInfoDictionaryKey: "OpenCodeCommit") as? String ?? ""
    return value.isEmpty ? "desenvolvimento" : value
  }
}
