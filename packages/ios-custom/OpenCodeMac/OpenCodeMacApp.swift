import AppIntents
import OpenCodeKit
import SwiftUI

@main
struct OpenCodeMacApp: App {
  @NSApplicationDelegateAdaptor(MacVoiceAppDelegate.self) private var delegate
  private let runtime = MacRuntime.shared

  init() {
    FilePreviewStorage.clean()
    MacNotifications.shared.start()
    MacAudioDevices.shared.start()
    MacOutsideClick.start()
    if !MacLaunch.fixture { TranscriptionController.shared.start() }
    #if DEBUG
    MacStress.openWindowIfNeeded()
    #endif
  }

  var body: some Scene {
    WindowGroup("OpenCode", id: "main", for: MacWindowTarget.self) { $target in
      MacRoot(runtime: runtime, target: target)
    } defaultValue: {
      MacWindowTarget()
    }
    .defaultSize(width: 1500, height: 940)
    // One strip level with the window buttons, like the approved option B. The regular unified height (not the
    // compact one) centers the two-line session title on the buttons with room above and below it.
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands { MacCommands() }

    // A resource opens in its own window, like the iPhone's full-screen viewer.
    WindowGroup("Recurso", id: "resource", for: String.self) { $id in
      if let id { MacThemed(runtime: runtime) { MacResourceWindow(resourceID: id, runtime: runtime) } }
    }
    .defaultSize(width: 520, height: 860)

    // A background task's output, live, in its own window.
    WindowGroup("Saída", id: MacShellOutputWindow.id, for: MacShellOutputWindow.Target.self) { $target in
      if let target { MacThemed(runtime: runtime) { MacShellOutputWindow(target: target, runtime: runtime) } }
    }
    .defaultSize(width: 760, height: 520)

    Settings {
      MacThemed(runtime: runtime) { MacSettingsView(runtime: runtime) }
    }
  }
}

/// The theme, locale and color scheme every window of the app shares.
struct MacThemed<Content: View>: View {
  @Environment(\.colorScheme) private var systemScheme
  let runtime: MacRuntime
  @ViewBuilder let content: Content
  var body: some View {
    let theme = runtime.appearance.theme(systemDark: systemScheme == .dark)
    content
      .environment(\.appTheme, theme)
      .environment(\.voiceController, runtime.audio.voice)
      .environment(\.voiceSessionStore, runtime.store)
      .environment(\.locale, Locale(identifier: "pt_BR"))
      .preferredColorScheme(runtime.appearance.colorScheme)
      .tint(theme.color(.primary))
  }
}

private struct MacRoot: View {
  @Environment(\.openWindow) private var openWindow
  let runtime: MacRuntime
  let target: MacWindowTarget
  var body: some View {
    MacThemed(runtime: runtime) {
      Group {
        if let store = runtime.store, runtime.appliedRevision == runtime.servers.revision {
          MacWindowScene(app: runtime, store: store, target: target).id(runtime.identity)
        } else if let error = runtime.error {
          ContentUnavailableView {
            Label("Credenciais indisponíveis", systemImage: "key")
          } description: { Text(error) } actions: {
            Button("Tentar novamente") { Task { await runtime.prepare() } }
          }
        } else {
          ProgressView("Conectando…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      // No minimum width here: the split view and the inspector derive the window's own, and a smaller one set
      // on top of it lets the window shrink below what their columns need. Their minimum sizes then oscillate
      // and AppKit aborts ("more Update Constraints in Window passes than there are views").
      .frame(minHeight: 620)
      .task(id: runtime.servers.revision) { await runtime.prepare() }
      .onAppear { runtime.openMainWindow = { openWindow(id: "main", value: MacWindowTarget()) } }
    }
  }
}

private struct MacWindowScene: View {
  let app: MacRuntime
  let store: SessionStore
  let target: MacWindowTarget
  @State private var runtime: MacWindowRuntime?
  var body: some View {
    Group {
      if let runtime {
        MacWindow(store: store, runtime: runtime)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task {
      guard runtime == nil else { return }
      let next = MacWindowRuntime(app: app, id: target.id, selection: app.initialSelection)
      if let id = target.sessionID, next.selection.sessionID == nil || MacLaunch.fixture { next.select(id) }
      if let pending = app.pendingNotification {
        if pending.server == nil || pending.server == store.client.configuration.url.absoluteString {
          next.select(pending.id)
        }
        app.pendingNotification = nil
      }
      app.windows[target.id] = next
      app.syncShown()
      runtime = next
    }
  }
}

/// The menu bar: Arquivo (Nova sessão, Nova janela, Atualizar), Visualizar (Contexto, Arquivos, the state filters),
/// Sessão (the selected session's actions and the selection mode), Ir (search, back, previous/next, Sessão mestra,
/// voice, ⌘1…⌘9) and the LLM proxy modal in Janela.
private struct MacCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.macWindow) private var runtime
  @AppStorage("OpenCodeSessionSections") private var collapse = SessionSectionCollapse()

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Nova sessão") { runtime?.newSession() }
        .shortcut(.newSession)
        .disabled(runtime?.store?.preferences == nil)
      Button("Nova janela") { openWindow(id: "main", value: MacWindowTarget()) }
        .shortcut(.newWindow)
      Divider()
      Button("Atualizar sessões") { Task { await runtime?.store?.reload() } }
        .shortcut(.reload)
    }
    CommandGroup(after: .sidebar) {
      if let runtime {
        Button(runtime.contextVisible ? "Ocultar contexto" : "Mostrar contexto") { runtime.contextVisible.toggle() }
          .shortcut(.context)
        Button("Arquivos") { runtime.showFiles() }
          .shortcut(.files)
        if let store = runtime.store {
          Picker("Filtrar sessões", selection: Binding(get: { store.filter }, set: { store.filter = $0 })) {
            ForEach(SessionFilter.allCases) { Text($0.rawValue).tag($0) }
          }
        }
        Divider()
      }
    }
    CommandGroup(after: .textEditing) {
      Button("Buscar na conversa") { NotificationCenter.default.post(name: .macSearchConversation, object: runtime?.id) }
        .shortcut(.find)
        .disabled(runtime == nil)
    }
    CommandGroup(before: .help) {
      Button("Atalhos do teclado") { runtime?.shortcutsVisible = true }
        .shortcut(.shortcuts)
        .disabled(runtime == nil)
    }
    CommandGroup(after: .windowArrangement) {
      Divider()
      Button("LLM proxy") { runtime?.showProxy() }
        .shortcut(.proxy)
        .disabled(runtime?.store == nil)
    }
    CommandMenu("Sessão") {
      Button("Escolher modelo e esforço…") { runtime?.openModelPalette() }
        .shortcut(.model)
        .disabled(runtime == nil)
      Button("Pergunta paralela…") { runtime?.askSideQuestion() }
        .shortcut(.sideQuestion)
        .disabled(runtime?.selection.sessionID == nil)
      if let runtime, let store = runtime.store {
        MacSessionMenuItems(store: store, runtime: runtime, shortcuts: true)
        Divider()
        Button("Selecionar todas as sessões") {
          if !runtime.sessionSelection.active, let id = runtime.selection.sessionID { runtime.sessionSelection.start(id) }
          runtime.bulkRequest = .selectAll
        }
        .shortcut(.selectAll)
        Button("Arquivar selecionadas") { runtime.bulkRequest = .archive }
          .disabled(!runtime.sessionSelection.active)
        Button("Excluir selecionadas…") { runtime.bulkRequest = .delete }
          .disabled(!runtime.sessionSelection.active)
        Button("Encerrar seleção") { runtime.sessionSelection.clear() }
          .disabled(!runtime.sessionSelection.active)
        Divider()
        Button("Reiniciar Sessão mestra") { runtime.resetMaster() }
          .disabled(!runtime.selection.master || runtime.selection.childID != nil
            || store.busy.contains("master-reset"))
      }
    }
    CommandMenu("Ir") {
      if let runtime {
        Button("Buscar projetos e sessões…") { runtime.search.open() }
          .shortcut(.search)
          .disabled(runtime.store == nil)
        Button("Escrever mensagem") { runtime.focusComposer() }
          .shortcut(.compose)
          .disabled(runtime.selection.sessionID == nil)
        Divider()
        // ⌘[ is the Mac's Back; the list's neighbors take ⌥⌘↑/⌥⌘↓.
        Button("Voltar à sessão principal") { runtime.backToParent() }
          .shortcut(.back)
          .disabled(runtime.selection.childID == nil)
        Button("Sessão anterior") { runtime.selectNeighbor(-1) }
          .shortcut(.previous)
        Button("Próxima sessão") { runtime.selectNeighbor(1) }
          .shortcut(.next)
        Divider()
        Button("Sessão mestra") { runtime.openMaster() }
          .shortcut(.master)
          .disabled(runtime.store?.masterAvailability != .available)
        if let store = runtime.store {
          Button(runtime.voicePresentation.visible(runtime.app.audio.voice) ? "Encerrar conversa por voz"
            : "Conversar por voz") {
            runtime.voicePresentation.toggle(runtime.app.audio.voice, sessions: store)
          }
          .disabled(runtime.app.audio.voice.busy)
          // ⌘1…⌘9: the first sessions in the order Sessões shows them, with its filter and collapsed sections.
          let rows = SessionNavigation.numbered(
            SessionSections.group(store.filtered, now: .now), collapse: collapse)
          if !rows.isEmpty {
            Divider()
            Section("Sessões da lista") {
              ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button(row.session.displayTitle) { runtime.selection = MacSelection(sessionID: row.id) }
                  .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
              }
            }
          }
        }
      }
    }
  }
}
