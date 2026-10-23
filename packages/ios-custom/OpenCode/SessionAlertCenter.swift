import Observation
import OpenCodeKit
import SwiftUI

@MainActor @Observable final class SessionAlertCenter {
  struct Message: Identifiable {
    let id = UUID()
    let session: Session
    let project: Project?
    let kind: SessionAlertKind
  }
  private(set) var message: Message?
  private(set) var navigationID = UUID()
  private(set) var presentations: [UUID] = []
  @ObservationIgnored private var dismissal: Task<Void, Never>?
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
        current: store.currentSessionID, muted: latest?.data.mutedSessions ?? [],
        autoApprove: latest?.data.settings.autoApprove ?? false)
      UserDefaults.standard.set(policy.claims, forKey: storageKey)
      guard admitted else { return }
      message = Message(
        session: root, project: store.projects.first { $0.id == root.projectID }, kind: signal.kind)
      dismissal?.cancel()
      let id = message?.id
      dismissal = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(6)) } catch { return }
        if let id { self?.dismiss(id) }
      }
      Haptics.play(.soft)
      AccessibilityNotification.Announcement("\(root.displayTitle), \(signal.kind.label)").post()
    } catch {
      // A missing session/ancestry or failed mute read cannot safely produce an alert.
    }
  }
  func dismiss(_ id: UUID) { if message?.id == id { message = nil } }
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
  }
}
extension View {
  func sessionAlertOverlay(modal: Bool = true) -> some View {
    modifier(SessionAlertOverlay(modal: modal))
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
                Label(message.kind.label, systemImage: icon(message.kind)).font(.caption)
                  .foregroundStyle(theme.color(role(message.kind)))
              }
              Spacer(minLength: 0)
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.color(.icon))
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
            .accessibilityLabel("\(message.session.displayTitle), \(message.kind.label)")
            .accessibilityIdentifier("session-alert-open")
          Button("Fechar alerta", systemImage: "xmark") { center.dismiss(message.id) }
            .labelStyle(.iconOnly).font(.caption).foregroundStyle(theme.color(.textSecondary))
            .frame(width: 28, height: 36)
        }
        .padding(12).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 12).padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: center.message?.id)
  }
  private func role(_ kind: SessionAlertKind) -> ThemeRole {
    switch kind {
    case .succeeded: .success
    case .failed, .permission: .error
    case .question: .info
    }
  }
  private func icon(_ kind: SessionAlertKind) -> String {
    switch kind {
    case .succeeded: "checkmark.circle"
    case .failed: "exclamationmark.circle"
    case .permission: "hand.raised"
    case .question: "questionmark.circle"
    }
  }
}
