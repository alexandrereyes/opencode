import OpenCodeKit
import SwiftUI

extension EnvironmentValues {
  @Entry var responseFilesStable = true
}

actor ResponseFileExistence {
  static let shared = ResponseFileExistence()
  private var found: [String: (FileLinkTarget?, Date)] = [:]
  private var pending: [String: Task<FileLinkTarget?, Never>] = [:]
  func target(_ source: String, context: ConversationImageContext) async -> FileLinkTarget? {
    let key = FeedImageLoader.cacheKey(source, configuration: context.client.configuration, directory: context.directory)
    if let value = found[key], Date.now.timeIntervalSince(value.1) < 60 { return value.0 }
    if let task = pending[key] { return await task.value }
    let task = Task { (try? await context.client.fileLinkTarget(source, directory: context.directory)) ?? nil }
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
  /// Inline code naming a server file or folder becomes a link; an explicit local link to a folder opens the
  /// explorer instead of the viewer. `targets` is keyed by the run's local path.
  func applyFileLinks(_ targets: [String: FileLinkTarget]) {
    guard let block = sourceBlock, !targets.isEmpty else { return }
    if case .code = block.kind { return }
    let text = NSMutableAttributedString(attributedString: attributedText)
    var offset = 0
    for run in block.runs {
      defer { offset += run.text.utf16.count }
      guard let (path, explicit) = ResponseFileLinks.path(run), let target = targets[path] else { continue }
      let link: URL
      switch target {
      case .directory(let folder): link = FileReference.folderLink(folder)
      case .file:
        // An explicit link already opens its file.
        guard !explicit else { continue }
        link = FileReference.link(path)
      }
      for range in displayRanges(NSRange(location: offset, length: run.text.utf16.count)) {
        text.addAttribute(.link, value: link, range: range)
        if !explicit {
          text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: (text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor ?? tintColor).withAlphaComponent(0.4)], range: range)
        }
      }
    }
    if attributedText != text { replaceText(text) }
  }
}

enum ResponseFileLinks {
  /// The local path a run may name: unlinked inline code, or an explicit local Markdown link.
  static func path(_ run: MarkdownRun) -> (String, explicit: Bool)? {
    if let link = run.link {
      guard let path = FileReference.local(link) else { return nil }
      return (path.removingPercentEncoding ?? path, true)
    }
    guard run.code, let path = FileReference.inline(run.text) else { return nil }
    return (path, false)
  }
}

extension SelectableResponseText.Coordinator {
  func resolveFiles(_ view: ResponseTextView, block: MarkdownBlock, context: ConversationImageContext?) {
    guard let context else { return }
    if case .code = block.kind { return }
    let paths = Array(Set(block.runs.compactMap { ResponseFileLinks.path($0)?.0 })).sorted()
    // An in-memory identity of this lookup only; hashing it ran for every block on every update.
    let key = paths.isEmpty ? nil : ([context.client.configuration.url.absoluteString, context.directory] + paths)
      .joined(separator: "\u{0}")
    guard key != fileKey else { return }
    fileTask?.cancel()
    fileKey = key
    knownFiles = [:]
    guard let key else { return }
    fileTask = Task { @MainActor [weak self, weak view] in
      for path in paths {
        let target = await ResponseFileExistence.shared.target(path, context: context)
        guard !Task.isCancelled, let self, self.fileKey == key, let view, view.sourceBlock == block else { return }
        guard let target else { continue }
        self.knownFiles[path] = target
        view.applyFileLinks(self.knownFiles)
      }
    }
  }
}
