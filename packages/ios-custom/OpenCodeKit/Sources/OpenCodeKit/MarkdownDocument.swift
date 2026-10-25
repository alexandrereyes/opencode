import Foundation

/// A Markdown file shown by the file viewer, rendered with the response engine.
public enum MarkdownDocument {
  /// One lazily mounted slice of a document and the space above it.
  public struct Chunk: Sendable, Equatable, Identifiable {
    public let blocks: [MarkdownBlock]
    public let spacing: Double
    public var id: Int { blocks.first?.id ?? 0 }
  }

  /// Response text is drawn whole (a conversation row is short and recycled), so a document is split into
  /// slices that a lazy stack mounts only near the viewport. Each slice still joins its prose for selection.
  public static func chunks(_ blocks: [MarkdownBlock], limit: Int = 1_500, count: Int = 12) -> [Chunk] {
    var chunks: [Chunk] = []
    var current: [MarkdownBlock] = []
    var size = 0
    var previous: MarkdownBlock?
    func flush() {
      guard let first = current.first else { return }
      chunks.append(Chunk(blocks: current, spacing: MarkdownBlocks.spacing(first, after: previous)))
      previous = current.last
      current = []
      size = 0
    }
    for block in blocks {
      let weight = block.text.utf16.count + (block.table == nil ? 0 : 600) + block.children.reduce(0) { $0 + $1.text.utf16.count }
      if !current.isEmpty, size + weight > limit || current.count >= count { flush() }
      current.append(block)
      size += weight
    }
    flush()
    return chunks
  }

  /// A single block this long is one text view taller than many screens; the source view scrolls it efficiently.
  public static func oversized(_ blocks: [MarkdownBlock], limit: Int = 40_000) -> Bool {
    blocks.contains { $0.text.utf16.count > limit || oversized($0.children, limit: limit) }
  }

  /// YAML front matter is metadata, not a heading and a rule: it is shown as a YAML code block.
  public static func renderable(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
      let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) })
    else { return text }
    let yaml = lines[1..<end].joined(separator: "\n")
    let fence = yaml.contains("```") ? "````" : "```"
    return ([fence + "yaml", yaml, fence] + lines[(end + 1)...].map(String.init)).joined(separator: "\n")
  }

  /// A link inside a file resolves against that file's directory; web, mail and anchor links are not files.
  public static func linkedFile(_ link: String, from file: String) -> String? {
    guard !link.hasPrefix("#"), let path = FileReference.local(link) else { return nil }
    if path.hasPrefix("/") || path.hasPrefix("~") { return path }
    return URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(path).standardized.path
  }
}
