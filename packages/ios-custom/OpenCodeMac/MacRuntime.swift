import Observation
import OpenCodeKit
import SwiftUI

/// App-wide state of the Mac app: the server, the appearance, the Sessões store and what the window shows.
@MainActor @Observable final class MacRuntime {
  static let shared = MacRuntime()
  /// The Mac app talks to this Mac's own server by default; Configurações can point it elsewhere.
  static let localURL = URL(string: "http://127.0.0.1:4096")!

  let servers = ServerStore(launchOverride: .override(), builtinURL: MacRuntime.localURL)
  let appearance = AppearanceSettings()
  let audio = MacVoiceSession()
  var store: SessionStore?
  var identity = UUID()
  var appliedRevision = -1
  var error: String?
  /// The third column (Contexto) can be hidden; the choice survives relaunches.
  var contextVisible = UserDefaults.standard.object(forKey: "OpenCodeMacContextVisible") as? Bool ?? true {
    didSet { UserDefaults.standard.set(contextVisible, forKey: "OpenCodeMacContextVisible") }
  }
  var selection = MacSelection() {
    didSet {
      syncShown()
      if let store, !MacLaunch.fixture { MacSelection.save(selection, server: store.client.configuration.url) }
    }
  }

  /// The session on screen stays silent only while the app is in front; in the background its alerts become
  /// notifications too.
  func syncShown() {
    store?.shownSessionID = NSApp.isActive ? selection.childID ?? selection.sessionID : nil
  }
  /// The Sessões column's selection mode (⌘-click or Selecionar), with its batch actions.
  var sessionSelection = SessionSelection()
  /// A batch action asked from the menu bar, carried out by the Sessões column.
  var bulkRequest: MacBulkRequest?
  /// The Nova sessão sheet: from Sessões, from a session (inheriting its checkout and model) or for the master.
  var newSessionRequest: MacNewSessionRequest?
  /// The title bar's `…` and the Sessão menu ask the chat column to rename or delete the selected session.
  var renameRequest: SessionRow?
  var deleteRequest: Session?
  /// The title's quick switcher (⌘K or a click on the title).
  var switcherVisible = false
  /// Archiving from the `…` or the Sessão menu asks for confirmation in the window.
  var archiveRequest: SessionRow?
  /// What the LLM proxy window shows; a quota ring sets its provider before opening it.
  var proxyPane: SubscriptionPane? = MacProxyLaunch.pane ?? .provider(.codex)
  @ObservationIgnored private var building: Task<Void, Never>?

  func prepare() async {
    if let building { await building.value }
    guard store == nil || appliedRevision != servers.revision else { return }
    let task = Task { await rebuild() }
    building = task
    await task.value
    building = nil
  }

  private func rebuild() async {
    await audio.stop()
    await store?.stop()
    sessionSelection = SessionSelection()
    newSessionRequest = nil
    do {
      #if DEBUG
      if ScrollFixtures.mode == "conversation" {
        // The iPhone's offline scroll fixture: no server, the shared store loads the bundled conversation.
        let next = SessionStore(configuration: MacFixture.configuration, acceptsLaunchSession: false,
          client: .inMemory(configuration: MacFixture.configuration, answer: { _ in nil }))
        ScrollFixtures.prepare(next)
        store = next
        selection = MacSelection(sessionID: ScrollFixtures.sessionID)
        appliedRevision = servers.revision
        identity = UUID()
        return
      }
      if let fixture = MacFixture.current {
        let client = fixture.client()
        store = SessionStore(configuration: MacFixture.configuration, acceptsLaunchSession: false, client: client,
          draftRoot: MacVoiceChecks.enabled ? MacFixture.value("-OpenCodeMacDraftRoot").map { URL(fileURLWithPath: $0) } : nil)
        if let store { MacVoiceChecks.prepare(store) }
        // The fixture has no resource hub: the viewer shows the drawn snapshot as its live frame.
        ResourceViewerModel.fixtureFrame = { resource in
          guard let data = try? await client.resourceSnapshot(resource.id, maxWidth: 1200).image else { return nil }
          return NSImage(data: data)
        }
        selection = fixture.selection
        appliedRevision = servers.revision
        identity = UUID()
        return
      }
      #endif
      let configuration = try servers.configuration()
      store = SessionStore(configuration: configuration, acceptsLaunchSession: false)
      selection = MacSelection.saved(server: configuration.url) ?? MacSelection()
      appliedRevision = servers.revision
      identity = UUID()
      error = nil
    } catch {
      store = nil
      self.error = error.localizedDescription
    }
  }

  /// The selected root session's row, when it is one of Sessões' rows (the master is not).
  var selectedRow: SessionRow? { store?.rows.first { $0.id == selection.sessionID } }

  func showFiles(at path: String? = nil, file: String? = nil) {
    contextVisible = true
    selection.files = MacSelection.Files(folder: path, file: file)
  }

  /// Nova sessão from Sessões (the chip filter decides the project, like the iPhone's `+`).
  func newSession() {
    newSessionRequest = MacNewSessionRequest(origin: nil, startInChats: true)
  }

  /// Nova sessão from a session: its project, checkout and model, like the iPhone's conversation menu.
  func newSession(from id: String) {
    guard let store, let session = store.rows.first(where: { $0.id == id })?.session else { return newSession() }
    let origin = NewSessionOrigin(
      session: session, projects: store.projects, chatRoot: store.chatRoot, model: session.model)
    newSessionRequest = MacNewSessionRequest(origin: origin, startInChats: false)
  }

  /// The current master in the middle column, or Nova sessão in its master mode when there is none yet.
  func openMaster() {
    guard let store, store.masterAvailability == .available else { return }
    if let id = store.masterID {
      selection = MacSelection(sessionID: id, master: true)
      Task { await store.verifyMaster() }
      return
    }
    newSessionRequest = MacNewSessionRequest(origin: nil, startInChats: false, master: true)
  }

  /// From a subagent back to the session that started it (⌘[ or the chat's `‹`): its parent subagent, else the root.
  func backToParent() {
    guard let child = selection.childID else { return }
    let parent = store?.liveConversation(child)?.session?.parentID
    selection.childID = parent == nil || parent == selection.sessionID ? nil : parent
  }

  /// The previous or next row of Sessões, in the order the column shows them (⌥⌘↑ and ⌥⌘↓).
  func selectNeighbor(_ offset: Int) {
    guard let store else { return }
    let ids = SessionSections.group(store.filtered, chats: store.chatsSelected, now: .now).flatMap(\.rows).map(\.id)
    if let next = SessionNavigation.neighbor(ids, current: selection.sessionID, offset: offset) {
      selection = MacSelection(sessionID: next)
    }
  }
}

enum MacBulkRequest: Equatable { case selectAll, archive, delete }

struct MacNewSessionRequest: Identifiable {
  let id = UUID()
  let origin: NewSessionOrigin?
  let startInChats: Bool
  var master = false
}

/// Launch flags the Mac reads once.
enum MacLaunch {
  static let fixture = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacFixture")
}

/// What the window shows: the selected root session, a subagent opened from Contexto in the middle column,
/// and the Arquivos view over the Contexto column.
struct MacSelection: Equatable, Codable {
  struct Files: Equatable, Codable {
    /// The folder shown; nil opens the session's checkout root.
    var folder: String?
    /// The file selected in the list and shown below it.
    var file: String?
  }
  var sessionID: String?
  /// A subagent of `sessionID` opened in the middle column.
  var childID: String?
  var files: Files?
  /// The selected session is the Sessão mestra (it is not one of Sessões' rows).
  var master = false

  /// The window reopens on the session (and subagent, and Arquivos) it showed, per server.
  static func saved(server: URL) -> MacSelection? {
    UserDefaults.standard.data(forKey: key(server)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
  }

  static func save(_ selection: MacSelection, server: URL) {
    UserDefaults.standard.set(try? JSONEncoder().encode(selection), forKey: key(server))
  }

  private static func key(_ server: URL) -> String { "OpenCodeMacSelection." + server.absoluteString }
}
