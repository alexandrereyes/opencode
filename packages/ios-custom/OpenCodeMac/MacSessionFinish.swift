import AppKit
import OpenCodeKit

/// "Avisar ao terminar" on the Mac, without APNs: a macOS notification when a session with the bell on finishes for
/// good, under the server's rule (`plugin-app-custom/docs/session-notifications.md`). The root must have been seen
/// working by this process; when its execution ends the family must stay quiet for 5 seconds (a subagent or
/// background shell that ends wakes the root again, which cancels the wait) and then have no subagent or task still
/// running. `succeeded` says "Terminou", `failed` "Terminou com erro", `interrupted` nothing; nothing either while
/// that session is open in the front window. One alert per finish, until the session works again.
@MainActor final class MacSessionFinish {
  private enum Outcome { case succeeded, failed, interrupted }
  private static let grace = Duration.seconds(5)
  private let store: SessionStore
  private var working: Set<String> = []
  private var waiting: [String: Task<Void, Never>] = [:]

  init(store: SessionStore) { self.store = store }

  func run() async {
    for await frame in store.hub.events() {
      guard case .update(let event) = frame.event, let id = event.data.owner,
        event.type.hasPrefix("session.execution.") else { continue }
      switch event.type {
      case "session.execution.started":
        waiting.removeValue(forKey: id)?.cancel()
        if store.rows.contains(where: { $0.id == id }) { working.insert(id) }
      case "session.execution.succeeded": finished(id, .succeeded)
      case "session.execution.failed": finished(id, .failed)
      case "session.execution.interrupted": finished(id, .interrupted)
      default: break
      }
    }
    waiting.values.forEach { $0.cancel() }
  }

  private func finished(_ id: String, _ outcome: Outcome) {
    guard working.contains(id) else { return }
    waiting[id]?.cancel()
    waiting[id] = Task { [weak self] in
      do { try await Task.sleep(for: Self.grace) } catch { return }
      await self?.settle(id, outcome)
    }
  }

  private func settle(_ id: String, _ outcome: Outcome) async {
    waiting[id] = nil
    // Only top-level sessions (the rows) carry a bell; the master stays out of them.
    guard let row = store.rows.first(where: { $0.id == id }), row.notify, row.session.time.archived == nil else {
      working.remove(id)
      return
    }
    let client = store.client
    guard let family = try? await client.family(id) else { return }
    let shells = (try? await client.shells(directory: row.session.location.directory)) ?? []
    let work = SessionAlertWork(root: id, active: family.active, shells: shells)
    // Still working: the subagent or task that ends wakes the root, whose next finish decides.
    guard work.agents + work.tasks == 0, !family.active.contains(where: { $0.id == id }) else { return }
    working.remove(id)
    guard outcome != .interrupted, store.rows.first(where: { $0.id == id })?.notify == true else { return }
    let runtime = MacRuntime.shared
    if NSApp.isActive, runtime.front?.selection.sessionID == id { return }
    MacNotifications.shared.finished(row.session, failed: outcome == .failed, server: client.configuration.url)
  }
}
