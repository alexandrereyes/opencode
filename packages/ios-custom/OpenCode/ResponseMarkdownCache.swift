import OpenCodeKit
import SwiftUI

@MainActor final class ResponseMarkdownCache {
  static let shared = ResponseMarkdownCache()
  private let values = NSCache<NSString, Entry>()
  private var pending: [String: Task<[MarkdownBlock], Never>] = [:]

  init() {
    values.countLimit = 256
    values.totalCostLimit = 16 * 1024 * 1024
  }

  func cached(_ source: String) -> [MarkdownBlock]? {
    values.object(forKey: source as NSString)?.blocks
  }

  func parse(_ source: String) async -> [MarkdownBlock] {
    if let blocks = cached(source) { return blocks }
    if let task = pending[source] { return await task.value }
    let task = Task.detached(priority: .userInitiated) { MarkdownBlocks.parse(source) }
    pending[source] = task
    let blocks = await task.value
    values.setObject(
      Entry(blocks: blocks), forKey: source as NSString,
      cost: source.utf16.count * 2 + blocks.reduce(0) { count, block in
        count + block.runs.reduce(0) { $0 + $1.offsets.count * MemoryLayout<Int?>.stride + $1.text.utf16.count * 2 }
      })
    pending[source] = nil
    return blocks
  }

  func prepare(_ messages: [ConversationMessage]) async {
    for message in messages {
      for part in message.content ?? [] where part.type == "text" {
        guard !Task.isCancelled else { return }
        if let source = part.text, cached(source) == nil { _ = await parse(source) }
      }
    }
  }

  private final class Entry {
    let blocks: [MarkdownBlock]
    init(blocks: [MarkdownBlock]) { self.blocks = blocks }
  }
}
