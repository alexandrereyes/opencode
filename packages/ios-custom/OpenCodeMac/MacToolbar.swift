import OpenCodeKit
import SwiftUI

/// A toolbar item drawn as plain content. macOS 26 wraps every item in a shared Liquid Glass capsule; the
/// approved window has one thin title bar with borderless icons, like macOS 15's.
struct MacPlainToolbarItem<Content: View>: ToolbarContent {
  var placement: ToolbarItemPlacement = .automatic
  @ViewBuilder let content: () -> Content

  var body: some ToolbarContent {
    if #available(macOS 26, *) {
      ToolbarItem(placement: placement, content: content).sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: placement, content: content)
    }
  }
}

/// Pushes the next items to the end of the title bar; earlier systems do it for `.automatic` items.
struct MacToolbarFlexibleSpace: ToolbarContent {
  var body: some ToolbarContent {
    if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
  }
}

/// A small borderless title-bar icon with a hover highlight.
struct MacToolbarIcon: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var enabled
  let symbol: String
  var role: ThemeRole = .text
  @State private var hovering = false

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 15, weight: .regular))
      .foregroundStyle(theme.color(role))
      .frame(width: 28, height: 26)
      .background(theme.color(.highlight).opacity(hovering && enabled ? 1 : 0), in: RoundedRectangle(cornerRadius: 7))
      .opacity(enabled ? 1 : 0.4)
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

/// The notifications bell, `…` (the session's actions) and Nova sessão, over Contexto or, with Contexto hidden, at
/// the chat's end.
struct MacSessionActions: View {
  @Bindable var store: SessionStore
  @Bindable var runtime: MacWindowRuntime

  var body: some View {
    HStack(spacing: 2) {
      MacNotificationBell(store: store, runtime: runtime)
      if runtime.selection.master && runtime.selection.childID == nil {
        // The iPhone's master conversation shows this trash instead of the session menu.
        Button { runtime.resetMaster() } label: { MacToolbarIcon(symbol: "trash") }
          .buttonStyle(.plain)
          .disabled(store.busy.contains("master-reset"))
          .help("Reiniciar Sessão mestra")
          .accessibilityLabel("Reiniciar Sessão mestra")
          .accessibilityIdentifier("master-trash")
      } else {
        sessionMenu
      }
      Button {
        runtime.newSession()
      } label: {
        MacToolbarIcon(symbol: "square.and.pencil")
      }
      .buttonStyle(.plain)
      .disabled(store.preferences == nil)
      .help("Nova sessão (⌘N)")
      .accessibilityLabel("Nova sessão")
    }
  }

  private var sessionMenu: some View {
    Menu {
      MacSessionMenuItems(store: store, runtime: runtime)
      Divider()
      Button("Buscar na conversa", systemImage: "magnifyingglass") {
        NotificationCenter.default.post(name: .macSearchConversation, object: runtime.id)
      }
      Button("Arquivos", systemImage: "folder") { runtime.showFiles() }
      Button(runtime.contextVisible ? "Ocultar contexto" : "Mostrar contexto", systemImage: "sidebar.right") {
        runtime.contextVisible.toggle()
      }
    } label: {
      MacToolbarIcon(symbol: "ellipsis")
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .help("Ações da sessão")
    .accessibilityLabel("Ações da sessão")
  }
}

/// The selected session's actions, shared by the title bar's `…` and the menu bar's Sessão menu: the iPhone's
/// conversation menu and row actions together.
struct MacSessionMenuItems: View {
  let store: SessionStore
  let runtime: MacWindowRuntime
  /// The menu bar carries the shortcuts; the title bar's copy shows the same items without registering them twice.
  var shortcuts = false

  var body: some View {
    let row = runtime.selectedRow
    Button("Nova sessão a partir desta", systemImage: "square.and.pencil") {
      if let id = row?.id { runtime.newSession(from: id) }
    }
    .shortcut(.fromThis, enabled: shortcuts)
    .disabled(row == nil || store.preferences == nil)
    Divider()
    Button("Renomear…", systemImage: "pencil") { runtime.renameRequest = row }
      .shortcut(.rename, enabled: shortcuts)
      .disabled(row == nil)
    Button(row?.pinned == true ? "Desafixar" : "Fixar", systemImage: row?.pinned == true ? "pin.slash" : "pin") {
      if let row { Task { await store.pin(row) } }
    }
    .shortcut(.pin, enabled: shortcuts)
    .disabled(row == nil)
    Button(row?.notify == true ? "Não avisar ao terminar" : "Avisar ao terminar",
      systemImage: row?.notify == true ? "bell.slash" : "bell") {
      if let row { Task { await store.toggleNotify(row) } }
    }
    .disabled(row == nil)
    Button("Marcar como lida", systemImage: "envelope.open") {
      if let row { Task { await store.markRead(row.session) } }
    }
    .disabled(row?.unread != true)
    Divider()
    Button("Arquivar…", systemImage: "archivebox") { runtime.archiveRequest = row }
      .shortcut(.archive, enabled: shortcuts)
      .disabled(row == nil)
    Button("Excluir sessão…", systemImage: "trash", role: .destructive) { runtime.deleteRequest = row?.session }
      .shortcut(.delete, enabled: shortcuts)
      .disabled(row == nil || runtime.sessionSelection.active)
  }
}

/// The chat's identity in the title bar: the project avatar in its context ring, `App Mac` and
/// `<worktree> · trabalhando…`, with no capsule behind it. It is a label: ⌘K's search switches sessions.
struct MacChatTitle: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: SessionStore
  @Bindable var runtime: MacWindowRuntime
  let title: String
  let usage: ContextUsage?
  let width: CGFloat
  let running: Bool

  private var row: SessionRow? { store.rows.first { $0.id == runtime.selection.sessionID } }
  private var master: Bool { runtime.selection.master }

  var body: some View {
    HStack(spacing: 9) {
      ConversationAvatar(
        context: usage?.fraction, master: master,
        colors: theme.avatar(SessionList.avatarColor(row?.project, fallback: row?.session.projectID ?? "")),
        monogram: SessionList.monogram(row?.projectName ?? title),
        icon: row.flatMap { $0.chat ? nil : ProjectIcon.of($0.project) }, size: 30)
      ConversationTitle(
        title: master ? "Sessão mestra" : title, subtitle: subtitle,
        status: running ? "trabalhando…" : "", waiting: row?.state == .permission || row?.state == .question)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: width, alignment: .leading)
    // Measure the label itself: the native toolbar host can retain its earlier, wider allocation.
    .background(MacSearchAnchor(role: .title))
    .fixedSize()
    .accessibilityElement(children: .combine)
    .accessibilityLabel([title, subtitle, running ? "trabalhando" : nil].compactMap { $0 }.joined(separator: ", "))
    .accessibilityAddTraits(.isHeader)
  }

  /// The worktree folder's name, like the iPhone header.
  private var subtitle: String {
    guard let row, let label = store.directoryLabel(row.session) else { return "" }
    return URL(fileURLWithPath: label.path).lastPathComponent
  }
}
