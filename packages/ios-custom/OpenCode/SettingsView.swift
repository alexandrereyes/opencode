import OpenCodeKit
import SwiftUI

struct SettingsView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.floatingVoice) private var floatingVoice
  let runtime: AppRuntime
  let store: SessionStore
  @State private var proxyProvider: SubscriptionProvider?
  @AppStorage("OpenCodeCollapsibleUserMessages") private var collapsibleUserMessages = true
  var body: some View {
    @Bindable var appearance = runtime.appearance
    NavigationStack {
      List {
        Section("LLM proxy") {
          ForEach(store.quota.providers) { provider in
            Button { proxyProvider = provider } label: {
              SubscriptionCompactRow(store: store.quota, provider: provider)
            }.buttonStyle(.plain).accessibilityIdentifier("proxy-settings-" + provider.rawValue)
          }
        }.listRowBackground(theme.color(.surface))
        Section("Aparência") {
          NavigationLink {
            ThemePicker(settings: appearance)
          } label: {
            HStack {
              Text("Tema")
              Spacer()
              Text(AppTheme.families.first { $0.dark == theme.id || $0.light == theme.id }?.name ?? "OpenChamber")
                .foregroundStyle(theme.color(.textSecondary))
            }
          }.accessibilityIdentifier("settings-themes")
          Picker("Aparência", selection: $appearance.appearance) {
            ForEach(ThemeAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
          }.pickerStyle(.segmented).accessibilityIdentifier("settings-appearance")
          if appearance.override != nil {
            Text("O tema desta execução foi definido na inicialização.")
              .font(.caption).foregroundStyle(theme.color(.textSecondary))
          }
        }.listRowBackground(theme.color(.surface))
        Section("Leitura") {
          Toggle("Recolher mensagens longas do usuário", isOn: $collapsibleUserMessages)
            .accessibilityIdentifier("settings-collapsible-user-messages")
        }.listRowBackground(theme.color(.surface))
        Section {
          NavigationLink {
            VoicePicker(settings: runtime.voice.preferences)
          } label: {
            LabeledContent("Voz", value: runtime.voice.preferences.voice.title)
          }.accessibilityIdentifier("settings-voice")
        } header: { Text("Conversa por voz") } footer: {
          if floatingVoice?.visible(runtime.voice) == true { Text("Vale a partir da próxima chamada") }
        }.listRowBackground(theme.color(.surface))
        Section("Transcrição") {
          NavigationLink("Transcrição no aparelho") { TranscriptionSettingsView(transcription: .shared) }
            .accessibilityIdentifier("settings-transcription")
        }.listRowBackground(theme.color(.surface))
        Section("Sessão mestra") {
          NavigationLink("Dados do iPhone") { DeviceDataView(agent: .shared) }
            .accessibilityIdentifier("settings-device-data")
        }.listRowBackground(theme.color(.surface))
        Section("Servidor") {
          NavigationLink {
            ServerListView(runtime: runtime, store: store)
          } label: {
            VStack(alignment: .leading, spacing: 5) {
              Text(runtime.servers.active.title)
              Text(runtime.servers.active.url.absoluteString).font(.caption)
                .foregroundStyle(theme.color(.textSecondary))
              connectionState(store, theme: theme)
            }.padding(.vertical, 3)
          }.accessibilityIdentifier("settings-servers")
          if let version = store.serverVersion {
            LabeledContent("Versão do servidor", value: version)
          }
        }.listRowBackground(theme.color(.surface))
        Section("Sobre") {
          NavigationLink("Sobre o OpenCode") { AboutView(store: store) }
            .accessibilityIdentifier("settings-about")
          LabeledContent("Versão do app", value: appVersion)
        }.listRowBackground(theme.color(.surface))
      }
      .settingsList(theme)
      .navigationTitle("Você")
      .refreshable { await store.quota.refresh() }
      .sheet(item: $proxyProvider) { provider in
        SubscriptionDetailSheet(store: store.quota, initialProvider: provider).sessionAlertOverlay()
      }
    }
  }
}

private struct VoicePicker: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.voiceController) private var voice
  @Environment(\.floatingVoice) private var floatingVoice
  @Bindable var settings: VoicePreferences
  var body: some View {
    List {
      Section { voices(GPTLiveVoice.brazilian) } header: { Text("Brasileiras") } footer: {
        if floatingVoice?.visible(voice) == true { Text("Vale a partir da próxima chamada") }
      }
      Section("Outras vozes") { voices(GPTLiveVoice.others) }
    }.settingsList(theme).navigationTitle("Voz").navigationBarTitleDisplayMode(.inline)
  }
  private func voices(_ voices: [GPTLiveVoice]) -> some View {
    ForEach(voices) { voice in
      Button {
        settings.voice = voice
        Haptics.play(.selection)
      } label: {
        HStack {
          Text(voice.title).foregroundStyle(theme.color(.textStrong))
          Spacer()
          if settings.voice == voice { Image(systemName: "checkmark").foregroundStyle(theme.color(.primary)) }
        }.contentShape(Rectangle())
      }.accessibilityIdentifier("voice-choice-" + voice.rawValue)
        .accessibilityAddTraits(settings.voice == voice ? .isSelected : [])
    }.listRowBackground(theme.color(.surface))
  }
}

struct ThemePicker: View {
  @Environment(\.appTheme) private var theme
  @Bindable var settings: AppearanceSettings
  var body: some View {
    List {
      ForEach(AppTheme.families) { family in
        Button {
          settings.family = family.id
          Haptics.play(.selection)
        } label: {
          HStack(spacing: 14) {
            ThemePreview(theme: AppTheme.load(theme.dark ? family.dark : family.light))
            Text(family.name).foregroundStyle(theme.color(.textStrong))
            Spacer()
            if currentFamily == family.id {
              Image(systemName: "checkmark").foregroundStyle(theme.color(.primary))
            }
          }.padding(.vertical, 5)
        }.accessibilityIdentifier("theme-" + family.id)
          .accessibilityAddTraits(currentFamily == family.id ? .isSelected : [])
      }.listRowBackground(theme.color(.surface))
    }.settingsList(theme).navigationTitle("Temas").navigationBarTitleDisplayMode(.inline)
  }
  private var currentFamily: String {
    guard let override = settings.override else { return settings.family }
    return AppTheme.families.first { $0.dark == override || $0.light == override }?.id ?? "openchamber"
  }
}

private struct ThemePreview: View {
  let theme: AppTheme
  var body: some View {
    HStack(spacing: 3) {
      ForEach([ThemeRole.primary, .accent, .success, .textStrong], id: \.self) { role in
        Capsule().fill(theme.color(role)).frame(width: 7, height: role == .textStrong ? 14 : 22)
      }
    }.padding(8).background(theme.color(.background), in: RoundedRectangle(cornerRadius: 9))
      .overlay { RoundedRectangle(cornerRadius: 9).stroke(theme.color(.border)) }
      .accessibilityHidden(true)
  }
}

struct ServerListView: View {
  @Environment(\.appTheme) private var theme
  let runtime: AppRuntime
  let store: SessionStore
  @State private var editor: ServerEditorRoute?
  @State private var removing: SavedServer?
  @State private var pairing = false
  @State private var error: String?
  var body: some View {
    List {
      Section("Servidor ativo") {
        VStack(alignment: .leading, spacing: 6) {
          Text(runtime.servers.active.title).font(.headline)
          Text(runtime.servers.active.url.absoluteString).font(.caption).textSelection(.enabled)
            .foregroundStyle(theme.color(.textSecondary))
          connectionState(store, theme: theme)
          if let version = store.serverVersion {
            Text("Versão \(version)").font(.caption).foregroundStyle(theme.color(.textSecondary))
          }
          if let failure = store.error {
            Text(failure).font(.caption).foregroundStyle(theme.color(.error))
          }
        }.padding(.vertical, 3)
      }.listRowBackground(theme.color(.surface))
      Section("Servidores salvos") {
        ForEach(runtime.servers.servers) { server in
          HStack {
            Button {
              do { try runtime.servers.select(server.id) }
              catch { self.error = error.localizedDescription }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: server.id == runtime.servers.activeID ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(theme.color(server.id == runtime.servers.activeID ? .primary : .icon))
                VStack(alignment: .leading, spacing: 4) {
                  Text(server.title).foregroundStyle(theme.color(.textStrong))
                  Text(server.url.absoluteString).font(.caption).foregroundStyle(theme.color(.textSecondary))
                  if server.builtIn { Text("Padrão · não pode ser removido").font(.caption2).foregroundStyle(theme.color(.textWeak)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
              }
            }.buttonStyle(.plain).accessibilityIdentifier("server-select-" + server.id)
            Button { editor = .init(server: server) } label: {
              Image(systemName: "pencil").frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.borderless).accessibilityLabel("Editar \(server.title)")
          }.padding(.vertical, 3)
            .swipeActions {
              if !server.builtIn {
                Button("Remover", role: .destructive) { removing = server }
              }
            }
            .contextMenu {
              Button("Editar", systemImage: "pencil") { editor = .init(server: server) }
              if !server.builtIn {
                Button("Remover", systemImage: "trash", role: .destructive) { removing = server }
              }
            }
        }
      }.listRowBackground(theme.color(.surface))
      Section {
        Button("Adicionar servidor", systemImage: "plus") { editor = .init(server: nil) }
          .accessibilityIdentifier("server-add")
        Button("Ler QR code", systemImage: "qrcode.viewfinder") { pairing = true }
          .accessibilityIdentifier("server-pair")
      } footer: {
        Text("Senhas e tokens ficam apenas no Chaves deste iPhone. Trocar de servidor fecha a conversa atual; rascunhos e posições de leitura ficam preservados por endereço.")
      }.listRowBackground(theme.color(.surface))
    }.settingsList(theme).navigationTitle("Servidores").navigationBarTitleDisplayMode(.inline)
      .sheet(item: $editor) { route in
        ServerEditor(servers: runtime.servers, server: route.server).sessionAlertOverlay()
      }
      .sheet(isPresented: $pairing) { PairingSheet(servers: runtime.servers).sessionAlertOverlay() }
      .confirmationDialog("Remover \(removing?.title ?? "servidor")?", isPresented: Binding(
        get: { removing != nil }, set: { if !$0 { removing = nil } }
      ), titleVisibility: .visible) {
        Button("Remover servidor", role: .destructive) {
          guard let removing else { return }
          do { try runtime.servers.remove(removing.id) }
          catch { self.error = error.localizedDescription }
          self.removing = nil
        }
        Button("Cancelar", role: .cancel) { removing = nil }
      } message: { Text("A credencial será apagada deste iPhone. As sessões no servidor não serão removidas.") }
      .alert("Não foi possível alterar o servidor", isPresented: Binding(
        get: { error != nil }, set: { if !$0 { error = nil } }
      )) { Button("OK") { error = nil } } message: { Text(error ?? "") }
  }
}

private struct ServerEditorRoute: Identifiable {
  let id = UUID()
  let server: SavedServer?
}

struct ServerEditor: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let servers: ServerStore
  let server: SavedServer?
  @State private var name = ""
  @State private var address = ""
  @State private var password = ""
  @State private var tested: String?
  @State private var succeeded = false
  @State private var busy = false
  @State private var error: String?
  @State private var task: Task<Void, Never>?
  var body: some View {
    NavigationStack {
      List {
        Section("Endereço e acesso") {
          TextField("Nome (opcional)", text: $name).textContentType(.nickname).autocorrectionDisabled()
            .accessibilityIdentifier("server-name")
          TextField("http://servidor:4096", text: $address).keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .textContentType(.URL)
            .disabled(server?.builtIn == true).accessibilityIdentifier("server-address")
          SecureField("Senha (opcional)", text: $password).textInputAutocapitalization(.never)
            .autocorrectionDisabled().accessibilityIdentifier("server-password")
            // Do not advertise API secrets as website login credentials.
            .textContentType(.oneTimeCode)
            .disabled(server?.builtIn == true && servers.launchOverride != nil)
        }.listRowBackground(theme.color(.surface))
        Section {
          Button {
            task?.cancel()
            task = Task { await test() }
          } label: {
            HStack { Text("Testar conexão"); Spacer(); if busy { ProgressView() } }
          }.disabled(busy || ServerAddress.parse(address) == nil).accessibilityIdentifier("server-test")
          if let tested {
            Label(tested, systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle")
              .font(.subheadline).foregroundStyle(theme.color(succeeded ? .success : .error))
              .accessibilityIdentifier("server-test-result")
          }
        } footer: { Text("O teste consulta apenas /api/info. Nenhuma sessão é criada ou executada.") }
          .listRowBackground(theme.color(.surface))
        if let error { Section { Text(error).foregroundStyle(theme.color(.error)) }.listRowBackground(theme.color(.surface)) }
      }.settingsList(theme, voice: false).navigationTitle(server == nil ? "Adicionar servidor" : "Editar servidor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Salvar") { save() }.disabled(busy || tested == nil).accessibilityIdentifier("server-save")
          }
        }
    }
    .onAppear {
      name = server?.name ?? ""
      address = server?.url.absoluteString ?? ""
      do { password = try server.flatMap { try servers.password($0) } ?? "" }
      catch { self.error = error.localizedDescription }
      #if DEBUG
      if server == nil, ProcessInfo.processInfo.environment["OPENCODE_SETTINGS_TEST_INPUT"] == "1" {
        password = servers.launchOverride?.password ?? ""
      }
      #endif
    }
    .onChange(of: address) { tested = nil; task?.cancel(); busy = false }
    .onChange(of: password) { tested = nil; task?.cancel(); busy = false }
    .onDisappear { task?.cancel() }
  }
  private func test() async {
    guard let url = ServerAddress.parse(address) else { return }
    busy = true
    tested = nil
    error = nil
    defer { if !Task.isCancelled { busy = false } }
    do {
      try servers.validate(url)
      let info = try await PairingClient().test(.init(url: url, password: password))
      try Task.checkCancellation()
      succeeded = true
      tested = "Conectado · versão \(info.version ?? "")"
    } catch {
      guard !Task.isCancelled else { return }
      succeeded = false
      tested = "Falha na conexão. \(error.localizedDescription)"
    }
  }
  private func save() {
    do {
      if let server { try servers.edit(server.id, name: name, address: address, password: password) }
      else { try servers.add(name: name, address: address, password: password) }
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

private var appVersion: String {
  let info = Bundle.main.infoDictionary ?? [:]
  return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
}

private struct AboutView: View {
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  var body: some View {
    List {
      Section("OpenCode") {
        LabeledContent("Versão e build", value: appVersion)
        LabeledContent("Commit", value: commit)
        LabeledContent("Versão do servidor", value: store.serverVersion ?? "Indisponível")
      }.listRowBackground(theme.color(.surface))
      Section {
        Link("README no GitHub", destination: URL(string: "https://github.com/alexandrereyes/opencode/tree/custom/packages/ios-custom")!)
      }.listRowBackground(theme.color(.surface))
    }.settingsList(theme).navigationTitle("Sobre").navigationBarTitleDisplayMode(.inline)
  }
  private var commit: String {
    let value = Bundle.main.object(forInfoDictionaryKey: "OpenCodeCommit") as? String ?? ""
    return value.isEmpty ? "desenvolvimento" : value
  }
}

@MainActor private func connectionState(_ store: SessionStore, theme: AppTheme) -> some View {
  Label(store.connected ? "Conectado" : (store.error == nil ? "Conectando…" : "Desconectado"),
        systemImage: store.connected ? "checkmark.circle.fill" : "network.slash")
    .font(.caption).foregroundStyle(theme.color(store.connected ? .success : .textSecondary))
}

extension View {
  func settingsList(_ theme: AppTheme, voice: Bool = true) -> some View {
    self.listStyle(.insetGrouped).scrollContentBackground(.hidden)
      .background(theme.color(.background)).foregroundStyle(theme.color(.textStrong))
      .listSectionSeparatorTint(theme.color(.border))
      .listRowSeparatorTint(theme.color(.border))
      .floatingVoiceInset(enabled: voice)
  }
}
