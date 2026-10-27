import Observation
import OpenCodeKit
import SwiftUI

/// Conversations recently on screen, retained so returning to one needs neither the network nor a
/// restoration: its messages, history pages and cursor, projections, visual state and exact reading place
/// are still there. The most recent `capacity` stay alive, plus every conversation on the navigation stack;
/// a memory warning keeps only the stack. One registry belongs to one server's `SessionStore`.
@MainActor final class ConversationRegistry {
  private var stores: [String: ConversationStore] = [:]
  /// Least recently opened first.
  private var recent: [String] = []
  private let capacity: Int
  /// Session IDs on the navigation stack, which are never released.
  var stack: () -> Set<String> = { [] }

  init(capacity: Int = 5) {
    self.capacity = max(1, capacity)
  }

  func store(_ id: String, make: () -> ConversationStore) -> ConversationStore {
    let store = stores[id] ?? make()
    stores[id] = store
    recent.removeAll { $0 == id }
    recent.append(id)
    trim()
    return store
  }

  func existing(_ id: String) -> ConversationStore? { stores[id] }

  func remove(_ ids: Set<String>) {
    for id in ids { stores[id] = nil }
    recent.removeAll { ids.contains($0) }
  }

  /// Under memory pressure, conversations off the stack go; those on it drop what they can fetch again.
  func releaseMemory() {
    let kept = stack()
    remove(Set(stores.keys).subtracting(kept))
    for store in stores.values { store.memory.releaseCaches() }
  }

  private func trim() {
    let kept = stack()
    while stores.count > capacity, let victim = recent.first(where: { !kept.contains($0) }) {
      remove([victim])
    }
  }
}

/// Per-conversation reading and presentation state that outlives the screen: the exact passage on screen
/// when it was last left or hidden, prompt and disclosure expansion, fetched tool output and table offsets.
@MainActor @Observable final class TranscriptMemory {
  /// The passage last on screen, always a message and offset (even at the end), never persisted.
  @ObservationIgnored var anchor: ReadingPosition?
  private(set) var bubbles: [String: Bool] = [:]
  private(set) var details: [String: Bool] = [:]
  private(set) var outputs: [String: String] = [:]
  @ObservationIgnored private var tableOffsets: [String: CGFloat] = [:]

  func bubble(_ id: String) -> Bool { bubbles[id] ?? false }
  func setBubble(_ id: String, expanded: Bool) { bubbles[id] = expanded }
  func detail(_ key: String) -> Bool? { details[key] }
  func setDetail(_ key: String, expanded: Bool) { details[key] = expanded }
  func output(_ key: String) -> String? { outputs[key] }
  func setOutput(_ key: String, value: String?) { outputs[key] = value }
  func tableOffset(_ key: String) -> CGFloat { tableOffsets[key] ?? 0 }
  func setTableOffset(_ key: String, value: CGFloat) { tableOffsets[key] = value }

  /// Fetched output can be read again on demand; expansion and offsets are the reader's own choices.
  func releaseCaches() { outputs = [:] }
}

extension EnvironmentValues {
  @Entry var transcriptMemory: TranscriptMemory? = nil
}
