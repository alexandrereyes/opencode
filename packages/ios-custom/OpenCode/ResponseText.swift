import OpenCodeKit
import SwiftUI

/// Non-editable TextKit 2 text. Wave 4 can override editMenu(for:suggestedActions:)
/// and use selectionSourceRange without changing the transcript or its stable part IDs.
final class ResponseTextView: UITextView {
  var messageID = ""
  var partID = ""
  var sourceBlock: MarkdownBlock?
  var selectionSourceRange: NSRange? { sourceBlock?.sourceRange(for: selectedRange) }
}

struct SelectableResponseText: UIViewRepresentable {
  let block: MarkdownBlock
  let messageID: String
  let partID: String
  let theme: AppTheme

  func makeUIView(context: Context) -> ResponseTextView {
    let view = ResponseTextView(usingTextLayoutManager: true)
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = false
    view.backgroundColor = theme.uiColor(.background).withAlphaComponent(0)
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
  func updateUIView(_ view: ResponseTextView, context: Context) {
    view.messageID = messageID
    view.partID = partID
    view.sourceBlock = block
    view.tintColor = theme.uiColor(.primary)
    let text = NSMutableAttributedString()
    let heading: Int? = { if case .heading(let level) = block.kind { level } else { nil } }()
    let codeBlock: Bool = { if case .code = block.kind { true } else { false } }()
    for run in block.runs {
      let size: CGFloat = heading.map { CGFloat(max(18, 27 - $0 * 2)) } ?? (codeBlock ? 14 : 16)
      let base =
        run.code || codeBlock
        ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        : UIFont.systemFont(
          ofSize: size, weight: heading != nil || run.strong ? .semibold : .regular)
      let font =
        run.emphasis
        ? UIFont(
          descriptor: base.fontDescriptor.withSymbolicTraits(.traitItalic) ?? base.fontDescriptor,
          size: size) : base
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = codeBlock ? 3 : 4
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: theme.uiColor(run.code && !codeBlock ? .inlineCode : .textStrong),
        .paragraphStyle: paragraph,
      ]
      if run.code && !codeBlock {
        attributes[.backgroundColor] = theme.uiColor(.inlineCodeBackground)
      }
      if let link = run.link, let url = URL(string: link),
        ["http", "https", "mailto"].contains(url.scheme)
      {
        attributes[.link] = url
      }
      text.append(NSAttributedString(string: run.text, attributes: attributes))
    }
    if view.attributedText != text { view.attributedText = text }
    view.linkTextAttributes = [
      .foregroundColor: theme.uiColor(.primary), .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ResponseTextView, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width, width > 0 else { return nil }
    return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
  }
}

struct ResponseMarkdown: View {
  @Environment(\.appTheme) private var theme
  let text: String
  let messageID: String
  let partID: String
  @State private var blocks: [MarkdownBlock] = []
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(blocks) { block in
        switch block.kind {
        case .rule: Divider().overlay(theme.color(.border))
        case .code:
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              if case .code(let language) = block.kind { Text(language ?? "Código").font(.caption) }
              Spacer()
              Button {
                UIPasteboard.general.string = block.text
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .accessibilityLabel("Copiar código")
            }.foregroundStyle(theme.color(.textSecondary))
            SelectableResponseText(block: block, messageID: messageID, partID: partID, theme: theme)
          }
          .padding(12).background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 10))
          .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 0.5)
          }
        default:
          HStack(alignment: .top, spacing: 10) {
            if block.kind == .quote { Rectangle().fill(theme.color(.border)).frame(width: 3) }
            SelectableResponseText(block: block, messageID: messageID, partID: partID, theme: theme)
          }
          .padding(.leading, CGFloat(max(0, block.depth - 1)) * 15)
          .padding(block.kind == .table ? 8 : 0)
          .background(
            block.kind == .table ? theme.color(.codeSurface) : theme.color(.background).opacity(0))
        }
      }
    }
    .task(id: text) {
      let source = text
      let parsed = await Task.detached(priority: .userInitiated) { MarkdownBlocks.parse(source) }
        .value
      if !Task.isCancelled { blocks = parsed }
    }
  }
}
