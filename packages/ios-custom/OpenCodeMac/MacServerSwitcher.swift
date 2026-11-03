import AppKit
import OpenCodeKit
import SwiftUI

extension MacRuntime {
  /// The server title's menu and ⌃⌘1…⌃⌘9: Ajustes' "Usar" (`ServerStore.select`, then `rebuild`: every window
  /// reloads on the session it showed on that server, drafts kept). While a voice call is on, `window` asks first,
  /// since the switch ends it.
  func requestServer(_ id: String, from window: MacWindowRuntime) {
    guard id != servers.activeID, let server = servers.servers.first(where: { $0.id == id }) else { return }
    if callActive {
      window.serverRequest = server
      return
    }
    switchServer(server, from: window)
  }

  func switchServer(_ server: SavedServer, from window: MacWindowRuntime) {
    do { try servers.select(server.id) } catch {
      window.store?.toast.show("Não foi possível trocar de servidor. " + error.localizedDescription, kind: .error)
    }
  }

  var callActive: Bool {
    #if DEBUG
    if let active = MacServerChecks.callActive { return active }
    #endif
    return audio.voice.sessionID != nil
  }

  var serverConnection: ServerSwitcher.Connection {
    #if DEBUG
    if let connection = MacServerChecks.connection { return connection }
    #endif
    return ServerSwitcher.Connection(connected: store?.connected == true, failed: store?.error != nil || error != nil)
  }
}

enum MacServerMenuAction: Equatable { case server(String), manage, add }

/// The current server where Sessões' title would be, in the session column's title bar (approved option B, 3
/// November; it replaces the avatar that sat at the foot of the project rail): its avatar with the connection dot,
/// its name and a chevron, with every saved server count, one included. A click opens `MacServerMenu` below it.
/// While the column selects sessions, its batch actions take the room and the title keeps only the avatar.
struct MacServerTitle: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openSettings) private var openSettings
  let runtime: MacWindowRuntime
  /// The room left beside voice and Nova sessão.
  let width: CGFloat
  var avatarOnly = false
  /// Another server needs Alexandre: the other servers' state (stage 2, each one's `custom.live-activity`
  /// snapshot) sets it; nothing does yet.
  var othersNeedYou = false
  @State private var menu = MacServerMenu()
  #if DEBUG
  static let openRequest = Notification.Name("MacServerTitle.open")
  /// What the title shows, for the checks: the background copy builds no accessibility tree.
  static var shown: String?
  #endif

  var body: some View {
    let servers = runtime.app.servers
    let entry = ServerSwitcher.entries(servers.servers, activeID: servers.activeID).first(where: \.active)
    let connection = runtime.app.serverConnection
    let label = "Servidor \(servers.active.title), \(connection.label.lowercased())"
    Button { menu.toggle(list) } label: {
      Group {
        if let entry {
          if avatarOnly {
            ServerAvatar(entry: entry, size: 20, dot: connection.role)
          } else {
            SessionServerTitle(entry: entry, connection: connection, compact: true, othersNeedYou: othersNeedYou)
          }
        }
      }
      .padding(.horizontal, 6).padding(.vertical, 3)
      .frame(maxWidth: avatarOnly ? nil : width, alignment: .leading)
      .fixedSize(horizontal: avatarOnly, vertical: false)
      .contentShape(Rectangle())
      .background(MacServerMenuAnchor(menu: menu))
    }
    .buttonStyle(.plain)
    .help("\(servers.active.title) · \(connection.label) · trocar de servidor")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label + (othersNeedYou ? ", outro servidor precisa de você" : ""))
    .accessibilityHint("Abre a lista de servidores")
    .accessibilityIdentifier("sessions-server")
    .onAppear { menu.perform = perform }
    .onDisappear { menu.hide() }
    #if DEBUG
    .onAppear { Self.shown = label }
    .onChange(of: label) { Self.shown = label }
    .onDisappear { Self.shown = nil }
    .onReceive(NotificationCenter.default.publisher(for: Self.openRequest)) { _ in
      if !menu.visible { menu.toggle(list) }
    }
    #endif
  }

  private var list: some View {
    MacServerMenuList(runtime: runtime, choose: menu.choose)
      .environment(\.appTheme, theme).environment(\.colorScheme, theme.dark ? .dark : .light)
  }

  private func perform(_ action: MacServerMenuAction) {
    switch action {
    case .server(let id): runtime.app.requestServer(id, from: runtime)
    case .manage, .add:
      if action == .add { runtime.app.addingServer = true }
      UserDefaults.standard.set("servidores", forKey: "OpenCodeMacSettingsTab")
      openSettings()
    }
  }
}

/// The server menu: a borderless, nonactivating child panel under the server title, aligned with its leading edge,
/// like the bell's list (`MacBellPanel`). It never takes the keyboard; Esc, a click outside or a choice closes it.
@MainActor final class MacServerMenu {
  #if DEBUG
  /// The open menu, for the checks.
  static weak var shown: MacServerMenu?
  #endif
  private let panel = MacServerMenuWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
  private let host = MacServerMenuHost(rootView: AnyView(EmptyView()))
  weak var anchor: NSView?
  var perform: (MacServerMenuAction) -> Void = { _ in }
  private var monitor: Any?
  private var deactivation: NSObjectProtocol?

  var visible: Bool { panel.isVisible }
  var window: NSWindow { panel }

  init() {
    host.sizingOptions = []
    panel.contentView = host
    panel.identifier = NSUserInterfaceItemIdentifier("mac-server-menu")
    panel.isReleasedWhenClosed = false
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
  }

  func toggle(_ content: some View) {
    if panel.isVisible { return hide() }
    show(content)
  }

  /// What a row does: the menu closes first, so a confirmation or Ajustes opens over a clear window.
  func choose(_ action: MacServerMenuAction) {
    hide()
    perform(action)
  }

  func hide() {
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    // A fresh list on the next opening, with the servers and the connection of that moment.
    host.rootView = AnyView(EmptyView())
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
    deactivation = nil
  }

  private func show(_ content: some View) {
    guard let anchor, let window = anchor.window else { return }
    host.rootView = AnyView(content)
    if panel.parent !== window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    // The host has no sizing options (it must not resize the panel), so its fitting size is zero: measure the list.
    let size = NSHostingController(rootView: content).sizeThatFits(in: CGSize(width: 300, height: 2000))
    let tile = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    // Just under the title, opening downward; never past the window's foot.
    let y = max(tile.minY - 4 - size.height, window.frame.minY + 8)
    panel.setFrame(NSRect(x: tile.minX, y: y, width: size.width, height: size.height), display: false)
    panel.orderFront(nil)
    #if DEBUG
    Self.shown = self
    #endif
    watch()
  }

  private func watch() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
      guard let self else { return event }
      if event.type == .keyDown {
        guard event.keyCode == 53 else { return event }
        self.hide()
        return nil
      }
      if event.window === self.panel { return event }
      // The title's own click toggles it.
      if let anchor = self.anchor, event.window === anchor.window,
        anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow) { return event }
      self.hide()
      return event
    }
    deactivation = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
  }
}

private final class MacServerMenuWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class MacServerMenuHost: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MacServerMenuAnchor: NSViewRepresentable {
  let menu: MacServerMenu
  func makeNSView(context: Context) -> NSView {
    let view = Marker()
    menu.anchor = view
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { menu.anchor = view }

  final class Marker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// The saved servers in Ajustes' order, the current one checked with its connection (the others' state needs
/// connections of their own, stage 2), their ⌃⌘ shortcuts, then Gerenciar servidores… and Adicionar servidor….
struct MacServerMenuList: View {
  @Environment(\.appTheme) private var theme
  let runtime: MacWindowRuntime
  let choose: (MacServerMenuAction) -> Void
  #if DEBUG
  /// The rows as shown, for the checks.
  static var shown: [String] = []
  #endif

  var body: some View {
    let servers = runtime.app.servers
    let entries = ServerSwitcher.entries(servers.servers, activeID: servers.activeID)
    let connection = runtime.app.serverConnection
    let detail = { (entry: ServerSwitcher.Entry) in entry.active ? entry.address + " · " + connection.label : entry.address }
    VStack(alignment: .leading, spacing: 1) {
      Text("SERVIDORES").font(.system(size: 10, weight: .semibold)).tracking(0.8)
        .foregroundStyle(theme.color(.textSecondary)).padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 5)
      ForEach(entries) { entry in
        MacServerMenuRow(action: { choose(.server(entry.id)) }) {
          HStack(spacing: 9) {
            ServerAvatar(entry: entry, size: 26)
            VStack(alignment: .leading, spacing: 1) {
              Text(entry.server.title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.color(.textStrong)).lineLimit(1)
              Text(detail(entry)).font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary))
                .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if entry.active {
              Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color(.primary))
            }
            if let shortcut = entry.shortcut { caps("⌃⌘\(shortcut)") }
          }
        }
        .accessibilityLabel(entry.server.title + (entry.active ? ", atual, " + connection.label.lowercased() : ""))
        .accessibilityAddTraits(entry.active ? .isSelected : [])
      }
      Rectangle().fill(theme.color(.border)).frame(height: 0.7).padding(.horizontal, 6).padding(.vertical, 5)
      MacServerMenuRow(action: { choose(.manage) }) {
        HStack {
          Text("Gerenciar servidores…").font(.system(size: 13)).foregroundStyle(theme.color(.text))
          Spacer()
          caps("⌘,")
        }
      }
      MacServerMenuRow(action: { choose(.add) }) {
        Text("Adicionar servidor…").font(.system(size: 13)).foregroundStyle(theme.color(.text))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Text("Trocar recarrega todas as janelas").font(.system(size: 10.5)).foregroundStyle(theme.color(.textWeak))
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }
    .padding(6)
    .frame(width: 300, alignment: .leading)
    .background(theme.color(.surfaceRaised), in: RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 0.7) }
    .fixedSize(horizontal: false, vertical: true)
    #if DEBUG
    .onAppear { Self.shown = report(entries, detail: detail) }
    .onChange(of: report(entries, detail: detail)) { _, rows in Self.shown = rows }
    .onDisappear { Self.shown = [] }
    #endif
  }

  private func caps(_ text: String) -> some View {
    Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.color(.textSecondary))
      .padding(.horizontal, 5).frame(minHeight: 18)
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 4))
      .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(theme.color(.border), lineWidth: 0.7) }
  }

  #if DEBUG
  private func report(_ entries: [ServerSwitcher.Entry], detail: (ServerSwitcher.Entry) -> String) -> [String] {
    entries.map { entry in
      (entry.active ? "✓ " : "") + entry.initials + " " + entry.server.title + " · " + detail(entry)
        + (entry.shortcut.map { " · ⌃⌘\($0)" } ?? "")
    } + ["Gerenciar servidores… ⌘,", "Adicionar servidor…"]
  }
  #endif
}

/// A menu line: the whole width clicks, highlighted under the pointer like a native menu item.
private struct MacServerMenuRow<Content: View>: View {
  @Environment(\.appTheme) private var theme
  let action: () -> Void
  @ViewBuilder let content: Content
  @State private var hovered = false
  var body: some View {
    Button(action: action) {
      content.padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(.primary).opacity(hovered ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
  }
}

/// Asks before a switch would end the voice call (`MacRuntime.requestServer`), as the window's own alert.
struct MacServerConfirmation: ViewModifier {
  @Bindable var runtime: MacWindowRuntime
  func body(content: Content) -> some View {
    content.alert("Trocar para \(runtime.serverRequest?.title ?? "outro servidor")?", isPresented: Binding(
      get: { runtime.serverRequest != nil }, set: { if !$0 { runtime.serverRequest = nil } }),
      presenting: runtime.serverRequest
    ) { server in
      Button("Trocar") {
        runtime.serverRequest = nil
        runtime.app.switchServer(server, from: runtime)
      }
      Button("Cancelar", role: .cancel) { runtime.serverRequest = nil }
    } message: { server in
      Text("A conversa por voz será encerrada. As janelas trocam juntas e cada uma volta à sessão que mostrava em \(server.title).")
    }
  }
}
