import Foundation
import Observation
import OpenCodeKit

@MainActor @Observable final class ConversationStore {
  let id: String
  private(set) var session: Session?
  private(set) var messages: [ConversationMessage] = []
  private(set) var models: [ModelInfo] = []
  private(set) var agents: [AgentInfo] = []
  private(set) var family: FamilySnapshot?
  private(set) var children: [Session] = []
  private(set) var active: Set<String> = []
  private(set) var shells: [ShellInfo] = []
  private(set) var ownerMessages: [ConversationMessage] = []
  private(set) var branch = ""
  private(set) var loading = false
  private(set) var paging = false
  private(set) var hasOlder = true
  private(set) var viewedBoundary: Double?
  private(set) var ready = false
  private(set) var revision = 0
  var error: String?
  @ObservationIgnored private let client: OpenCodeClient
  @ObservationIgnored private let hub: EventHub
  @ObservationIgnored private var cursor: String?
  @ObservationIgnored private var refreshing = false
  @ObservationIgnored private var dirty = false
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var batchTask: Task<Void, Never>?
  @ObservationIgnored private var pending: [ConversationEvent] = []
  @ObservationIgnored private var acknowledged: Double?
  @ObservationIgnored private var visible = false
  @ObservationIgnored private var acknowledging = false
  @ObservationIgnored private var replaceHistory = false
  @ObservationIgnored private var snapshotSequence = 0

  init(id: String, client: OpenCodeClient, hub: EventHub) {
    self.id = id
    self.client = client
    self.hub = hub
  }
  var context: Double? { ConversationProjection.context(messages, models: models) }
  var waiting: Bool { family?.permissions.isEmpty == false || family?.forms.isEmpty == false }
  var working: Bool { active.contains(id) || family?.active.isEmpty == false }
  var runningCount: Int {
    ConversationProjection.runningCount(
      ownerID: session?.parentID ?? id, viewedID: id,
      messages: session?.parentID == nil ? messages : ownerMessages, children: children,
      active: active, shells: shells)
  }
  var modelLabel: String {
    let ref = session?.model
    return [
      models.first { $0.id == ref?.id && $0.providerID == ref?.providerID }?.name ?? ref?.id,
      ref?.variant == "default" ? nil : ref?.variant,
    ].compactMap { $0 }.joined(separator: " · ")
  }
  func responseText(endingAt id: String) -> String {
    guard let end = messages.firstIndex(where: { $0.id == id }) else { return "" }
    let start = messages[..<end].lastIndex(where: { $0.type == "user" }).map { $0 + 1 } ?? 0
    return messages[start...end].map(\.responseText).filter { !$0.isEmpty }.joined(
      separator: "\n\n")
  }
  func run() async {
    visible = true
    let events = hub.events()
    await refresh()
    for await frame in events {
      if Task.isCancelled { break }
      switch frame.event {
      case .connected: scheduleRefresh()
      case .update(let event):
        let ids = Set([id, session?.parentID].compactMap { $0 } + children.map(\.id))
        guard event.data.owner.map(ids.contains) == true || event.type.hasPrefix("rpc.") else {
          continue
        }
        if event.type.hasPrefix("session.revert.") { replaceHistory = true }
        // Snapshot and stream race: buffered deltas may already be in the snapshot.
        // Never append them twice; revalidate once more to cover the read's in-flight window.
        if refreshing || frame.sequence <= snapshotSequence {
          scheduleRefresh()
          continue
        }
        if event.data.owner == id {
          pending.append(event)
          scheduleBatch()
        }
        if !event.type.hasSuffix(".delta") && !event.type.hasSuffix(".progress") {
          scheduleRefresh()
        }
      }
    }
    visible = false
    refreshTask?.cancel()
    refreshTask = nil
    batchTask?.cancel()
    batchTask = nil
  }
  private func scheduleBatch() {
    guard batchTask == nil else { return }
    batchTask = Task {
      do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
      let events = pending
      pending.removeAll()
      batchTask = nil
      for event in events {
        if !ConversationReducer.apply(event, to: &messages) { scheduleRefresh() }
      }
      revision += 1
    }
  }
  private func scheduleRefresh() {
    dirty = true
    guard refreshTask == nil else { return }
    refreshTask = Task {
      while dirty && !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
        dirty = false
        await refresh()
      }
      refreshTask = nil
    }
  }
  func refresh() async {
    guard !refreshing else {
      dirty = true
      return
    }
    refreshing = true
    loading = !ready
    pending.removeAll()
    batchTask?.cancel()
    batchTask = nil
    defer {
      refreshing = false
      loading = false
      snapshotSequence = hub.sequence
    }
    do {
      async let info = client.session(id)
      async let page = client.conversation(id)
      async let running = client.active()
      let (infoValue, pageValue, runningValue) = try await (info, page, running)
      try Task.checkCancellation()
      if !ready {
        viewedBoundary = infoValue.time.viewed
        cursor = pageValue.cursor?.next
        hasOlder = !pageValue.data.isEmpty
      }
      session = infoValue
      if replaceHistory {
        let count = messages.count
        var replacement = Array(pageValue.data.reversed())
        var next = pageValue.cursor?.next
        while replacement.count < count, let current = next {
          let older = try await client.conversation(id, cursor: current)
          if older.data.isEmpty {
            next = nil
            break
          }
          replacement = ConversationProjection.merge(
            replacement, page: older.data.reversed(), older: true)
          next = older.cursor?.next
          if next == current { break }
        }
        messages = replacement
        cursor = next
        hasOlder = next != nil
        replaceHistory = false
      } else {
        messages = ConversationProjection.merge(messages, page: pageValue.data.reversed())
      }
      active = Set(runningValue.filter { $0.value.isRunning }.map(\.key))
      let directory = infoValue.location.directory
      if models.isEmpty { models = try await client.models(directory: directory) }
      if agents.isEmpty { agents = try await client.agents(directory: directory) }
      async let familyValue = client.family(id)
      async let shellValue = client.shells(directory: directory)
      async let located = client.locate([directory])
      let snapshots = try await (familyValue, shellValue, located)
      var members: [Session] = []
      var after: String?
      repeat {
        let page = try await client.familyPage(infoValue.parentID ?? id, after: after)
        members.append(contentsOf: page.data)
        if page.next == after { break }
        after = page.next
      } while after != nil
      family = snapshots.0
      children = members
      shells = snapshots.1
      branch = snapshots.2.first?.branch ?? URL(fileURLWithPath: directory).lastPathComponent
      if let parent = infoValue.parentID {
        ownerMessages = try await client.conversation(parent).data.reversed()
      }
      ready = true
      revision += 1
      error = nil
    } catch {
      if !Task.isCancelled {
        self.error = "Não foi possível atualizar a conversa. \(error.localizedDescription)"
      }
    }
  }
  func older() async {
    guard !paging, hasOlder, let cursor else { return }
    paging = true
    defer { paging = false }
    do {
      let page = try await client.conversation(id, cursor: cursor)
      try Task.checkCancellation()
      messages = ConversationProjection.merge(messages, page: page.data.reversed(), older: true)
      self.cursor = page.cursor?.next
      hasOlder = !page.data.isEmpty && self.cursor != cursor
    } catch { self.error = "Não foi possível carregar o histórico. \(error.localizedDescription)" }
  }
  /// Called after the updated transcript has reached the view, never at request start.
  func presented() async {
    guard let session, !acknowledging,
      let watermark = ConversationProjection.viewedWatermark(
        idle: session.time.idle, viewed: session.time.viewed, acknowledged: acknowledged,
        visible: visible && ready)
    else { return }
    acknowledging = true
    defer { acknowledging = false }
    do {
      try await client.markViewed(session)
      acknowledged = watermark
    } catch {
      if !Task.isCancelled { self.error = "Não foi possível marcar a conversa como lida." }
    }
  }
  func shellOutput(_ part: ConversationPart) async throws -> String? {
    guard let directory = session?.location.directory,
      let shellID = part.metadata["shellID"]?.string
        ?? shells.first(where: {
          $0.metadata?["sessionID"]?.string == id && $0.command == part.input["command"]?.string
        })?.id
    else { return nil }
    let output = try await client.shellOutput(shellID, directory: directory)
    if output.size > 65536 {
      return try await client.shellOutput(
        shellID, directory: directory, cursor: output.size - 65536
      ).output
    }
    return output.output
  }
}
