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

  /// The conversation's store, created on first use. Looking one up is not an opening: SwiftUI rebuilds a
  /// destination's view value whenever its parent renders, so recency changes only through `touch`.
  func store(_ id: String, make: () -> ConversationStore) -> ConversationStore {
    if let store = stores[id] { return store }
    let store = make()
    stores[id] = store
    touch(id)
    return store
  }

  /// Marks a conversation as the most recently shown one.
  func touch(_ id: String) {
    guard stores[id] != nil else { return }
    recent.removeAll { $0 == id }
    recent.append(id)
    trim()
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
/// Each key is observed on its own, so a shell output polled every second re-renders only the row showing it.
@MainActor final class TranscriptMemory {
  /// The passage last on screen, always a message and offset (even at the end), never persisted.
  var anchor: ReadingPosition?
  let state = TranscriptState()
  let heights = TranscriptHeights()
  /// The prompt sent from this screen that may rise to the top, with trailing space below it.
  var spacerPrompt: String?
  /// The transcript view kept with the conversation; returning remounts this very view.
  var controller: TranscriptViewController?
  private var mounted: [WeakTranscript] = []
  /// The mounted transcript that commands from the conversation screen act on: the most recently mounted.
  var active: TranscriptViewController? { mounted.last?.controller }

  func mount(_ controller: TranscriptViewController) {
    mounted.removeAll { $0.controller == nil || $0.controller === controller }
    mounted.append(WeakTranscript(controller: controller))
  }
  func unmount(_ controller: TranscriptViewController) {
    mounted.removeAll { $0.controller == nil || $0.controller === controller }
  }
  private struct WeakTranscript {
    weak var controller: TranscriptViewController?
  }
  private var bubbles: [String: TranscriptValue<Bool>] = [:]
  private var truncations: [String: TranscriptValue<Bool>] = [:]
  private var details: [String: TranscriptValue<Bool?>] = [:]
  private var outputs: [String: TranscriptValue<String?>] = [:]
  private var tableOffsets: [String: CGFloat] = [:]

  func bubble(_ id: String) -> Bool { Self.entry(&bubbles, id, false).value }
  func truncated(_ id: String) -> Bool { Self.entry(&truncations, id, false).value }
  func setTruncated(_ id: String, value: Bool) { Self.entry(&truncations, id, false).value = value }
  func setBubble(_ id: String, expanded: Bool) { Self.entry(&bubbles, id, false).value = expanded }
  func detail(_ key: String) -> Bool? { Self.entry(&details, key, nil).value }
  func setDetail(_ key: String, expanded: Bool) { Self.entry(&details, key, nil).value = expanded }
  func output(_ key: String) -> String? { Self.entry(&outputs, key, nil).value }
  func setOutput(_ key: String, value: String?) { Self.entry(&outputs, key, nil).value = value }
  func tableOffset(_ key: String) -> CGFloat { tableOffsets[key] ?? 0 }
  func setTableOffset(_ key: String, value: CGFloat) { tableOffsets[key] = value }

  /// Fetched output can be read again on demand, and an unmounted view rebuilt from cached heights;
  /// expansion, offsets and the reading place are the reader's own state.
  func releaseCaches() {
    outputs.values.forEach { $0.value = nil }
    if controller?.mounted == false { controller = nil }
  }

  /// The observable box for one key; a reader of an absent key still observes its later value.
  private static func entry<Value>(
    _ table: inout [String: TranscriptValue<Value>], _ key: String, _ initial: Value
  ) -> TranscriptValue<Value> {
    if let box = table[key] { return box }
    let box = TranscriptValue(initial)
    table[key] = box
    return box
  }
}

@MainActor @Observable final class TranscriptValue<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

extension EnvironmentValues {
  @Entry var transcriptMemory: TranscriptMemory? = nil
}
