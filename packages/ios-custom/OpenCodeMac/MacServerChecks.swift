#if DEBUG
import AppKit
import OpenCodeKit
import SwiftUI

/// The rail's server switch in the closed fixture: `-OpenCodeMacServers <n>` replaces the saved servers with `n`
/// fake ones held in memory (never the app's defaults or the Keychain), and `-OpenCodeMacAjustes servidores` drives
/// the avatar, its menu, the voice confirmation, Ir ▸ Servidores with ⌃⌘2 and the rail with one server left.
/// Every switch rebuilds the same fixture: only the saved servers change.
@MainActor enum MacServerChecks {
  /// Overrides the voice call the switch asks about, and the connection the avatar shows (the fixture has no event
  /// stream, so it stays "Conectando…"). Observed, so the avatar redraws when a step changes them.
  @Observable final class Overrides {
    var callActive: Bool?
    var connection: ServerSwitcher.Connection?
  }
  static let overrides = Overrides()
  static var callActive: Bool? { overrides.callActive }
  static var connection: ServerSwitcher.Connection? { overrides.connection }
  /// The check in progress. It ends the run itself; a window the switch rebuilt waits for it instead.
  private(set) static var pending: Task<Void, Never>?

  static func servers() -> ServerStore? {
    guard MacLaunch.fixture, let count = MacFixture.value("-OpenCodeMacServers").flatMap(Int.init), count > 0
    else { return nil }
    let fake = [("host6", "host-6 · produção", "http://host-6.interno:4096"), ("sandbox", "Sandbox", "http://127.0.0.1:4199")]
      .prefix(count - 1).map { #"{"id":"\#($0.0)","name":"\#($0.1)","url":"\#($0.2)"}"# }
    let defaults = MacServerDefaults(values: [
      "OpenCodeServers": Data(("[" + fake.joined(separator: ",") + "]").utf8),
      "OpenCodeServers.builtinName": "Mac de Alexandre",
    ])
    return ServerStore(defaults: defaults, credentials: ServerCredentials(backend: MacServerCredentials()),
      builtinURL: MacRuntime.localURL)
  }

  /// Runs outside the window's own task, since the switch replaces the window's views and cancels that task, and
  /// ends the process itself: the capture of the rebuilt window would otherwise finish the run first.
  static func run(window: NSWindow, theme: AppTheme, folder: String) async {
    func shot(_ step: String) { MacCapture.shot(window, theme: theme, to: folder + "/\(MacCapture.name)-\(step).png") }
    let task = Task { @MainActor in
      do {
        try await check(window: window, shot: shot)
        print("MacAjustes servidores ok")
        fflush(stdout)
        exit(0)
      } catch {
        shot("falha")
        print("MacAjustes servidores failed: \(error) · app ativo \(NSApp.isActive)")
        fflush(stdout)
        exit(1)
      }
    }
    pending = task
    await task.value
  }

  private static func check(window: NSWindow, shot: (String) -> Void) async throws {
    let app = MacRuntime.shared
    let servers = app.servers
    let overrides = overrides
    func front() throws -> MacWindowRuntime {
      try require(app.windows.values.first { $0.window === window }, "janela")
    }
    try expect(servers.servers.map(\.title) == ["Mac de Alexandre", "host-6 · produção", "Sandbox"],
      "servidores falsos: \(servers.servers.map(\.title))")
    overrides.connection = .connected
    // Closed: the avatar under Ajustes, the menu hidden.
    try await wait("avatar do servidor conectado (\(MacServerButton.shown ?? "ausente"))") {
      MacServerButton.shown == "Servidor Mac de Alexandre, conectado" ? true : nil
    }
    try await Task.sleep(for: .milliseconds(500))
    shot("fechada")

    // Open: upward from the avatar, beside the rail; it never takes the keyboard.
    NotificationCenter.default.post(name: MacServerButton.openRequest, object: nil)
    let menu = try await wait("menu aberto") { MacServerMenu.shown.flatMap { $0.visible ? $0 : nil } }
    let rows = try await wait("linhas do menu") { MacServerMenuList.shown.isEmpty ? nil : MacServerMenuList.shown }
    try expect(rows == [
      "✓ MA Mac de Alexandre · 127.0.0.1:4096 · Conectado · ⌃⌘1",
      "H6 host-6 · produção · host-6.interno:4096 · ⌃⌘2",
      "SA Sandbox · 127.0.0.1:4199 · ⌃⌘3",
      "Gerenciar servidores… ⌘,", "Adicionar servidor…",
    ], "linhas: \(rows)")
    let anchor = try require(menu.anchor, "âncora do avatar")
    let tile = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let panel = menu.window.frame
    try expect(abs(panel.minY - tile.minY) < 1 && panel.maxY > tile.maxY + 60 && panel.minX >= tile.maxX,
      "menu fora do lugar: \(NSStringFromRect(panel)) avatar \(NSStringFromRect(tile))")
    try expect(!menu.window.canBecomeKey && !menu.window.isKeyWindow, "o menu tomou o teclado")
    try await Task.sleep(for: .milliseconds(400))
    shot("menu")
    print("MacAjustes servidores menu: " + rows.joined(separator: " | "))
    // Esc closes it, through the app's event queue like a key press.
    NSApp.postEvent(key("\u{1b}", code: 53, window: window), atStart: false)
    try await wait("Esc fechou o menu") { menu.visible ? nil : true }

    // With a voice call, choosing another server asks first; Cancelar keeps the server.
    overrides.callActive = true
    NotificationCenter.default.post(name: MacServerButton.openRequest, object: nil)
    try await wait("menu reaberto") { menu.visible ? true : nil }
    menu.choose(.server("host6"))
    let alert = try await wait("confirmação") { window.attachedSheet }
    try expect(!menu.visible && servers.activeID == "builtin", "trocou sem confirmar")
    try await Task.sleep(for: .milliseconds(600))
    shot("confirmacao")
    _ = alert.performKeyEquivalent(with: key("\u{1b}", code: 53, window: alert))
    try await wait("Cancelar fechou a confirmação") {
      window.attachedSheet == nil && (try? front().serverRequest) == nil ? true : nil
    }
    try expect(servers.activeID == "builtin" && app.appliedRevision == servers.revision, "Cancelar trocou")
    overrides.callActive = nil

    // A draft typed before the switch, to find again after it.
    let draft = try front().input(try require(app.store?.liveConversation(MacFixture.rootID), "conversa")).draft
    try await wait("compositor") { draft.input?.window != nil ? true : nil }
    draft.text = NSAttributedString(string: "Rascunho antes da troca")
    let session = try front().selection.sessionID
    try await Task.sleep(for: .milliseconds(700))

    // Ir ▸ Servidores and ⌃⌘2, which SwiftUI fills only for the active app: the copy comes forward for this part.
    if MacLaunch.background {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
    window.makeKeyAndOrderFront(nil)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    let items = try await wait("Ir ▸ Servidores") { serverItems().count == 3 ? serverItems() : nil }
    try expect(items.map(\.title) == ["Mac de Alexandre", "host-6 · produção", "Sandbox"]
      && items.map(\.keyEquivalent) == ["1", "2", "3"]
      && items.allSatisfy { $0.keyEquivalentModifierMask == [.control, .command] }
      && items.map(\.state) == [.on, .off, .off],
      "Ir ▸ Servidores: \(items.map { "\($0.title) \($0.keyEquivalent) \($0.state.rawValue)" })")
    overrides.connection = nil
    _ = NSApp.mainMenu?.performKeyEquivalent(with: key("2", code: 19, flags: [.control, .command], window: window))
    try await wait("⌃⌘2 escolheu host-6") { servers.activeID == "host6" ? true : nil }
    try await Task.sleep(for: .milliseconds(150))
    shot("trocando")
    try await wait("janela recarregada em host-6", timeout: 15) {
      app.appliedRevision == servers.revision && MacServerButton.shown?.hasPrefix("Servidor host-6") == true
        ? true : nil
    }
    try await Task.sleep(for: .milliseconds(600))
    shot("conectando")
    let rebuilt = try front()
    try expect(rebuilt.selection.sessionID == session, "a janela não voltou à sessão: \(rebuilt.selection.sessionID ?? "-")")
    let restored = rebuilt.input(try require(app.store?.liveConversation(MacFixture.rootID), "conversa")).draft
    try await wait("rascunho de volta") { restored.text.string == "Rascunho antes da troca" ? true : nil }
    overrides.connection = .connected
    try await Task.sleep(for: .milliseconds(500))
    shot("trocado")
    overrides.connection = .disconnected
    try await Task.sleep(for: .milliseconds(500))
    shot("desconectado")
    overrides.connection = .connected
    restored.text = NSAttributedString()
    try await Task.sleep(for: .milliseconds(700))
    try expect(UserDefaults.standard.object(forKey: "OpenCodeServers") == nil
      && UserDefaults.standard.object(forKey: "OpenCodeServers.active") == nil,
      "os servidores falsos foram gravados nos ajustes do app")

    // One server left: the avatar and Ir ▸ Servidores go away and the rail is as before.
    try servers.remove("sandbox")
    try servers.remove("host6")
    try await wait("sem avatar com um servidor", timeout: 15) {
      app.appliedRevision == servers.revision && app.windows.values.contains { $0.window === window }
        && MacServerButton.shown == nil ? true : nil
    }
    try await Task.sleep(for: .seconds(1.5))
    try expect(MacServerButton.shown == nil && serverItems().isEmpty, "controle visível com um servidor")
    shot("um-servidor")
    // The window's draft and reading place, written to this Mac's Application Support under the fixture's key.
    let key = try require(app.store, "sessões").client.configuration.url.absoluteString + "#window=" + front().id.uuidString
    try? FileManager.default.removeItem(at: DraftPersistence(server: key, sessionID: MacFixture.rootID).directory
      .deletingLastPathComponent())
    try? FileManager.default.removeItem(at: ReadingPositionStore(server: key).file)
    print("MacAjustes servidores: menu, Esc, confirmação com voz, ⌃⌘2, sessão e rascunho de volta, um servidor sem avatar")
  }

  /// Ir ▸ Servidores' items, once SwiftUI filled the menu.
  private static func serverItems() -> [NSMenuItem] {
    guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Ir" })?.submenu else { return [] }
    menu.delegate?.menuNeedsUpdate?(menu)
    return menu.items.filter { $0.keyEquivalentModifierMask == [.control, .command] && Int($0.keyEquivalent) != nil }
  }

  private static func key(_ character: String, code: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow)
    -> NSEvent
  {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
  }

  private static func expect(_ condition: Bool, _ what: String) throws {
    if !condition { throw MacAjustesChecks.Failure(description: what) }
  }

  private static func require<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw MacAjustesChecks.Failure(description: "sem \(what)") }
    return value
  }

  @discardableResult
  private static func wait<T>(_ what: String, timeout: Double = 8, _ value: () -> T?) async throws -> T {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if let value = value() { return value }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MacAjustesChecks.Failure(description: "tempo esgotado: \(what)")
  }
}

/// The fake servers' defaults, in memory: `ServerStore` reads and writes through `object(forKey:)` and
/// `set(_:forKey:)`, so the app's domain never sees them.
private final class MacServerDefaults: UserDefaults, @unchecked Sendable {
  private var values: [String: Any] = [:]
  convenience init(values: [String: Any]) {
    self.init(suiteName: nil)!
    self.values = values
  }
  override func object(forKey defaultName: String) -> Any? { values[defaultName] }
  override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
  override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
  override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
  override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
}

/// No Keychain for the fake servers.
private final class MacServerCredentials: CredentialBackend {
  private var values: [String: Data] = [:]
  func read(_ account: String) throws -> Data? { values[account] }
  func write(_ data: Data?, account: String) throws { values[account] = data }
}
#endif
