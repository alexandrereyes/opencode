import AppKit
import OpenCodeKit
import Quartz
import SwiftUI

/// A read-only source file in an `NSTextView` with line numbers, colored by the iPhone's highlight.js engine
/// (`ResponseEngines` + `markdown-engines.js`). Long lines scroll horizontally instead of wrapping.
struct MacCodeView: NSViewRepresentable {
  @Environment(\.appTheme) private var theme
  let text: String
  let path: String

  final class Coordinator {
    var shown: (text: String, theme: String)?
    var task: Task<Void, Never>?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let textView = scroll.documentView as! NSTextView
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.isRichText = true
    textView.textContainerInset = NSSize(width: 6, height: 10)
    textView.isHorizontallyResizable = true
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.setAccessibilityIdentifier("file-code")
    let ruler = LineNumberRuler(textView: textView, scrollView: scroll)
    scroll.verticalRulerView = ruler
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? NSTextView,
      context.coordinator.shown?.text != text || context.coordinator.shown?.theme != theme.id else { return }
    context.coordinator.shown = (text, theme.id)
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = 1.18
    let base: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: theme.nsColor(.codeText), .paragraphStyle: paragraph,
    ]
    textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: base))
    if let ruler = scroll.verticalRulerView as? LineNumberRuler {
      ruler.configure(text: text, font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        color: theme.nsColor(.codeLineNumber), separator: .clear)
    }
    context.coordinator.task?.cancel()
    guard let source = ContextColumn.highlightSource(text, path: path) else { return }
    let theme = theme
    context.coordinator.task = Task { @MainActor in
      let blocks = await ResponseEngines.shared.highlight(MarkdownBlocks.parse(source))
      guard !Task.isCancelled, let block = blocks.first, case .code = block.kind,
        let storage = textView.textStorage, storage.string == text else { return }
      var location = 0
      storage.beginEditing()
      for run in block.runs {
        let length = (run.text as NSString).length
        guard location + length <= storage.length else { break }
        // Desaturated: each token color halfway to the plain code color, so the code reads as text first.
        if let syntax = run.syntax {
          let color = theme.nsColor(syntax.role).blended(withFraction: 0.45, of: theme.nsColor(.codeText))
            ?? theme.nsColor(syntax.role)
          storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: location, length: length))
        }
        location += length
      }
      storage.endEditing()
    }
  }
}

/// Line numbers beside the text view, drawn for the visible lines only.
final class LineNumberRuler: NSRulerView {
  private var starts: [Int] = [0]
  private var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
  private var color = NSColor.secondaryLabelColor
  private var separator = NSColor.separatorColor

  init(textView: NSTextView, scrollView: NSScrollView) {
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 40
    NotificationCenter.default.addObserver(
      self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(text: String, font: NSFont, color: NSColor, separator: NSColor) {
    let utf16 = Array(text.utf16)
    starts = [0] + utf16.indices.filter { utf16[$0] == 10 }.map { $0 + 1 }
    self.font = font
    self.color = color
    self.separator = separator
    let digits = max(2, String(starts.count).count)
    ruleThickness = CGFloat(digits) * 8 + 22
    needsDisplay = true
  }

  @objc private func redraw() { needsDisplay = true }

  /// Numbers only, over the code's own background: no gutter fill.
  override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView = clientView as? NSTextView, let layout = textView.layoutManager,
      let container = textView.textContainer else { return }
    separator.setFill()
    NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    let visible = textView.visibleRect
    let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let first = max(0, (starts.lastIndex { $0 <= characters.location } ?? 0))
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    for line in first..<starts.count {
      let start = starts[line]
      if start > NSMaxRange(characters) { break }
      let glyph = layout.glyphIndexForCharacter(at: min(start, max(0, textView.string.utf16.count - 1)))
      let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let y = fragment.minY + textView.textContainerOrigin.y
      let point = convert(NSPoint(x: 0, y: y), from: textView)
      let label = "\(line + 1)" as NSString
      let size = label.size(withAttributes: attributes)
      label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: point.y + (fragment.height - size.height) / 2),
        withAttributes: attributes)
    }
  }
}

/// Quick Look for images, PDFs and everything that is not drawn as text.
struct MacQuickLook: NSViewRepresentable {
  let url: URL
  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .compact)!
    view.autostarts = true
    view.shouldCloseWithWindow = true
    return view
  }
  func updateNSView(_ view: QLPreviewView, context: Context) {
    if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
  }
}
