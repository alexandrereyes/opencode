import AppIntents
import Observation
import OpenCodeKit
import SwiftUI

@main
struct OpenCodeApp: App {
  var body: some Scene {
    WindowGroup {
      #if DEBUG
      if ScrollFixtures.mode != nil { ScrollFixtureRoot() } else { AppRoot() }
      #else
      AppRoot()
      #endif
    }
  }
}

@MainActor @Observable final class AppRuntime {
  let servers = ServerStore(launchOverride: .override())
  let appearance = AppearanceSettings()
  var store: SessionStore?
  var identity = UUID()
  var appliedRevision = -1
  var switching = false
  var error: String?
  func rebuild() async {
    switching = true
    defer { switching = false }
    let previous = store
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
  @Environment(\.colorScheme) private var systemScheme
  @State private var runtime = AppRuntime()
  var body: some View {
    let theme = runtime.appearance.theme(systemDark: systemScheme == .dark)
    Group {
      if let store = runtime.store, runtime.appliedRevision == runtime.servers.revision {
        AppTabs(store: store, runtime: runtime).id(runtime.identity)
          .allowsHitTesting(!runtime.switching)
      } else if let error = runtime.error {
        ContentUnavailableView {
          Label("Credenciais indisponíveis", systemImage: "key")
        } description: { Text(error) } actions: {
          Button("Tentar novamente") { Task { await runtime.rebuild() } }.disabled(runtime.switching)
        }
      } else { ProgressView("Conectando…") }
    }
    .environment(\.appTheme, theme)
    .environment(\.locale, Locale(identifier: "pt_BR"))
    .preferredColorScheme(runtime.appearance.colorScheme)
    .tint(theme.color(.primary))
    .background(ThemeChrome(theme: theme).frame(width: 0, height: 0))
    .task(id: runtime.servers.revision) { await runtime.rebuild() }
  }
}

private struct AppTabs: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var store: SessionStore
  let runtime: AppRuntime

  var body: some View {
    TabView(selection: $store.selectedTab) {
      Tab("Painel", systemImage: "square.grid.2x2", value: 0) {
        placeholder("Painel", icon: "square.grid.2x2")
      }
      Tab("Pedidos", systemImage: "tray", value: 1) { placeholder("Pedidos", icon: "tray") }.badge(
        store.requestCount)
      Tab("Projetos", systemImage: "folder", value: 2) { placeholder("Projetos", icon: "folder") }
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
    .tabViewBottomAccessory(isEnabled: !store.conversationOpen) {
      HStack(spacing: 8) {
        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(
          theme.color(.accent))
        Text("Sessão mestra").fontWeight(.medium)
        Spacer(minLength: 4)
        Text(store.requestCount > 0 ? "\(store.requestCount) precisam de você" : "Tudo em dia")
          .foregroundStyle(theme.color(.textSecondary))
        Image(systemName: "arrow.right").foregroundStyle(theme.color(.icon))
      }
      .font(.system(size: 13))
      .foregroundStyle(theme.color(.textStrong))
      .padding(.horizontal, 18)
      .accessibilityElement(children: .combine)
      .accessibilityHint("Em construção")
    }
    .background(theme.color(.background))
    .sessionAlertOverlay(modal: false)
    .environment(\.sessionAlerts, SessionAlertsContext(center: store.alerts, open: { id in
      if let current = store.currentSessionID { store.drafts.draft(current).focused = false }
      store.alerts.openingSession()
      store.selectedTab = 3
      store.conversationPath.append(.init(id: id))
    }))
    .task(id: scenePhase) {
      if scenePhase == .active { await store.run() }
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
        .font: UIFont.systemFont(ofSize: 10, weight: .medium),
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
