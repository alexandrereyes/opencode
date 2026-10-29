import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// The bell shows the same state as Sessões. Its count and "Não lidas" are the rows of "Precisa de você"
/// (`SessionAttention`: permissions, questions, failures and unread answers of sessions that are not working, read
/// against the server's `viewed`), one line per session in the section's order, so reading a conversation anywhere
/// (Mac, iPhone, web) clears its line. "Anteriores" are recent answers already read; Limpar hides them up to now. Only
/// three things are local: which lines arrived during this run (`fresh`, highlighted until read), the latest alert
/// text per session and the Limpar mark.
@MainActor @Observable final class MacAlertInbox {
  enum Kind {
    case permission(PermissionRequest)
    case question(PendingForm)
    case failed, running, replied
  }

  struct Item: Identifiable {
    let row: SessionRow
    let kind: Kind
    var id: String { row.id }
    /// The session a click opens: the subagent that asks, otherwise the root.
    var target: String {
      switch kind {
      case .permission(let request): request.sessionID
      case .question(let form): form.sessionID
      default: row.id
      }
    }
  }

  private(set) var fresh: Set<String> = []
  /// Bumped once per batch of new lines; the front window opens its panel on it.
  private(set) var arrival = 0
  private var latest: [String: (content: SessionAlertContent, date: Date)] = [:]
  private var cleared = UserDefaults.standard.dictionary(forKey: clearedKey) as? [String: Double] ?? [:]
  @ObservationIgnored private var known: Set<String>?
  @ObservationIgnored private weak var observed: SessionStore?
  private static let clearedKey = "OpenCodeMacBellCleared"
  private static let ready = "ready"

  func record(_ message: SessionAlertCenter.Message) {
    latest[message.session.id] = (message.content, .now)
    if latest.count > 60, let oldest = latest.min(by: { $0.value.date < $1.value.date })?.key { latest[oldest] = nil }
  }

  /// "Precisa de você" in its order: permissions, questions, failures, then unread answers, newest first.
  func unread(_ rows: [SessionRow], store: SessionStore) -> [Item] {
    SessionAttention.ordered(rows).map { Item(row: $0, kind: kind($0, store: store)) }
  }

  func earlier(_ rows: [SessionRow], excluding unread: [Item], store: SessionStore) -> [Item] {
    let shown = Set(unread.map(\.id))
    let after = cleared[store.client.configuration.url.absoluteString] ?? 0
    return rows.filter { !shown.contains($0.id) && ($0.session.time.idle ?? 0) > after }
      .sorted { ($0.session.time.idle ?? 0) > ($1.session.time.idle ?? 0) }
      .prefix(8)
      .map { Item(row: $0, kind: $0.session.outcome == .failed ? .failed : .replied) }
  }

  func clear(_ store: SessionStore) {
    cleared[store.client.configuration.url.absoluteString] = Date.now.timeIntervalSince1970 * 1000
    if !MacLaunch.fixture { UserDefaults.standard.set(cleared, forKey: Self.clearedKey) }
  }

  /// The latest alert text of a session or its subagents, else the list's preview.
  func detail(_ item: Item, store: SessionStore) -> String? {
    let alert = latest.filter { item.row.memberIDs.contains($0.key) }.max { $0.value.date < $1.value.date }?.value
    if let preview = alert?.content.preview, !preview.isEmpty { return preview }
    if let text = store.previews[item.id]?.text, !text.isEmpty { return text }
    return alert?.content.label
  }

  /// What the arrival check compares: every line (`line|`), its unread dot and its requests. Marked ready once a
  /// whole reload settled, so a launch does not count what was already waiting as new.
  func keys(_ items: [Item], store: SessionStore) -> Set<String> {
    var keys: Set<String> = store.preferences != nil && !store.loading ? [Self.ready] : []
    for item in items {
      keys.insert("line|" + item.id)
      if item.row.unread { keys.insert("unread|" + item.id) }
      if item.row.state == .permission {
        store.permissions.filter { item.row.memberIDs.contains($0.sessionID) }
          .forEach { keys.insert("permission|" + item.id + "|" + $0.id) }
      }
      store.forms.filter { item.row.memberIDs.contains($0.sessionID) }
        .forEach { keys.insert("question|" + item.id + "|" + $0.id) }
    }
    return keys
  }

  /// A line is new when its dot or a request appears. The conversation on screen is already read.
  func observe(_ keys: Set<String>, rows: [SessionRow], store: SessionStore) {
    if observed !== store {
      observed = store
      known = nil
      fresh = []
    }
    let lines = Set(keys.compactMap { $0.hasPrefix("line|") ? String($0.dropFirst(5)) : nil })
    if !fresh.isSubset(of: lines) { fresh.formIntersection(lines) }
    guard known != nil || keys.contains(Self.ready) else { return }
    defer { known = keys }
    guard let known else { return }
    let shown = store.shownSessionID.flatMap { id in rows.first { $0.memberIDs.contains(id) }?.id }
    let new = Set(keys.subtracting(known).filter { !$0.hasPrefix("line|") && $0 != Self.ready }
      .compactMap { $0.split(separator: "|").dropFirst().first.map(String.init) })
      .subtracting([shown].compactMap { $0 })
    guard !new.isEmpty else { return }
    fresh.formUnion(new)
    arrival += 1
  }

  /// In the front window, like a click on the macOS notification. Opening it is what marks it read.
  func open(_ item: Item, store: SessionStore, runtime: MacWindowRuntime) {
    store.alerts.openingSession()
    let target = runtime.app.front ?? runtime
    target.select(item.target)
    target.window?.makeKeyAndOrderFront(nil)
  }

  private func kind(_ row: SessionRow, store: SessionStore) -> Kind {
    if row.state == .permission, let request = store.permission(row) { return .permission(request) }
    if row.state == .question, let form = store.forms.first(where: { row.memberIDs.contains($0.sessionID) }) {
      return .question(form)
    }
    switch row.state {
    case .failed: return .failed
    case .running: return .running
    default: return .replied
    }
  }
}

/// The bell left of `…`, with the count of "Não lidas". A new line opens the list for a moment in the front window,
/// in a panel that never takes the keyboard (`MacBellPanel`); a click opens it until a click outside or Esc.
struct MacNotificationBell: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let store: SessionStore
  let runtime: MacWindowRuntime
  @State private var panel = MacBellPanel()

  private var inbox: MacAlertInbox { runtime.app.alertInbox }

  var body: some View {
    let rows = store.rows
    let items = inbox.unread(rows, store: store)
    let count = items.count
    let fresh = !inbox.fresh.isEmpty
    Button { panel.toggle(list) } label: {
      MacToolbarIcon(symbol: fresh ? "bell.fill" : "bell", role: fresh ? .primary : .text)
        .symbolEffect(.bounce, value: reduceMotion ? 0 : inbox.arrival)
        .overlay(alignment: .topTrailing) {
          if count > 0 {
            Text(count > 99 ? "99+" : "\(count)").font(.system(size: 9, weight: .bold)).monospacedDigit()
              .foregroundStyle(theme.color(.onPrimary))
              .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
              .background(theme.color(.primary), in: Capsule())
              .offset(x: 3, y: -3)
              .allowsHitTesting(false)
          }
        }
        .background(MacBellAnchor(panel: panel))
    }
    .buttonStyle(.plain)
    .help("Notificações")
    .accessibilityLabel(count > 0 ? "Notificações, \(count) não lidas" : "Notificações")
    .accessibilityIdentifier("notifications-bell")
    .onChange(of: inbox.keys(items, store: store), initial: true) { _, keys in
      inbox.observe(keys, rows: rows, store: store)
    }
    .onChange(of: inbox.arrival) { flash() }
    .onDisappear { panel.hide() }
    #if DEBUG
    .onAppear { MacBellChecks.start(store: store, runtime: runtime, panel: panel) }
    #endif
  }

  private var list: some View {
    MacNotificationList(store: store, runtime: runtime) { panel.hide() }
      .environment(\.appTheme, theme).environment(\.colorScheme, theme.dark ? .dark : .light)
      .sessionRowTimeline()
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [panel] in panel.resize($0) }
  }

  /// Only over the window in use, with nothing presented over it; in the background the macOS notification speaks.
  private func flash() {
    #if DEBUG
    // The checks run without taking the keyboard from the Mac's user, so the app stays in the background.
    let inUse = MacBellChecks.arrival != nil || NSApp.isActive && runtime.window?.isKeyWindow == true
    #else
    let inUse = NSApp.isActive && runtime.window?.isKeyWindow == true
    #endif
    guard inUse, runtime.app.front === runtime, let window = runtime.window, window.attachedSheet == nil,
      NSApp.modalWindow == nil, !runtime.search.visible, runtime.modelPalette.panel?.isVisible != true,
      !inbox.fresh.isEmpty
    else { return }
    panel.flash(list)
  }
}

/// A borderless, nonactivating child panel under the bell. It cannot become key or main, so the composer keeps the
/// keyboard while it shows; clicks still reach its lines.
@MainActor final class MacBellPanel {
  enum Mode { case flash, pinned }
  private let panel = MacBellWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
  private let host = MacBellHost(rootView: AnyView(EmptyView()))
  weak var anchor: NSView?
  private(set) var mode: Mode?
  private var height: CGFloat?
  private var monitor: Any?
  private var closing: Task<Void, Never>?
  private var deactivation: NSObjectProtocol?

  var visible: Bool { panel.isVisible }
  var window: NSWindow { panel }

  init() {
    host.sizingOptions = []
    panel.contentView = host
    panel.identifier = NSUserInterfaceItemIdentifier("mac-notification-panel")
    panel.isReleasedWhenClosed = false
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
  }

  func toggle(_ content: some View) {
    if panel.isVisible && mode == .pinned { return hide() }
    show(content, mode: .pinned)
  }

  /// A few seconds, longer while the pointer is over it; a pinned list just shows the new lines.
  func flash(_ content: some View) {
    if panel.isVisible && mode == .pinned { return }
    show(content, mode: .flash)
    closing?.cancel()
    closing = Task { [weak self] in
      try? await Task.sleep(for: .seconds(4.5))
      while let self, !Task.isCancelled, self.hovered {
        try? await Task.sleep(for: .milliseconds(400))
      }
      guard !Task.isCancelled, let self, self.mode == .flash else { return }
      self.hide()
    }
  }

  func hide() {
    closing?.cancel()
    closing = nil
    mode = nil
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
    deactivation = nil
  }

  private var hovered: Bool { panel.isVisible && panel.frame.contains(NSEvent.mouseLocation) }

  private func show(_ content: some View, mode: Mode) {
    guard let anchor, let window = anchor.window else { return }
    if mode == .pinned {
      closing?.cancel()
      closing = nil
    }
    self.mode = mode
    if !panel.isVisible { host.rootView = AnyView(content) }
    if panel.parent !== window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    place(height: height ?? max(host.fittingSize.height, 120))
    panel.orderFront(nil)
    watch()
  }

  /// The list's own height, so the panel grows and shrinks from its top edge as lines come and go.
  func resize(_ height: CGFloat) {
    self.height = height
    if panel.isVisible { place(height: height) }
  }

  /// Top edge just under the bell, inside the window.
  private func place(height: CGFloat) {
    guard let anchor, let window = anchor.window, height > 0 else { return }
    let bell = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let width: CGFloat = 380
    let x = max(window.frame.minX + 8, min(bell.midX - width + 34, window.frame.maxX - width - 8))
    let frame = NSRect(x: x, y: bell.minY - 6 - height, width: width, height: height)
    if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
  }

  private func watch() {
    if monitor == nil {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
        guard let self else { return event }
        if event.type == .keyDown {
          // Esc closes a list opened by a click; a passing one leaves every key to the composer.
          guard event.keyCode == 53, self.mode == .pinned else { return event }
          self.hide()
          return nil
        }
        if event.window === self.panel {
          // A click inside keeps a passing list open.
          self.closing?.cancel()
          self.closing = nil
          self.mode = .pinned
          return event
        }
        if let anchor = self.anchor, event.window === anchor.window,
          anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow) { return event }
        self.hide()
        return event
      }
    }
    if deactivation == nil {
      deactivation = NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
    }
  }
}

private final class MacBellWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class MacBellHost: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MacBellAnchor: NSViewRepresentable {
  let panel: MacBellPanel
  func makeNSView(context: Context) -> NSView {
    let view = Marker()
    panel.anchor = view
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { panel.anchor = view }

  final class Marker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

private struct MacNotificationList: View {
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  let runtime: MacWindowRuntime
  let close: () -> Void

  private var inbox: MacAlertInbox { runtime.app.alertInbox }

  var body: some View {
    let rows = store.rows
    let unread = inbox.unread(rows, store: store)
    let earlier = inbox.earlier(rows, excluding: unread, store: store)
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Notificações").appFont(.secondary, weight: .semibold).foregroundStyle(theme.color(.textStrong))
        Spacer()
      }
      .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
      if unread.isEmpty && earlier.isEmpty {
        Text("Nenhuma notificação").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
          .frame(maxWidth: .infinity).padding(.vertical, 22)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if !unread.isEmpty {
              header("Não lidas") { EmptyView() }
              ForEach(unread) { row($0, read: false) }
            }
            if !earlier.isEmpty {
              header("Anteriores") {
                Button("Limpar") { inbox.clear(store) }.buttonStyle(.plain).appFont(.caption)
                  .foregroundStyle(theme.color(.textSecondary))
              }
              ForEach(earlier) { row($0, read: true) }
            }
          }
        }
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.bottom, 6)
    .frame(width: 380)
    .background(theme.color(.background))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 1) }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func header(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
    HStack {
      Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
        .foregroundStyle(theme.color(.textSecondary))
      Spacer()
      trailing()
    }
    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
  }

  private func row(_ item: MacAlertInbox.Item, read: Bool) -> some View {
    let highlighted = !read && inbox.fresh.contains(item.id)
    return HStack(spacing: 10) {
      Button {
        close()
        inbox.open(item, store: store, runtime: runtime)
      } label: {
        HStack(spacing: 10) {
          MacPromptAvatar(avatar: MacTranscriptAvatar(item.row, mixChats: !store.chatsSelected, master: false), size: 20)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(item.row.session.displayTitle + " · " + kind(item)).appFont(.caption, weight: read ? .regular : .semibold)
                .foregroundStyle(theme.color(.textStrong)).lineLimit(1)
              Spacer(minLength: 4)
              SessionRowTime(at: item.row.interactionAt, unread: !read && item.row.unread)
            }
            Text(detail(item)).appFont(.footnote).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      actions(item)
      if item.row.unread && !read { Circle().fill(theme.color(.primary)).frame(width: 8, height: 8) }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(theme.color(.primary).opacity(highlighted ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
    .padding(.horizontal, 4)
    .opacity(read ? 0.6 : 1)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(item.row.session.displayTitle + ", " + kind(item) + (read ? "" : ", não lida"))
  }

  @ViewBuilder private func actions(_ item: MacAlertInbox.Item) -> some View {
    switch item.kind {
    case .permission(let request):
      HStack(spacing: 6) {
        Button("Negar") { reply(request, row: item.row, allow: false) }
        Text("·").foregroundStyle(theme.color(.textWeak))
        Button("Permitir") { reply(request, row: item.row, allow: true) }
      }
      .buttonStyle(.plain).appFont(.caption, weight: .medium).foregroundStyle(theme.color(.primary))
      .disabled(store.busy.contains(item.row.id))
    case .question:
      Button("Responder") {
        close()
        inbox.open(item, store: store, runtime: runtime)
      }
      .buttonStyle(.plain).appFont(.caption, weight: .medium).foregroundStyle(theme.color(.primary))
    default:
      EmptyView()
    }
  }

  private func kind(_ item: MacAlertInbox.Item) -> String {
    switch item.kind {
    case .permission: "pede permissão"
    case .question: "pergunta"
    case .failed: "terminou com erro"
    case .running: "trabalhando"
    case .replied: "respondeu"
    }
  }

  private func detail(_ item: MacAlertInbox.Item) -> String {
    switch item.kind {
    case .permission(let request): request.resources.first ?? request.message ?? request.preview
    case .question(let form): form.preview
    default: inbox.detail(item, store: store) ?? (item.row.unread ? "Nova resposta" : item.row.projectName)
    }
  }

  private func reply(_ request: PermissionRequest, row: SessionRow, allow: Bool) {
    Task {
      if store.permission(row)?.id == request.id { return await store.reply(row, allow: allow) }
      try? await store.client.reply(request, allow: allow)
      await store.reload()
    }
  }
}
