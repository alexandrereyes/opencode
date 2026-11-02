import Observation
import OpenCodeKit
import SwiftUI

/// App services have one owner regardless of the number of windows. Window presentation lives in MacWindowRuntime.
@MainActor @Observable final class MacRuntime {
  static let shared = MacRuntime()
  static let localURL = URL(string: "http://127.0.0.1:4096")!
  let servers = MacRuntime.serverStore()
  let appearance = AppearanceSettings()
  let audio = MacVoiceSession()
  var store: SessionStore?
  var identity = UUID()
  var appliedRevision = -1
  var error: String?
  var proxyPane: SubscriptionPane? = MacProxyLaunch.pane ?? .provider(.codex)
  var windows: [UUID: MacWindowRuntime] = [:]
  /// The bell's list in every window (`MacNotificationBell`).
  let alertInbox = MacAlertInbox()
  /// Espaço em disco: the rail's bar and the sheet, shared by every window.
  let disk = MacDiskStore()
  weak var front: MacWindowRuntime?
  var initialSelection: MacSelection?
  var pendingNotification: (id: String, server: String?)?
  /// Ajustes ▸ Servidores opens Adicionar servidor… (the rail's server menu).
  var addingServer = false
  /// Ajustes ▸ Snippets, which the conversation opens on a project or a new snippet (`MacSnippets`).
  let snippetBoard = MacSnippetBoard()
  @ObservationIgnored var openMainWindow: (() -> Void)?
  @ObservationIgnored private var building: Task<Void, Never>?
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var finishes: Task<Void, Never>?
  @ObservationIgnored private var conversations: [String: (count: Int, task: Task<Void, Never>)] = [:]
  /// What keeps every screen from the user now; empty is `systemAwake` (`ReadVisibility.desktop`). Views read each
  /// window's `readable` instead, set by `syncShown`.
  @ObservationIgnored private var asleep: Set<SystemState> = []
  #if DEBUG
  /// The read check's stand-in for AppKit (`MacLaunch.readCheck`): whether the app is active and hidden, and the
  /// sessions whose windows are minimized. A locked Mac activates no app, and the check never takes the user's focus.
  @ObservationIgnored private var simulated = (active: true, hidden: false, minimized: Set<String>())
  #endif

  init() { observeSystem() }

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
    finishes?.cancel()
    conversations.values.forEach { $0.task.cancel() }
    conversations.removeAll()
    windows.values.forEach { $0.close() }
    windows.removeAll()
    front = nil
    await store?.stop()
    snippetBoard.clear()
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
        if !MacLaunch.fixture {
          let finish = MacSessionFinish(store: store)
          finishes = Task { await finish.run() }
        }
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
        // A bell session's finish is announced by `MacSessionFinish` under the server's rule instead.
        let bell = store.rows.first { $0.id == message.session.id }?.notify == true
        if !(bell && (message.content.kind == .succeeded || message.content.kind == .failed)) {
          MacNotifications.shared.post(message, server: store.client.configuration.url)
        }
        alertInbox.record(message)
      }
      MacNotifications.shared.badge(store.attentionCount)
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

  private static func serverStore() -> ServerStore {
    #if DEBUG
    if let fixture = MacServerChecks.servers() { return fixture }
    if MacLaunch.testCopy {
      let sandbox = TestInstall.sandbox(launch: .override(), defaults: .standard, credentials: ServerCredentials())
      return ServerStore(launchOverride: sandbox, builtinURL: localURL, testWithoutSandbox: sandbox == nil)
    }
    #endif
    return ServerStore(launchOverride: .override(), builtinURL: localURL)
  }

  func syncShown() {
    for runtime in windows.values {
      let readable = seen(runtime)
      guard runtime.readable != readable else { continue }
      runtime.readable = readable
      #if DEBUG
      if MacLaunch.readCheck {
        print("MacRead \(runtime.selection.sessionID ?? "-") readable \(readable) \(simulated)"
          + " system \(asleep.map(\.rawValue).sorted())")
        fflush(stdout)
      }
      #endif
    }
    store?.shownConversations = windows.values.flatMap { [$0.selection.sessionID, $0.selection.childID].compactMap { $0 } }
    // `NSApp.isActive` too: the bell check's background copy reads without its conversation being the shown one.
    store?.shownSessionID = NSApp.isActive && front?.readable == true
      ? front?.selection.childID ?? front?.selection.sessionID : nil
  }

  /// Whether the user can see this window now, so its conversation may acknowledge answers on its own.
  private func seen(_ runtime: MacWindowRuntime) -> Bool {
    #if DEBUG
    // The bell check runs in the background and off-screen, and opening a line must still read it.
    if MacBellChecks.arrival != nil { return true }
    if MacLaunch.readCheck {
      return runtime.window != nil && ReadVisibility.desktop(
        appActive: simulated.active, windowVisible: !simulated.hidden,
        minimized: simulated.minimized.contains(runtime.selection.sessionID ?? ""), occluded: false,
        systemAwake: asleep.isEmpty)
    }
    #endif
    guard let window = runtime.window else { return false }
    return ReadVisibility.desktop(
      appActive: NSApp.isActive, windowVisible: window.isVisible, minimized: window.isMiniaturized,
      occluded: !window.occlusionState.contains(.visible), systemAwake: asleep.isEmpty)
  }

  /// Displays asleep, the screen locked or another user's session in front: no window can be seen until it ends.
  private func observeSystem() {
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()
    let changes: [(NotificationCenter, Notification.Name, SystemState, Bool)] = [
      (workspace, NSWorkspace.screensDidSleepNotification, .asleep, true),
      (workspace, NSWorkspace.screensDidWakeNotification, .asleep, false),
      (workspace, NSWorkspace.sessionDidResignActiveNotification, .switchedOut, true),
      (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .switchedOut, false),
      (distributed, Notification.Name("com.apple.screenIsLocked"), .locked, true),
      (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
    ]
    for (center, name, state, on) in changes {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          #if DEBUG
          // The read check takes only the states it is told; the real ones are traced.
          if MacLaunch.readCheck {
            print("MacRead real \(state.rawValue) \(on)")
            fflush(stdout)
            return
          }
          #endif
          self?.change(state, on)
        }
      }
    }
    #if DEBUG
    // The read check tells its copy those transitions instead, so it never sleeps, locks or takes over the Mac.
    guard MacLaunch.readCheck, let id = Bundle.main.bundleIdentifier else { return }
    distributed.addObserver(forName: Notification.Name(id + ".read-check"), object: nil, queue: .main) { [weak self] note in
      guard let command = note.object as? String else { return }
      MainActor.assumeIsolated { self?.readCheck(command) }
    }
    #endif
  }

  #if DEBUG
  /// `active:1|0`, `hidden:1|0`, `minimized:<session id>:1|0` (that session's window), `asleep:1|0`, `locked:1|0`,
  /// `switchedOut:1|0`, or `window:<session id>` for one more window showing that session.
  private func readCheck(_ command: String) {
    let parts = command.split(separator: ":").map(String.init)
    let on = parts.last == "1"
    switch parts.first {
    case "window" where parts.count == 2:
      pendingNotification = (parts[1], nil)
      openMainWindow?()
    case "active": simulated.active = on
    case "hidden": simulated.hidden = on
    case "minimized" where parts.count == 3:
      if on { simulated.minimized.insert(parts[1]) } else { simulated.minimized.remove(parts[1]) }
    default:
      if let state = parts.first.flatMap(SystemState.init(rawValue:)) { change(state, on) }
      return
    }
    syncShown()
  }
  #endif

  private func change(_ state: SystemState, _ on: Bool) {
    if on { asleep.insert(state) } else { asleep.remove(state) }
    syncShown()
  }

  private enum SystemState: String { case asleep, locked, switchedOut }

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
  /// The conversation in front when ⌘N opened it: its project (or Chats) wins over the Sessões chips.
  var front: NewSessionOrigin? = nil
}

enum MacLaunch {
  /// A fixture or an offline check: no notifications, finish banners or real voice. The voice screen check and the
  /// live resources check (`-OpenCodeMacResourcesLive`) talk to an isolated sandbox server instead of the in-memory
  /// fixture.
  static let fixture = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacFixture")
    || ProcessInfo.processInfo.arguments.contains("-OpenCodeMacVoiceScreenCheck")
    || ProcessInfo.processInfo.arguments.contains("-OpenCodeMacResourcesLive")
  /// `-OpenCodeMacBackground` with a fixture: a test copy that never takes the user's focus. No Dock icon or menu
  /// bar (an accessory app) and no activation; its windows stay off-screen as the captures already put them.
  static let background = fixture && ProcessInfo.processInfo.arguments.contains("-OpenCodeMacBackground")
  /// A test copy: the scripts give each copy a bundle identifier of its own (`….ajustes.tests`, …), unlike the
  /// installed app and the Debug build. It never connects to a saved server or to 4096 (`TestInstall`).
  static let testCopy = !["br.com.alexandrem.opencode.mac", "br.com.alexandrem.opencode.mac.debug"]
    .contains(Bundle.main.bundleIdentifier ?? "")
  #if DEBUG
  /// `-OpenCodeMacReadCheck` in a test copy (`script/test-read-visibility.py mac`): prints `MacRead …` whenever a
  /// window's `readable` changes and takes the app, window and system states it is told (`<bundle id>.read-check`)
  /// instead of AppKit's, so the check runs in the background, even with the Mac's screen off or locked.
  static let readCheck = testCopy && ProcessInfo.processInfo.arguments.contains("-OpenCodeMacReadCheck")
  #endif
}
