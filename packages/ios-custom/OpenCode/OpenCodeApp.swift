import AppIntents
import Observation
import OpenCodeKit
import SwiftUI

@main
struct OpenCodeApp: App {
  @UIApplicationDelegateAdaptor(TranscriptionAppDelegate.self) private var delegate
  init() {
    FilePreviewStorage.clean()
    VoiceLaunchRouter.launcher = AppVoiceLauncher()
  }
  var body: some Scene {
    WindowGroup {
      #if DEBUG
      if AgentsActivityFixtures.enabled { AgentsActivityFixtureRoot() }
      else if DictationFixtures.mode != nil { DictationFixtureRoot() }
      else if MCPFixtures.mode != nil { MCPFixtureRoot() }
      else if ComposerFixtures.enabled { ComposerFixtureRoot() }
      else if ScrollFixtures.mode != nil { ScrollFixtureRoot() } else { AppRoot() }
      #else
      AppRoot()
      #endif
    }
  }
}

/// App-wide state, shared by the scene and by intents that run without one (Action button, Controls).
@MainActor @Observable final class AppRuntime {
  static let shared = AppRuntime()
  let servers = ServerStore(launchOverride: .override())
  let appearance = AppearanceSettings()
  let voice = VoiceController()
  var store: SessionStore?
  var identity = UUID()
  var appliedRevision = -1
  var switching = false
  var error: String?
  @ObservationIgnored private var building: Task<Void, Never>?
  @ObservationIgnored private var voiceSessions: Task<Void, Never>?
  /// Builds the store for the active server only when it is missing or stale; the scene and an
  /// intent arriving together share one build, so neither replaces the other's call.
  @discardableResult func prepare() async -> SessionStore? {
    if let building { await building.value }
    if store != nil, appliedRevision == servers.revision { return store }
    let task = Task { await rebuild() }
    building = task
    await task.value
    building = nil
    return appliedRevision == servers.revision ? store : nil
  }
  /// AppTabs runs the store only with a scene; a call started without one still needs the
  /// event stream for Sessão mestra progress, until that call ends.
  func keepSessionsRunning(_ store: SessionStore) {
    guard voiceSessions == nil else { return }
    voiceSessions = Task {
      let run = Task { await store.run() }
      for await id in Observations({ self.voice.sessionID }) where id == nil { break }
      run.cancel()
      await run.value
      voiceSessions = nil
    }
  }
  private func rebuild() async {
    switching = true
    defer { switching = false }
    let previous = store
    if previous != nil { await voice.end() }
    await previous?.stop()
    guard !Task.isCancelled else { return }
    do {
      let replacement = SessionStore(configuration: try servers.configuration(), acceptsLaunchSession: previous == nil)
      if previous != nil { replacement.selectedTab = 4 }
      store = replacement
      appliedRevision = servers.revision
      identity = UUID()
      error = nil
    } catch {
      store = nil
      self.error = error.localizedDescription
    }
  }
}

private struct AppRoot: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorScheme) private var systemScheme
  private let runtime = AppRuntime.shared
  var body: some View {
    let theme = runtime.appearance.theme(systemDark: systemScheme == .dark)
    Group {
      if let store = runtime.store, runtime.appliedRevision == runtime.servers.revision {
        AppTabs(store: store, runtime: runtime).id(runtime.identity)
          .allowsHitTesting(!runtime.switching)
          .environment(\.voiceController, runtime.voice)
          .environment(\.voiceSessionStore, store)
      } else if let error = runtime.error {
        ContentUnavailableView {
          Label("Credenciais indisponíveis", systemImage: "key")
        } description: { Text(error) } actions: {
          Button("Tentar novamente") { Task { await runtime.prepare() } }.disabled(runtime.switching)
        }
      } else { ProgressView("Conectando…") }
    }
    .environment(\.appTheme, theme)
    .environment(\.locale, Locale(identifier: "pt_BR"))
    .preferredColorScheme(runtime.appearance.colorScheme)
    .tint(theme.color(.primary))
    .background(ThemeChrome(theme: theme).frame(width: 0, height: 0))
    .task(id: runtime.servers.revision) { await runtime.prepare() }
    .task {
      TranscriptionController.shared.start()
      AgentsActivityAgent.shared.start()
      #if DEBUG
      DeviceAgent.shared.probeIfRequested()
      #endif
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      TranscriptionController.shared.setActive(phase == .active)
      if phase == .active { DeviceAgent.shared.sceneBecameActive() }
    }
    .onChange(of: theme.id, initial: true) {
      runtime.voice.setTheme(theme)
      AgentsActivityAgent.shared.setTheme(theme)
    }
    .onOpenURL { url in
      guard let link = AgentsDeepLink(url: url) else { return }
      Task { await runtime.open(link) }
    }
  }
}

struct AppTabs: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @State private var floatingVoice = FloatingVoicePresentation()
  @Bindable var store: SessionStore
  let runtime: AppRuntime

  var body: some View {
    TabView(selection: $store.selectedTab) {
      Tab("Painel", systemImage: "square.grid.2x2", value: 0) {
        placeholder("Painel", icon: "square.grid.2x2")
          .floatingVoiceInset(sessions: store)
      }
      Tab("Pedidos", systemImage: "tray", value: 1) {
        placeholder("Pedidos", icon: "tray").floatingVoiceInset(sessions: store)
      }.badge(
        store.requestCount)
      Tab("Projetos", systemImage: "folder", value: 2) {
        placeholder("Projetos", icon: "folder").floatingVoiceInset(sessions: store)
      }
      Tab("Sessões", systemImage: "bubble.left.and.bubble.right.fill", value: 3) {
        SessionsView(store: store)
      }
      Tab(value: 4) {
        SettingsView(runtime: runtime, store: store)
      } label: {
        Label {
          Text("Você")
        } icon: {
          Image(uiImage: profileIcon)
        }
      }
    }
    // The voice bar is a content inset, so it stacks above this accessory instead of replacing it.
    .tabViewBottomAccessory(isEnabled: !(store.selectedTab == 3 && store.conversationOpen)) {
      Button {
        store.selectedTab = 3
        store.conversationPath.append(.init(id: "master", master: true))
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "point.3.connected.trianglepath.dotted").appSymbol(.action).foregroundStyle(
            theme.color(.accent))
          // The native tab accessory has a fixed height; shrink its labels before clipping them.
          Text("Sessão mestra").fontWeight(.medium)
            .lineLimit(1).minimumScaleFactor(0.45)
          Spacer(minLength: 4)
          Text(store.masterAvailability == .available
            ? (store.requestCount > 0 ? "\(store.requestCount) precisam de você" : "Tudo em dia")
            : store.masterAvailability.label)
            .foregroundStyle(theme.color(.glassSecondary))
            .lineLimit(1).minimumScaleFactor(0.45)
          Image(systemName: "arrow.right").appSymbol(.inline).foregroundStyle(theme.color(.icon))
        }
        .appFont(.caption).monospacedDigit()
        .foregroundStyle(theme.color(.textStrong))
        .padding(.horizontal, AppLayout.margin)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
      }.buttonStyle(.plain).accessibilityIdentifier("master-accessory")
    }
    // Above the tabs and every navigation stack, so a resource opens the same way from any screen.
    .fullScreenCover(item: $store.openResource) { resource in
      ResourceViewerScreen(resource: resource, client: store.client) { store.openResource = nil }
    }
    .onAppear { ResourceLinks.store = store }
    .environment(\.floatingVoice, floatingVoice)
    .onChange(of: runtime.voice.sessionID, initial: true) { _, id in floatingVoice.observe(id) }
    .background(theme.color(.background))
    #if DEBUG
    // UI tests read the connected server before destructive actions, so a relaunch that fell back to the
    // default server fails instead of archiving or deleting real sessions.
    .overlay(alignment: .topLeading) {
      Text(store.client.configuration.url.absoluteString)
        .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1).clipped()
        .allowsHitTesting(false)
        .accessibilityIdentifier("debug-server-url")
    }
    #endif
    .toastOverlay(runtime.voice.toast)
    .sessionAlertOverlay(modal: false)
    .environment(\.sessionAlerts, SessionAlertsContext(center: store.alerts, open: { id in
      if let current = store.currentSessionID { store.drafts.draft(current).focused = false }
      store.alerts.openingSession()
      store.selectedTab = 3
      store.conversationPath.append(.init(id: id))
    }))
    .task(id: scenePhase == .active || runtime.voice.sessionID != nil) {
      if scenePhase == .active || runtime.voice.sessionID != nil { await store.run() }
    }
  }

  private var profileIcon: UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26))
    return renderer.image { context in
      theme.uiColor(.border).setStroke()
      let ring = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 24, height: 24))
      ring.lineWidth = 1.5
      ring.stroke()
      theme.uiColor(.success).setStroke()
      let quota = UIBezierPath(
        arcCenter: CGPoint(x: 13, y: 13), radius: 12,
        startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
      quota.lineWidth = 1.5
      quota.stroke()
      let attributes: [NSAttributedString.Key: Any] = [
        .font: AppTypography.font(.micro, weight: .medium,
          compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)),
        .foregroundColor: theme.uiColor(.textStrong),
      ]
      let text = NSString(string: "AR")
      let size = text.size(withAttributes: attributes)
      text.draw(
        at: CGPoint(x: (26 - size.width) / 2, y: (26 - size.height) / 2), withAttributes: attributes
      )
    }.withRenderingMode(.alwaysOriginal)
  }

  private func placeholder(_ title: String, icon: String) -> some View {
    NavigationStack {
      ContentUnavailableView(
        title, systemImage: icon, description: Text("Esta tela está em construção.")
      )
      .foregroundStyle(theme.color(.textSecondary))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.color(.background))
      .navigationTitle(title)
    }
  }
}
