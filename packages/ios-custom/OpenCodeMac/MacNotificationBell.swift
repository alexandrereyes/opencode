import Observation
import OpenCodeKit
import SwiftUI

/// The Mac's in-app alerts, replacing the iPhone's banner: the bell lists what `SessionStore` and
/// `SessionAlertCenter` already hold. Permissions and questions are the store's pending requests; finished and
/// failed runs are the alerts the center admitted (it keeps only the latest, so they are kept here, newest first,
/// until Limpar). macOS notifications, the Dock badge and the rows' dots do not depend on it.
@MainActor @Observable final class MacAlertInbox {
  struct Finished: Identifiable {
    let id: UUID
    let session: Session
    let content: SessionAlertContent
    let date: Date
  }

  enum Item: Identifiable {
    case permission(PermissionRequest)
    case question(PendingForm)
    case finished(Finished)

    var id: String {
      switch self {
      case .permission(let value): "permission:" + value.id
      case .question(let value): "question:" + value.id
      case .finished(let value): "finished:" + value.id.uuidString
      }
    }
    var sessionID: String {
      switch self {
      case .permission(let value): value.sessionID
      case .question(let value): value.sessionID
      case .finished(let value): value.session.id
      }
    }
  }

  private(set) var finished: [Finished] = []
  private var seen: Set<String> = []
  private var cleared: Set<String> = []

  func record(_ message: SessionAlertCenter.Message) {
    guard message.content.kind == .succeeded || message.content.kind == .failed,
      !finished.contains(where: { $0.id == message.id }) else { return }
    finished.insert(Finished(id: message.id, session: message.session, content: message.content, date: .now), at: 0)
    if finished.count > 20 { finished.removeLast(finished.count - 20) }
  }

  func items(_ store: SessionStore) -> [Item] {
    let deleted = store.deletedIDs
    let all = store.permissions.map(Item.permission) + store.forms.map(Item.question)
      + finished.filter { !deleted.contains($0.session.id) }.map(Item.finished)
    return all.filter { !cleared.contains($0.id) }
  }

  func unseen(_ store: SessionStore) -> Int { items(store).filter { !seen.contains($0.id) }.count }
  func see(_ item: Item) { seen.insert(item.id) }

  func clear(_ store: SessionStore) {
    cleared.formUnion(items(store).map(\.id))
    finished.removeAll()
  }
}

/// The bell left of `…`, with the unseen count; its popover lists the alerts.
struct MacNotificationBell: View {
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  let runtime: MacWindowRuntime
  @State private var open = false

  var body: some View {
    let unseen = runtime.app.alertInbox.unseen(store)
    Button { open.toggle() } label: {
      MacToolbarIcon(symbol: "bell")
        .overlay(alignment: .topTrailing) {
          if unseen > 0 {
            Text(unseen > 99 ? "99+" : "\(unseen)").font(.system(size: 9, weight: .bold)).monospacedDigit()
              .foregroundStyle(theme.color(.onPrimary))
              .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
              .background(theme.color(.primary), in: Capsule())
              .offset(x: 3, y: -3)
              .allowsHitTesting(false)
          }
        }
    }
    .buttonStyle(.plain)
    .help("Notificações")
    .accessibilityLabel(unseen > 0 ? "Notificações, \(unseen) não vistas" : "Notificações")
    .accessibilityIdentifier("notifications-bell")
    .popover(isPresented: $open, arrowEdge: .bottom) {
      MacNotificationList(store: store, runtime: runtime) { open = false }
        .environment(\.appTheme, theme)
    }
  }
}

private struct MacNotificationList: View {
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  let runtime: MacWindowRuntime
  let close: () -> Void

  private var inbox: MacAlertInbox { runtime.app.alertInbox }

  var body: some View {
    let items = inbox.items(store)
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Notificações").appFont(.secondary, weight: .semibold).foregroundStyle(theme.color(.textStrong))
        Spacer()
        Button("Limpar") { inbox.clear(store) }.buttonStyle(.plain).appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary)).disabled(items.isEmpty)
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      if items.isEmpty {
        Text("Nenhuma notificação").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
          .frame(maxWidth: .infinity).padding(.vertical, 22)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(items) { item in row(item) }
          }
        }
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.bottom, 6)
    .frame(width: 380)
    .background(theme.color(.background))
  }

  private func row(_ item: MacAlertInbox.Item) -> some View {
    let root = store.rows.first { $0.id == item.sessionID || $0.memberIDs.contains(item.sessionID) }
    let title = root?.session.displayTitle ?? sessionTitle(item)
    return HStack(spacing: 10) {
      Button { open(item) } label: {
        HStack(spacing: 10) {
          MacPromptAvatar(avatar: MacTranscriptAvatar(root, mixChats: !store.chatsSelected,
            master: item.sessionID == store.masterID), size: 20)
          VStack(alignment: .leading, spacing: 2) {
            Text(title + " · " + kind(item)).appFont(.caption, weight: .medium)
              .foregroundStyle(theme.color(.textStrong)).lineLimit(1)
            Text(detail(item)).appFont(.footnote).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
          }
          Spacer(minLength: 6)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      actions(item, row: root)
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private func actions(_ item: MacAlertInbox.Item, row: SessionRow?) -> some View {
    switch item {
    case .permission(let request):
      HStack(spacing: 6) {
        Button("Negar") { reply(request, row: row, allow: false, item: item) }
        Text("·").foregroundStyle(theme.color(.textWeak))
        Button("Permitir") { reply(request, row: row, allow: true, item: item) }
      }
      .buttonStyle(.plain).appFont(.caption, weight: .medium).foregroundStyle(theme.color(.primary))
      .disabled(row.map { store.busy.contains($0.id) } ?? false)
    case .question:
      Button("Responder") { open(item) }.buttonStyle(.plain).appFont(.caption, weight: .medium)
        .foregroundStyle(theme.color(.primary))
    case .finished:
      EmptyView()
    }
  }

  private func kind(_ item: MacAlertInbox.Item) -> String {
    switch item {
    case .permission: "pede permissão"
    case .question: "pergunta"
    case .finished(let value): value.content.kind == .failed ? "terminou com erro" : value.content.label.lowercased()
    }
  }

  private func detail(_ item: MacAlertInbox.Item) -> String {
    switch item {
    case .permission(let request): request.resources.first ?? request.message ?? request.preview
    case .question(let form): form.preview
    case .finished(let value):
      value.content.preview
        ?? SessionList.relativeTime(value.date.timeIntervalSince1970 * 1000).accessibilityLabel
    }
  }

  private func sessionTitle(_ item: MacAlertInbox.Item) -> String {
    if case .finished(let value) = item { return value.session.displayTitle }
    return store.entries.first { $0.session.id == item.sessionID }?.session.displayTitle ?? "Sessão"
  }

  /// In the front window, like a click on the macOS notification.
  private func open(_ item: MacAlertInbox.Item) {
    inbox.see(item)
    close()
    store.alerts.openingSession()
    let target = runtime.app.front ?? runtime
    target.select(item.sessionID)
    target.window?.makeKeyAndOrderFront(nil)
  }

  private func reply(_ request: PermissionRequest, row: SessionRow?, allow: Bool, item: MacAlertInbox.Item) {
    inbox.see(item)
    Task {
      if let row, store.permission(row)?.id == request.id { return await store.reply(row, allow: allow) }
      try? await store.client.reply(request, allow: allow)
      await store.reload()
    }
  }
}
