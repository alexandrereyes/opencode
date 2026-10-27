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
  @State private var hovering = false

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 15, weight: .regular))
      .foregroundStyle(theme.color(.text))
      .frame(width: 28, height: 26)
      .background(theme.color(.highlight).opacity(hovering && enabled ? 1 : 0), in: RoundedRectangle(cornerRadius: 7))
      .opacity(enabled ? 1 : 0.4)
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

/// `…` (the session's actions) and Nova sessão, over Contexto or, with Contexto hidden, at the chat's end.
struct MacSessionActions: View {
  @Bindable var store: SessionStore
  @Bindable var runtime: MacRuntime

  private var row: SessionRow? { store.rows.first { $0.id == runtime.selection.sessionID } }

  var body: some View {
    HStack(spacing: 2) {
      Menu {
        if let row {
          Button("Renomear…", systemImage: "pencil") { runtime.renameRequest = row }
          Button(row.pinned ? "Desafixar" : "Fixar", systemImage: row.pinned ? "pin.slash" : "pin") {
            Task { await store.pin(row) }
          }
          Button(row.muted ? "Reativar" : "Silenciar", systemImage: row.muted ? "bell" : "bell.slash") {
            Task { await store.mute(row) }
          }
          Divider()
          Button("Excluir sessão…", systemImage: "trash", role: .destructive) { runtime.deleteRequest = row.session }
          Divider()
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
      Button {
        NotificationCenter.default.post(name: .macNewSession, object: nil)
      } label: {
        MacToolbarIcon(symbol: "square.and.pencil")
      }
      .buttonStyle(.plain)
      .disabled(store.preferences == nil)
      .help("Nova sessão")
      .accessibilityLabel("Nova sessão")
    }
  }
}

/// The chat's identity in the title bar: the project avatar in its context ring, `App Mac ⌄` (a menu to switch
/// to another recent session) and `<worktree> · trabalhando…`, with no capsule behind it.
struct MacChatTitle: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: SessionStore
  @Bindable var runtime: MacRuntime
  let title: String
  let usage: ContextUsage?
  let running: Bool

  private var row: SessionRow? { store.rows.first { $0.id == runtime.selection.sessionID } }

  var body: some View {
    Menu {
      ForEach(recent, id: \.id) { other in
        Button {
          runtime.selection = MacSelection(sessionID: other.id)
        } label: {
          Text(other.session.displayTitle)
        }
        .disabled(other.id == runtime.selection.sessionID && runtime.selection.childID == nil)
      }
    } label: {
      HStack(spacing: 9) {
        ConversationAvatar(
          context: usage?.fraction, master: false,
          colors: theme.avatar(SessionList.avatarColor(row?.project, fallback: row?.session.projectID ?? "")),
          monogram: SessionList.monogram(row?.projectName ?? title),
          icon: row.flatMap { $0.chat ? nil : ProjectIcon.of($0.project) }, size: 30)
        ConversationTitle(
          title: title, switches: true, subtitle: subtitle, status: running ? "trabalhando…" : "",
          waiting: row?.state == .permission || row?.state == .question)
          .fixedSize()
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .help("Trocar de sessão")
    .accessibilityLabel([title, subtitle, running ? "trabalhando" : nil].compactMap { $0 }.joined(separator: ", "))
  }

  /// The worktree folder's name, like the iPhone header.
  private var subtitle: String {
    guard let row, let label = store.directoryLabel(row.session) else { return "" }
    return URL(fileURLWithPath: label.path).lastPathComponent
  }

  private var recent: [SessionRow] {
    Array(store.rows.sorted { $0.interactionAt > $1.interactionAt }.prefix(12))
  }
}
