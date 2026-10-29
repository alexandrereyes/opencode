import Observation
import OpenCodeKit
import SwiftUI

@MainActor @Observable final class SessionAlertCenter {
  struct Message: Identifiable {
    let id = UUID()
    let session: Session
    let project: Project?
    let content: SessionAlertContent
  }
  private(set) var message: Message?
  private(set) var navigationID = UUID()
  private(set) var presentations: [UUID] = []
  @ObservationIgnored private var dismissal: Task<Void, Never>?
  @ObservationIgnored private var enrichment: Task<Void, Never>?
  /// Admission order: a slower completion lookup never replaces a newer alert.
  @ObservationIgnored private var sequence = 0
  @ObservationIgnored private var policy: SessionAlertPolicy
  @ObservationIgnored private let server: String
  @ObservationIgnored private let storageKey: String

  init(server: String) {
    self.server = server
    storageKey = "OpenCodeAlertClaims." + server
    policy = SessionAlertPolicy(claims: UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
  }
  func connect(at time: Double) { policy.connect(at: time) }
  func disconnect() {
    policy.disconnect()
    enrichment?.cancel()
    enrichment = nil
    dismissal?.cancel()
    dismissal = nil
    message = nil
  }
  func receive(_ event: ConversationEvent, store: SessionStore) async {
    guard let signal = SessionAlertSignal(event), store.hub.connected else { return }
    let connection = store.hub.connection
    do {
      async let info = store.client.session(signal.sessionID)
      async let settings = store.client.preferences()
      let (session, preferences) = try await (info, settings)
      var root = session
      var seen: Set<String> = [session.id]
      while let parent = root.parentID {
        guard seen.insert(parent).inserted else { return }
        root = try await store.client.session(parent)
      }
      guard !Task.isCancelled, store.hub.connected, store.hub.connection == connection else {
        return
      }
      let latest =
        (store.preferences?.revision ?? -1) > preferences.revision ? store.preferences : preferences
      let admitted = policy.admit(
        signal, server: server, session: session, root: root,
        current: store.currentSessionID,
        notified: pushes(store) ? latest?.data.notifySessions ?? [] : [], pushes: pushes(store),
        autoApprove: latest?.data.settings.autoApprove ?? false)
      UserDefaults.standard.set(policy.claims, forKey: storageKey)
      guard admitted else { return }
      sequence += 1
      let order = sequence
      let project = store.projects.first { $0.id == root.projectID }
      guard signal.kind == .succeeded else {
        present(Message(session: root, project: project, content: SessionAlertContent(kind: signal.kind)))
        return
      }
      // The root's execution ended; read what of its family still runs at this instant, from
      // the server rather than this device's possibly stale snapshot. The event stream keeps
      // this lookup off its path, and newer alerts win over a slower one.
      let client = store.client
      let target = root
      enrichment = Task { [weak self] in
        async let work = Self.within(.seconds(2)) { try await Self.work(of: target, client: client) }
        async let preview = Self.within(.milliseconds(1500)) { try await client.preview(target.id).reply }
        let content = SessionAlertContent(kind: .succeeded, work: await work, preview: await preview ?? nil)
        guard let self, !Task.isCancelled, self.sequence == order, store.hub.connected,
          store.hub.connection == connection, !store.deletedIDs.contains(target.id)
        else { return }
        self.present(Message(session: target, project: project, content: content))
      }
    } catch {
      // A missing session/ancestry or failed preferences read cannot safely produce an alert.
    }
  }
  /// Whether this server pushes session alerts (attention and bell finishes) to this device. The Mac has no APNs: its bell list keeps them and
  /// `MacSessionFinish` posts the system notification.
  private func pushes(_ store: SessionStore) -> Bool {
    #if os(iOS)
    SessionNotificationAgent.shared.pushing.contains(store.client.configuration.url)
    #else
    false
    #endif
  }
  private func present(_ next: Message) {
    message = next
    dismissal?.cancel()
    let id = next.id
    dismissal = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(6)) } catch { return }
      self?.dismiss(id)
    }
    Haptics.play(.soft)
    AccessibilityNotification.Announcement(
      [next.session.displayTitle, next.content.label, next.content.preview].compactMap { $0 }
        .joined(separator: ", ")
    ).post()
  }
  nonisolated private static func work(of root: Session, client: OpenCodeClient) async throws
    -> SessionAlertWork
  {
    async let family = client.family(root.id)
    // A missing directory has no shells; the family read alone decides whether work is known.
    async let shells = try? client.shells(directory: root.location.directory)
    return SessionAlertWork(root: root.id, active: try await family.active, shells: await shells ?? [])
  }
  /// `nil` when the read fails or exceeds `limit`; the alert then shows without that detail.
  nonisolated private static func within<Value: Sendable>(
    _ limit: Duration, _ operation: @escaping @Sendable () async throws -> Value
  ) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
      group.addTask { try? await operation() }
      group.addTask {
        try? await Task.sleep(for: limit)
        return nil
      }
      let first = await group.next()
      group.cancelAll()
      return first ?? nil
    }
  }
  func dismiss(_ id: UUID) { if message?.id == id { message = nil } }
  func remove(_ ids: Set<String>) {
    policy.remove(ids)
    UserDefaults.standard.set(policy.claims, forKey: storageKey)
    if let message, ids.contains(message.session.id) { dismiss(message.id) }
  }
  func openingSession() { navigationID = UUID() }
  func presented(_ id: UUID) {
    presentations.removeAll { $0 == id }
    presentations.append(id)
  }
  func leftPresentation(_ id: UUID) { presentations.removeAll { $0 == id } }
}

struct SessionAlertsContext {
  let center: SessionAlertCenter
  let open: (String) -> Void
}
extension EnvironmentValues {
  @Entry var sessionAlerts: SessionAlertsContext? = nil
}
private struct SessionAlertOverlay: ViewModifier {
  @Environment(\.sessionAlerts) private var alerts
  @Environment(\.dismiss) private var dismiss
  @State private var presentationID = UUID()
  let modal: Bool
  let voice: Bool
  func body(content: Content) -> some View {
    content.overlay(alignment: .top) {
      if let alerts,
        modal
          ? alerts.center.presentations.last == presentationID : alerts.center.presentations.isEmpty
      {
        SessionAlertBanner(center: alerts.center, open: alerts.open)
      }
    }
    .onAppear { if modal { alerts?.center.presented(presentationID) } }
    .onDisappear { if modal { alerts?.center.leftPresentation(presentationID) } }
    .onChange(of: alerts?.center.navigationID) { _, _ in
      // Each modal presentation boundary closes itself, including nested composer sheets.
      if modal { dismiss() }
    }
    #if os(iOS)
    .floatingVoiceInset(enabled: modal && voice)
    .modifier(FloatingVoiceScope(enabled: modal))
    #endif
  }
}
extension View {
  func sessionAlertOverlay(modal: Bool = true, voice: Bool = true) -> some View {
    modifier(SessionAlertOverlay(modal: modal, voice: voice))
  }
}

struct SessionAlertBanner: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let center: SessionAlertCenter
  let open: (String) -> Void
  var body: some View {
    Group {
      if let message = center.message {
        HStack(spacing: 12) {
          Button {
            center.dismiss(message.id)
            open(message.session.id)
          } label: {
            HStack(spacing: 12) {
              let colors = theme.avatar(
                SessionList.avatarColor(message.project, fallback: message.session.projectID))
              Text(
                SessionList.monogram(
                  message.project?.vcs != nil ? message.project?.displayName ?? message.session.displayTitle
                    : message.session.displayTitle)
              )
              .font(.system(size: 13, weight: .medium)).foregroundStyle(colors.text)
              .frame(width: 38, height: 38).background(colors.background, in: Circle())
              VStack(alignment: .leading, spacing: 3) {
                Text(message.session.displayTitle).font(.subheadline.weight(.semibold))
                  .foregroundStyle(theme.color(.textStrong)).lineLimit(1)
                Label(message.content.label, systemImage: icon(message.content)).font(.caption)
                  .foregroundStyle(theme.color(role(message.content.tone)))
                if let preview = message.content.preview {
                  Text(preview).font(.caption).foregroundStyle(theme.color(.textPreview)).lineLimit(1)
                }
              }
              Spacer(minLength: 0)
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.color(.icon))
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
            .accessibilityLabel(
              [message.session.displayTitle, message.content.label, message.content.preview]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("session-alert-open")
          Button("Fechar alerta", systemImage: "xmark") { center.dismiss(message.id) }
            .labelStyle(.iconOnly).font(.caption).foregroundStyle(theme.color(.textSecondary))
            .frame(width: 28, height: 36)
        }
        .padding(12).adaptiveGlass(RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 12).padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: center.message?.id)
  }
  private func role(_ tone: SessionAlertContent.Tone) -> ThemeRole {
    switch tone {
    case .success: .success
    case .neutral: .textSecondary
    case .error: .error
    case .info: .info
    }
  }
  private func icon(_ content: SessionAlertContent) -> String {
    if content.replied { return "bubble.left" }
    return switch content.kind {
    case .succeeded: "checkmark.circle"
    case .failed: "exclamationmark.circle"
    case .permission: "hand.raised"
    case .question: "questionmark.circle"
    }
  }
}
