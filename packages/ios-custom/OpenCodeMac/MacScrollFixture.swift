#if DEBUG
import AppKit
import OpenCodeKit

/// The iPhone's offline scroll fixture on the Mac (`-OpenCodeScrollFixture conversation`): the same bundled
/// 300-message conversation, loaded by the shared `ConversationStore` without any server, with the same
/// `-OpenCodeFixturePosition`, `-OpenCodeFixtureStream <ms>` and `-OpenCodeFixturePaged` options.
@MainActor enum ScrollFixtures {
  static weak var conversation: ConversationStore?
  static let mode: String? = argument("-OpenCodeScrollFixture")
  static let reentry: String? = argument("-OpenCodeFixtureReentry")
  private(set) static var arrivals: [ConversationMessage] = []
  static let sessionID = "ses_scroll_0000"

  static func argument(_ name: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard arguments.indices.contains(index + 1) else { return "" }
    return arguments[index + 1]
  }

  static let snapshot: ScrollFixtureSnapshot = try! JSONDecoder().decode(
    ScrollFixtureSnapshot.self,
    from: Data(contentsOf: Bundle.main.url(forResource: "scroll-fixture", withExtension: "json")!))

  /// The saved place the fixture opens at, as the iPhone's `ScrollFixtureRoot` sets it.
  static func prepare(_ store: SessionStore) {
    let messages = snapshot.messages
    let position = argument("-OpenCodeFixturePosition")
    let target: ReadingPosition.Target =
      position == "top" ? .message(id: messages[0].id, offset: 0)
      : position == "middle" ? .message(id: messages[messages.count / 2].id, offset: 0)
      : position == "nearTail" ? .message(id: messages[messages.count - 3].id, offset: 0)
      : position.flatMap { id in messages.first { $0.id == id } }.map { .message(id: $0.id, offset: 0) }
        ?? .followTail
    store.reading.set(ReadingPosition(target), sessionID: sessionID)
  }
}

struct ScrollFixtureSnapshot: Decodable {
  let messages: [ConversationMessage]
  let entries: [NavigationEntry]
  let projects: [Project]
  let preferences: Preferences
  let models: [ModelInfo]
}
#endif
