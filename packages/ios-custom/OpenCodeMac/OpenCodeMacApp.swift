import OpenCodeKit
import SwiftUI

@main
struct OpenCodeMacApp: App {
  private let runtime = MacRuntime.shared

  init() {
    FilePreviewStorage.clean()
    MacNotifications.shared.start()
    #if DEBUG
    MacStress.openWindowIfNeeded()
    #endif
  }

  var body: some Scene {
    WindowGroup("OpenCode", id: "main") {
      MacRoot(runtime: runtime)
    }
    .defaultSize(width: 1500, height: 940)
    // One thin strip level with the window buttons, like the approved option B.
    .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    .commands { MacCommands(runtime: runtime) }

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

    // One LLM proxy window; it keeps its frame between openings and is listed in the Window menu.
    Window("LLM proxy", id: MacProxyWindow.id) {
      MacThemed(runtime: runtime) { MacProxyWindow(runtime: runtime) }
    }
    .defaultSize(width: 1000, height: 640)
    .windowResizability(.contentMinSize)
    .keyboardShortcut("l", modifiers: [.command, .shift])

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
      .environment(\.locale, Locale(identifier: "pt_BR"))
      .preferredColorScheme(runtime.appearance.colorScheme)
      .tint(theme.color(.primary))
  }
}

private struct MacRoot: View {
  let runtime: MacRuntime
  var body: some View {
    MacThemed(runtime: runtime) {
      Group {
        if let store = runtime.store, runtime.appliedRevision == runtime.servers.revision {
          MacWindow(store: store, runtime: runtime).id(runtime.identity)
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
    }
  }
}

/// The menu bar: Arquivo (Nova sessão, Nova janela, Atualizar), Visualizar (Contexto, Arquivos, the state filters),
/// Sessão (the selected session's actions and the selection mode), Ir (previous/next, Sessão mestra, Trocar) and
/// the LLM proxy window in Janela.
private struct MacCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  let runtime: MacRuntime

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Nova sessão") { runtime.newSession() }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(runtime.store?.preferences == nil)
      Button("Nova janela") { openWindow(id: "main") }
        .keyboardShortcut("n", modifiers: [.command, .option])
      Divider()
      Button("Atualizar sessões") { Task { await runtime.store?.reload() } }
        .keyboardShortcut("r", modifiers: .command)
    }
    CommandGroup(after: .sidebar) {
      Button(runtime.contextVisible ? "Ocultar contexto" : "Mostrar contexto") { runtime.contextVisible.toggle() }
        .keyboardShortcut("i", modifiers: [.command, .option])
      Button("Arquivos") { runtime.showFiles() }
        .keyboardShortcut("f", modifiers: [.command, .shift])
      if let store = runtime.store {
        Picker("Filtrar sessões", selection: Binding(get: { store.filter }, set: { store.filter = $0 })) {
          ForEach(SessionFilter.allCases) { Text($0.rawValue).tag($0) }
        }
      }
      Divider()
    }
    CommandGroup(after: .textEditing) {
      Button("Buscar na conversa") { NotificationCenter.default.post(name: .macSearchConversation, object: nil) }
        .keyboardShortcut("f", modifiers: .command)
    }
    CommandMenu("Sessão") {
      if let store = runtime.store {
        MacSessionMenuItems(store: store, runtime: runtime, shortcuts: true)
        Divider()
        Button("Selecionar todas as sessões") {
          if !runtime.sessionSelection.active, let id = runtime.selection.sessionID { runtime.sessionSelection.start(id) }
          runtime.bulkRequest = .selectAll
        }
        .keyboardShortcut("a", modifiers: [.command, .option])
        Button("Arquivar selecionadas") { runtime.bulkRequest = .archive }
          .disabled(!runtime.sessionSelection.active)
        Button("Excluir selecionadas…") { runtime.bulkRequest = .delete }
          .disabled(!runtime.sessionSelection.active)
        Button("Encerrar seleção") { runtime.sessionSelection.clear() }
          .disabled(!runtime.sessionSelection.active)
      }
    }
    CommandMenu("Ir") {
      Button("Trocar de sessão…") { runtime.switcherVisible = true }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(runtime.store == nil)
      Divider()
      // ⌘[ is the Mac's Back (Finder, Safari, Xcode): from a subagent to the session that started it. The list's
      // neighbors take ⌥⌘↑/⌥⌘↓, like moving up and down Sessões.
      Button("Voltar à sessão principal") { runtime.backToParent() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(runtime.selection.childID == nil)
      Button("Sessão anterior") { runtime.selectNeighbor(-1) }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
      Button("Próxima sessão") { runtime.selectNeighbor(1) }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
      Divider()
      Button("Sessão mestra") { runtime.openMaster() }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(runtime.store?.masterAvailability != .available)
    }
  }
}
