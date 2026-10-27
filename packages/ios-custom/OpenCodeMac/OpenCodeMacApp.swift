import OpenCodeKit
import SwiftUI

@main
struct OpenCodeMacApp: App {
  private let runtime = MacRuntime.shared

  init() { FilePreviewStorage.clean() }

  var body: some Scene {
    WindowGroup("OpenCode", id: "main") {
      MacRoot(runtime: runtime)
    }
    .defaultSize(width: 1500, height: 940)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands { MacCommands(runtime: runtime) }

    // A resource opens in its own window, like the iPhone's full-screen viewer.
    WindowGroup("Recurso", id: "resource", for: String.self) { $id in
      if let id { MacThemed(runtime: runtime) { MacResourceWindow(resourceID: id, runtime: runtime) } }
    }
    .defaultSize(width: 520, height: 860)

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
      .frame(minWidth: 980, minHeight: 620)
      .task(id: runtime.servers.revision) { await runtime.prepare() }
    }
  }
}

private struct MacCommands: Commands {
  let runtime: MacRuntime
  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button(runtime.contextVisible ? "Ocultar contexto" : "Mostrar contexto") { runtime.contextVisible.toggle() }
        .keyboardShortcut("i", modifiers: [.command, .option])
      Button("Arquivos") { runtime.showFiles() }
        .keyboardShortcut("f", modifiers: [.command, .shift])
    }
    CommandGroup(after: .newItem) {
      Button("Atualizar sessões") { Task { await runtime.store?.reload() } }
        .keyboardShortcut("r", modifiers: .command)
    }
  }
}
