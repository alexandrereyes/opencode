import OpenCodeKit
import SwiftUI

extension EnvironmentValues {
  @Entry var responseFilesStable = true
}

actor ResponseFileExistence {
  static let shared = ResponseFileExistence()
  private var found: [String: (Bool, Date)] = [:]
  private var pending: [String: Task<Bool, Never>] = [:]
  func exists(_ source: String, context: ConversationImageContext) async -> Bool {
    let key = FeedImageLoader.cacheKey(source, configuration: context.client.configuration, directory: context.directory)
    if let value = found[key], Date.now.timeIntervalSince(value.1) < 60 { return value.0 }
    if let task = pending[key] { return await task.value }
    let task = Task {
      do {
        return try await !context.client.fileLinkMatches(source, directory: context.directory).isEmpty
      } catch { return false }
    }
    pending[key] = task
    let value = await task.value
    pending[key] = nil
    found[key] = (value, .now)
    if found.count > 512, let oldest = found.min(by: { $0.value.1 < $1.value.1 })?.key {
      found.removeValue(forKey: oldest)
    }
    return value
  }
}

extension ResponseTextView {
  func applyFileLinks(_ paths: Set<String>) {
    guard let block = sourceBlock, !paths.isEmpty else { return }
    if case .code = block.kind { return }
    let text = NSMutableAttributedString(attributedString: attributedText)
    var offset = 0
    for run in block.runs {
      defer { offset += run.text.utf16.count }
      guard run.code, run.link == nil, let path = FileReference.inline(run.text), paths.contains(path) else { continue }
      for range in displayRanges(NSRange(location: offset, length: run.text.utf16.count)) {
        text.addAttribute(.link, value: FileReference.link(path), range: range)
        text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
          .underlineColor: (text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor ?? tintColor).withAlphaComponent(0.4)], range: range)
      }
    }
    if attributedText != text { attributedText = text }
  }
}

extension SelectableResponseText.Coordinator {
  func resolveFiles(_ view: ResponseTextView, block: MarkdownBlock, context: ConversationImageContext?) {
    guard let context else { return }
    if case .code = block.kind { return }
    let paths = Array(Set(block.runs.filter { $0.code && $0.link == nil }.compactMap { FileReference.inline($0.text) })).sorted()
    // An in-memory identity of this lookup only; hashing it ran for every block on every update.
    let key = paths.isEmpty ? nil : ([context.client.configuration.url.absoluteString, context.directory] + paths)
      .joined(separator: "\u{0}")
    guard key != fileKey else { return }
    fileTask?.cancel()
    fileKey = key
    knownFiles = []
    guard let key else { return }
    fileTask = Task { @MainActor [weak self, weak view] in
      for path in paths {
        let exists = await ResponseFileExistence.shared.exists(path, context: context)
        guard !Task.isCancelled, let self, self.fileKey == key, let view, view.sourceBlock == block else { return }
        if exists { self.knownFiles.insert(path) }
        view.applyFileLinks(self.knownFiles)
      }
    }
  }
}
