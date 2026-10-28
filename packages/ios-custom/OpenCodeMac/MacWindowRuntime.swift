import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// Presentation belongs to a window. Services, including the single voice call, belong to `app`.
@MainActor @Observable final class MacWindowRuntime {
  let app: MacRuntime
  let id: UUID
  let reading: ReadingPositionStore
  let drafts: ConversationDrafts
  let voicePresentation = FloatingVoicePresentation()
  weak var window: NSWindow?
  var state: DesktopWindowState {
    didSet {
      app.syncShown()
      guard let store, !MacLaunch.fixture else { return }
      state.save(window: id, server: store.client.configuration.url, defaults: .standard)
    }
  }
  var selection: MacSelection {
    get { state.selection }
    set { state.selection = newValue }
  }
  var contextVisible: Bool {
    get { state.contextVisible }
    set { state.contextVisible = newValue }
  }
  var contextWidth: Double {
    get { state.contextWidth }
    set { state.contextWidth = newValue }
  }
  var columns: NavigationSplitViewVisibility {
    get { state.sidebarVisible ? .all : .detailOnly }
    set { state.sidebarVisible = newValue != .detailOnly }
  }
  var store: SessionStore? { app.store }
  var proxyPane: SubscriptionPane? {
    get { app.proxyPane }
    set { app.proxyPane = newValue }
  }
  var sessionSelection = SessionSelection()
  var bulkRequest: MacBulkRequest?
  var newSessionRequest: MacNewSessionRequest?
  var renameRequest: SessionRow?
  var deleteRequest: Session?
  /// The title's old switcher popover is gone (⌘K replaces it); the search presentation still resets this flag.
  var switcherVisible = false
  let search: MacSearch
  let modelPalette = MacModelPalette()
  var newSessionPalette: (() -> Void)?
  var archiveRequest: SessionRow?
  /// The widths the columns got in the last layout, for checks (not observed).
  @ObservationIgnored var measuredContextWidth: CGFloat = 0
  @ObservationIgnored var measuredChatWidth: CGFloat = 0
  @ObservationIgnored private var memories: [String: TranscriptMemory] = [:]
  @ObservationIgnored private var recent: [String] = []
  @ObservationIgnored private var inputs: [String: MacConversationInput] = [:]

  init(app: MacRuntime, id: UUID, selection: MacSelection? = nil) {
    self.app = app
    self.id = id
    search = MacSearch { [weak app] in app?.store }
    let server = app.store!.client.configuration.url
    #if DEBUG
    let root = MacVoiceChecks.enabled ? MacFixture.value("-OpenCodeMacDraftRoot").map { URL(fileURLWithPath: $0) } : nil
    #else
    let root: URL? = nil
    #endif
    drafts = ConversationDrafts(server: server.absoluteString + "#window=" + id.uuidString, root: root)
    #if DEBUG
    // The scroll benchmark seeds a precise initial anchor in the fixture's store.
    reading = ScrollFixtures.mode == nil
      ? ReadingPositionStore(server: server.absoluteString + "#window=" + id.uuidString) : app.store!.reading
    #else
    reading = ReadingPositionStore(server: server.absoluteString + "#window=" + id.uuidString)
    #endif
    var restored = MacLaunch.fixture ? DesktopWindowState() : DesktopWindowState.load(window: id, server: server, defaults: .standard)
    if let selection { restored.selection = selection }
    #if DEBUG
    if let width = MacFixture.value("-OpenCodeMacContextWidth").flatMap(Double.init) {
      restored.contextWidth = max(width, DesktopWindowState.minimumContextWidth)
    }
    #endif
    state = restored
  }

  func memory(_ id: String) -> TranscriptMemory {
    recent.removeAll { $0 == id }
    recent.append(id)
    if let memory = memories[id] { return memory }
    let memory = TranscriptMemory()
    memories[id] = memory
    // Match the conversation registry's small cache, retaining the root and the child over it.
    let shown = [selection.sessionID, selection.childID].compactMap { $0 }
    for old in recent.dropLast(5) where !shown.contains(old) {
      memories[old]?.controller = nil
      memories[old] = nil
    }
    recent.removeAll { memories[$0] == nil }
    return memory
  }

  func close() {
    modelPalette.close()
    search.visible = false
    inputs.values.forEach { $0.readAloud.stop() }
    let drafts = drafts
    Task { await drafts.flush() }
    memories.values.forEach { $0.controller = nil }
    memories.removeAll()
    recent.removeAll()
  }

  var selectedRow: SessionRow? { store?.rows.first { $0.id == selection.sessionID } }

  func input(_ conversation: ConversationStore) -> MacConversationInput {
    if let input = inputs[conversation.id] { return input }
    let input = MacConversationInput(conversation: conversation, sessions: app.store!, draft: drafts.draft(conversation.id))
    #if DEBUG
    MacVoiceChecks.prepare(input.draft)
    MacAjustesChecks.prepare(input.draft)
    #endif
    inputs[conversation.id] = input
    return input
  }

  func showFiles(at path: String? = nil, file: String? = nil) {
    contextVisible = true
    selection.files = MacSelection.Files(folder: path, file: file)
  }

  func newSession() {
    newSessionRequest = MacNewSessionRequest(origin: nil, startInChats: true)
  }

  func newSession(from id: String) {
    guard let store, let session = store.rows.first(where: { $0.id == id })?.session else { return newSession() }
    let origin = NewSessionOrigin(session: session, projects: store.projects, chatRoot: store.chatRoot, model: session.model)
    newSessionRequest = MacNewSessionRequest(origin: origin, startInChats: false)
  }

  func openMaster() {
    guard let store, store.masterAvailability == .available else { return }
    if let id = store.masterID {
      selection = MacSelection(sessionID: id, master: true)
      Task { await store.verifyMaster() }
      return
    }
    newSessionRequest = MacNewSessionRequest(origin: nil, startInChats: false, master: true)
  }

  /// The iPhone's trash on the Sessão mestra: archives it and clears the master, with no confirmation and the same
  /// toast. Like the iPhone's empty master screen, the window then offers a new master (Nova sessão in its master
  /// mode), whose first message creates it.
  func resetMaster() {
    guard let store else { return }
    Task {
      await store.resetMaster()
      guard store.masterID == nil else { return }
      if selection.master { selection = MacSelection() }
      openMaster()
    }
  }

  func backToParent() {
    guard let child = selection.childID else { return }
    let parent = store?.liveConversation(child)?.session?.parentID
    selection.childID = parent == nil || parent == selection.sessionID ? nil : parent
  }

  func selectNeighbor(_ offset: Int) {
    guard let store else { return }
    let ids = SessionSections.group(store.filtered, now: .now).flatMap(\.rows).map(\.id)
    if let next = SessionNavigation.neighbor(ids, current: selection.sessionID, offset: offset) {
      selection = MacSelection(sessionID: next)
    }
  }

  func select(_ id: String) {
    guard let store else { return }
    if id == store.masterID {
      selection = MacSelection(sessionID: id, master: true)
      return
    }
    if let root = store.rows.first(where: { $0.id != id && $0.memberIDs.contains(id) }) {
      selection = MacSelection(sessionID: root.id, childID: id)
      return
    }
    selection = MacSelection(sessionID: id)
  }
}

typealias MacSelection = DesktopWindowState.Selection

/// Stable scene value: opening the same session twice still makes two independent windows.
struct MacWindowTarget: Codable, Hashable {
  var id = UUID()
  var sessionID: String?
}

extension FocusedValues {
  struct WindowRuntimeKey: FocusedValueKey { typealias Value = MacWindowRuntime }
  var macWindow: MacWindowRuntime? {
    get { self[WindowRuntimeKey.self] }
    set { self[WindowRuntimeKey.self] = newValue }
  }
}
