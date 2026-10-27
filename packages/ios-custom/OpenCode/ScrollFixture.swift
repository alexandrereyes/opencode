#if DEBUG
import OpenCodeKit
import SwiftUI

@MainActor enum ScrollFixtures {
  static weak var scrollState: ConversationScrollState?
  static weak var conversation: ConversationStore?
  static weak var driving: TranscriptDriving?
  static let mode: String? = argument("-OpenCodeScrollFixture")
  /// `pop` leaves and reopens the conversation; `child` covers it with another screen and returns; `memory`
  /// opens seven conversations in turn and reports the process footprint after each.
  static let reentry: String? = argument("-OpenCodeFixtureReentry")
  /// Messages that arrived while the app was hidden, as the next tail read would return them.
  private(set) static var arrivals: [ConversationMessage] = []

  private static func argument(_ name: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard arguments.indices.contains(index + 1) else { return "" }
    return arguments[index + 1]
  }

  /// A new prompt and its answer, delivered to the open conversation while the app is in the background.
  static func arrive() {
    let messages = snapshot.messages
    guard var user = messages.last(where: { $0.type == "user" }),
      var answer = messages.last(where: { $0.type == "assistant" && !$0.responseText.isEmpty })
    else { return }
    let index = arrivals.count / 2
    let created = (messages.last?.time.created ?? 0) + Double(index + 1) * 60_000
    user.id = "msg_scroll_arrival_\(index)_user"
    user.text = "Pergunta sintética \(index) enviada com o app escondido."
    user.metadata = nil
    user.time.created = created
    answer.id = "msg_scroll_arrival_\(index)_answer"
    answer.content = answer.content?.filter { $0.type == "text" }
    answer.time.created = created + 1000
    answer.time.completed = created + 2000
    arrivals += [user, answer]
    conversation?.receiveFixtureArrivals(arrivals)
  }
  static let snapshot: ScrollFixtureSnapshot = {
    let snapshot = try! JSONDecoder().decode(
      ScrollFixtureSnapshot.self,
      from: Data(contentsOf: Bundle.main.url(forResource: "scroll-fixture", withExtension: "json")!))
    if mode == "catalog" { return ScreenCatalogFixture.snapshot(snapshot) }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeContextUsageFixture") {
      return ContextUsageFixture.snapshot(snapshot)
    }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeMarkdownFixture") {
      return MarkdownFixtures.snapshot(snapshot)
    }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureEmpty") {
      return ScrollFixtureSnapshot(
        messages: [], entries: snapshot.entries, projects: snapshot.projects,
        preferences: snapshot.preferences, models: snapshot.models)
    }
    guard ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureFollow") else { return snapshot }
    // A small, fully measured starting transcript separates real row growth from
    // the unrelated coordinate renumbering of hundreds of unmeasured List items.
    let rows = snapshot.messages.filter {
      $0.type == "assistant" && (100...200).contains($0.responseText.count)
    }.suffix(3).map { message in
      var row = message
      row.content = message.content?.filter { $0.type == "text" }
      return row
    }
    var user = snapshot.messages[snapshot.messages.count - 3]
    user.text = "Acompanhe o checklist sintético."
    return ScrollFixtureSnapshot(
      messages: [user] + rows,
      entries: snapshot.entries, projects: snapshot.projects, preferences: snapshot.preferences, models: snapshot.models)
  }()
}

struct ScrollFixtureSnapshot: Decodable {
  let messages: [ConversationMessage]
  let entries: [NavigationEntry]
  let projects: [Project]
  let preferences: Preferences
  let models: [ModelInfo]
}

struct ScrollFixtureRoot: View {
  @Environment(\.colorScheme) private var systemScheme
  @State private var appearance = AppearanceSettings()
  @State private var store: SessionStore
  @State private var path = ["conversation"]

  init() {
    let store = SessionStore(
      configuration: ScrollFixtures.mode == "catalog" ? .launch() : ServerConfiguration(url: URL(string: "http://127.0.0.1:1")!),
      acceptsLaunchSession: false)
    let arguments = ProcessInfo.processInfo.arguments
    let index = arguments.firstIndex(of: "-OpenCodeFixturePosition")
    let position = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    let messages = ScrollFixtures.snapshot.messages
    let target: ReadingPosition.Target =
      position == "top" ? .message(id: messages[0].id, offset: 0)
      : position == "middle" ? .message(id: messages[messages.count / 2].id, offset: 0)
      // A reading bookmark above the tail: history above it has never been measured.
      : position == "nearTail" ? .message(id: messages[messages.count - 3].id, offset: 0)
      : position.flatMap { id in messages.first { $0.id == id } }.map { .message(id: $0.id, offset: 0) }
        ?? .followTail
    store.reading.set(ReadingPosition(target), sessionID: "ses_scroll_0000")
    _store = State(initialValue: store)
  }

  var body: some View {
    let theme = appearance.theme(systemDark: systemScheme == .dark)
    Group {
      if ScrollFixtures.mode == "catalog" {
        AppTabs(store: store, runtime: AppRuntime.shared)
          .environment(\.voiceController, AppRuntime.shared.voice)
          .environment(\.voiceSessionStore, store)
      } else if ScrollFixtures.mode == "conversation", ScrollFixtures.reentry != nil {
        NavigationStack(path: $path) {
          Text("Sessões sintéticas").navigationDestination(for: String.self) { route in
            if route == "conversation" {
              ConversationView(id: "ses_scroll_0000", sessions: store)
            } else if route.hasPrefix("ses_") {
              ConversationView(id: route, sessions: store)
            } else {
              Text("Tela sobreposta").frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
            }
          }
        }
        .task { await reenter() }
      } else if ScrollFixtures.mode == "conversation" {
        NavigationStack {
          ConversationView(id: "ses_scroll_0000", sessions: store)
        }
      } else if ScrollFixtures.mode == "sessions" {
        SessionsView(store: store)
      } else {
        ContentUnavailableView(
          "Fixture desconhecida", systemImage: "exclamationmark.triangle",
          description: Text("Use conversation ou sessions. Nenhum servidor foi conectado."))
      }
    }
    .environment(\.appTheme, theme)
    .environment(\.locale, Locale(identifier: "pt_BR"))
    .preferredColorScheme(appearance.colorScheme)
    .tint(theme.color(.primary))
    .background(ThemeChrome(theme: theme).frame(width: 0, height: 0))
    .background(ScrollFixtureDriver().frame(width: 0, height: 0))
    .background(ComposerTypingDriver().frame(width: 0, height: 0))
    .background(MarkdownFixtureCaptureDriver().frame(width: 0, height: 0))
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
      if ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureBackgroundArrivals") { ScrollFixtures.arrive() }
    }
    .task { TranscriptTrajectory.shared.start() }
    .task {
      if ScrollFixtures.mode == "catalog" {
        let draft = store.drafts.draft("ses_scroll_0000")
        await draft.load()
        await draft.clear()
        if ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogQuote") {
          draft.quotes = [.init(id: "catalog-quote", messageID: "msg_catalog_answer",
            partID: "msg_catalog_answer:text:0", text: "Criar uma sessão em um único toque.",
            comment: "Podemos destacar este atalho na próxima proposta?")]
        }
        await store.quota.refresh()
      }
      await store.run()
    }
  }

  /// Three departures and returns, each compared frame by frame with the passage shown when leaving.
  private func reenter() async {
    if ScrollFixtures.reentry == "memory" { return await measureMemory() }
    let trajectory = TranscriptTrajectory.shared
    // Tasks start in no particular order; the opening episode must exist before waiting for it.
    trajectory.start()
    await trajectory.settled()
    for _ in 0..<3 {
      do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
      let reference = trajectory.rows
      if ScrollFixtures.reentry == "child" {
        path.append("child")
        do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
        trajectory.begin("child", reference: reference)
        path.removeLast()
      } else {
        path.removeAll()
        do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
        trajectory.begin("reentry", reference: reference)
        path.append("conversation")
      }
      await trajectory.settled()
    }
  }

  /// Opens seven conversations one after another (the registry keeps five plus the stack) and records the
  /// footprint after each settles, then after a memory warning, in `Documents/transcript-memory.json`.
  private func measureMemory() async {
    var samples: [[String: Any]] = [["opened": 0, "footprintMB": Self.footprint()]]
    for index in 1...7 {
      path = []
      do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
      path = ["ses_scroll_\(String(format: "%04d", index))"]
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      let retained = (0...index).compactMap { store.conversations.existing("ses_scroll_\(String(format: "%04d", $0))") }
      samples.append(["opened": index, "footprintMB": Self.footprint(), "retained": retained.count,
        "views": retained.filter { $0.memory.controller != nil }.count,
        "messages": retained.map(\.messages.count).reduce(0, +)])
    }
    path = []
    do { try await Task.sleep(for: .seconds(1)) } catch { return }
    samples.append(["opened": 7, "afterLeaving": true, "footprintMB": Self.footprint()])
    NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    do { try await Task.sleep(for: .seconds(1)) } catch { return }
    samples.append(["opened": 7, "afterWarning": true, "footprintMB": Self.footprint()])
    let arguments = ProcessInfo.processInfo.arguments
    let run = arguments.firstIndex(of: "-OpenCodeFixtureRunID").flatMap {
      arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
    } ?? ""
    if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
      let data = try? JSONSerialization.data(withJSONObject: ["runID": run, "samples": samples], options: .prettyPrinted)
    {
      try? data.write(to: url.appendingPathComponent("transcript-memory.json"), options: .atomic)
    }
    NSLog("MEMORY %@", String(describing: samples))
  }

  private static func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
  }
}
#endif
