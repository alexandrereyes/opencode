import AppIntents
import Observation
import OpenCodeKit
import SwiftUI

@main
struct OpenCodeApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  init() {
    FilePreviewStorage.clean()
    VoiceLaunchRouter.launcher = AppVoiceLauncher()
    AgentsActivityAgent.shared.watch()
  }
  var body: some Scene {
    WindowGroup {
      #if DEBUG
      if AgentsActivityFixtures.enabled { AgentsActivityFixtureRoot() }
      else if DictationFixtures.mode != nil { DictationFixtureRoot() }
      else if MCPFixtures.mode != nil { MCPFixtureRoot() }
      else if ComposerFixtures.enabled { ComposerFixtureRoot() }
      else if ConversationTitleFixtures.enabled { ConversationTitleFixtureRoot() }
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
  /// AppShell runs the store only with a scene; a call started without one still needs the
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
      // A server chosen in Você reopens it on the new store.
      if previous != nil { replacement.settingsOpen = true }
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
        AppShell(store: store, runtime: runtime).id(runtime.identity)
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

/// Sessões is the root: Você opens from its header avatar as a sheet, and the Sessão mestra bar sits at the bottom.
struct AppShell: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @State private var floatingVoice = FloatingVoicePresentation()
  @Bindable var store: SessionStore
  let runtime: AppRuntime

  var body: some View {
    SessionsView(store: store)
      .sheet(isPresented: $store.settingsOpen) {
        // Modal for alerts and the voice bar (hiding Sessões' bar); Você's own list keeps the single voice bar.
        SettingsView(runtime: runtime, store: store).sessionAlertOverlay(voice: false)
      }
      // Above every navigation stack, so a resource opens the same way from any screen.
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
        store.settingsOpen = false
        store.conversationPath.append(.init(id: id))
      }))
      .task(id: scenePhase == .active || runtime.voice.sessionID != nil) {
        if scenePhase == .active || runtime.voice.sessionID != nil { await store.run() }
      }
  }
}
