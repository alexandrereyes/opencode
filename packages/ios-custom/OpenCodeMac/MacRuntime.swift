import Observation
import OpenCodeKit
import SwiftUI

/// App services have one owner regardless of the number of windows. Window presentation lives in MacWindowRuntime.
@MainActor @Observable final class MacRuntime {
  static let shared = MacRuntime()
  static let localURL = URL(string: "http://127.0.0.1:4096")!
  let servers = ServerStore(launchOverride: .override(), builtinURL: MacRuntime.localURL)
  let appearance = AppearanceSettings()
  let audio = MacVoiceSession()
  var store: SessionStore?
  var identity = UUID()
  var appliedRevision = -1
  var error: String?
  var proxyPane: SubscriptionPane? = MacProxyLaunch.pane ?? .provider(.codex)
  var windows: [UUID: MacWindowRuntime] = [:]
  weak var front: MacWindowRuntime?
  var initialSelection: MacSelection?
  var pendingNotification: (id: String, server: String?)?
  @ObservationIgnored var openMainWindow: (() -> Void)?
  @ObservationIgnored private var building: Task<Void, Never>?
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var conversations: [String: (count: Int, task: Task<Void, Never>)] = [:]

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
    events?.cancel()
    conversations.values.forEach { $0.task.cancel() }
    conversations.removeAll()
    windows.values.forEach { $0.close() }
    windows.removeAll()
    front = nil
    await store?.stop()
    initialSelection = nil
    do {
      #if DEBUG
      if ScrollFixtures.mode == "conversation" {
        let next = SessionStore(configuration: MacFixture.configuration, acceptsLaunchSession: false,
          client: .inMemory(configuration: MacFixture.configuration, answer: { _ in nil }))
        ScrollFixtures.prepare(next)
        store = next
        initialSelection = MacSelection(sessionID: ScrollFixtures.sessionID)
        appliedRevision = servers.revision
        identity = UUID()
        return
      }
      if let fixture = MacFixture.current {
        let client = fixture.client()
        store = SessionStore(configuration: MacFixture.configuration, acceptsLaunchSession: false, client: client,
          draftRoot: MacVoiceChecks.enabled ? MacFixture.value("-OpenCodeMacDraftRoot").map { URL(fileURLWithPath: $0) } : nil)
        // The fixture has no resource hub: the viewer shows the drawn snapshot as its live frame.
        ResourceViewerModel.fixtureFrame = { resource in
          guard let data = try? await client.resourceSnapshot(resource.id, maxWidth: 1200).image else { return nil }
          return NSImage(data: data)
        }
        initialSelection = fixture.selection
      } else {
        store = SessionStore(configuration: try servers.configuration(), acceptsLaunchSession: false)
      }
      #else
      store = SessionStore(configuration: try servers.configuration(), acceptsLaunchSession: false)
      #endif
      appliedRevision = servers.revision
      identity = UUID()
      error = nil
      if let store {
        events = Task { await store.run() }
        observeServices(store)
      }
    } catch {
      store = nil
      self.error = error.localizedDescription
    }
  }

  private func observeServices(_ store: SessionStore) {
    guard self.store === store else { return }
    withObservationTracking {
      if let message = store.alerts.message {
        MacNotifications.shared.post(message, server: store.client.configuration.url)
      }
      MacNotifications.shared.badge(store.requestCount)
      if let id = store.conversationPath.last?.id {
        Task { @MainActor [weak self] in
          self?.front?.select(id)
          store.conversationPath = []
        }
      }
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeServices(store) }
    }
  }

  func syncShown() {
    store?.shownConversations = windows.values.flatMap { [$0.selection.sessionID, $0.selection.childID].compactMap { $0 } }
    store?.shownSessionID = NSApp.isActive ? front?.selection.childID ?? front?.selection.sessionID : nil
  }

  /// Only one event consumer per conversation, even when it is visible in two windows.
  func mount(_ conversation: ConversationStore) {
    if var entry = conversations[conversation.id] {
      entry.count += 1
      conversations[conversation.id] = entry
      return
    }
    conversations[conversation.id] = (1, Task { await conversation.run() })
  }

  func unmount(_ conversation: ConversationStore) {
    guard var entry = conversations[conversation.id] else { return }
    entry.count -= 1
    if entry.count > 0 { conversations[conversation.id] = entry; return }
    entry.task.cancel()
    conversations[conversation.id] = nil
  }
}

enum MacBulkRequest: Equatable { case selectAll, archive, delete }

struct MacNewSessionRequest: Identifiable {
  let id = UUID()
  let origin: NewSessionOrigin?
  let startInChats: Bool
  var master = false
}

enum MacLaunch {
  static let fixture = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacFixture")
}
