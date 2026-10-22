import OpenCodeKit
import SwiftUI

struct ResponseSelectionActions {
  let comment: (ChatQuote) -> Void
  let sideQuestion: (String) -> Void
}
struct ResponseSelectionObserver {
  let selected: () -> Void
}
extension EnvironmentValues {
  @Entry var responseSelection: ResponseSelectionActions? = nil
  @Entry var responseSelectionChanged: ResponseSelectionObserver? = nil
}

final class ResponseTextView: UITextView {
  var messageID = ""
  var partID = ""
  var sourceBlock: MarkdownBlock?
  var source = ""
  var selectionActions: ResponseSelectionActions?
  var selectionChanged: (() -> Void)?
  var selectionSourceRange: NSRange? { sourceBlock?.sourceRange(for: selectedRange) }
  func clearSelection() {
    selectedRange = NSRange(location: 0, length: 0)
    resignFirstResponder()
  }
}

struct SelectableResponseText: UIViewRepresentable {
  let block: MarkdownBlock
  let messageID: String
  let partID: String
  let theme: AppTheme
  var source = ""
  var actions: ResponseSelectionActions? = nil
  var selectionChanged: (() -> Void)? = nil

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> ResponseTextView {
    // The ObjC textViewUsingTextLayoutManager factory bypasses Swift subclass defaults.
    // The designated initializer uses TextKit 2 by default on our deployment target.
    let view = ResponseTextView(frame: .zero, textContainer: nil)
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = false
    view.delegate = context.coordinator
    view.backgroundColor = theme.uiColor(.background).withAlphaComponent(0)
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
  func updateUIView(_ view: ResponseTextView, context: Context) {
    if view.messageID != messageID || view.partID != partID || view.sourceBlock != block {
      view.clearSelection()
    }
    view.messageID = messageID
    view.accessibilityIdentifier = "response-\(messageID)-\(partID)"
    view.partID = partID
    view.sourceBlock = block
    view.source = source
    view.selectionActions = actions
    view.selectionChanged = selectionChanged
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
  static func dismantleUIView(_ view: ResponseTextView, coordinator: Coordinator) {
    view.clearSelection()
    view.attributedText = nil
    view.sourceBlock = nil
    view.source = ""
    view.selectionActions = nil
    view.selectionChanged = nil
    view.delegate = nil
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
      guard textView.selectedRange.length > 0 else { return }
      (textView as? ResponseTextView)?.selectionChanged?()
    }
    func textView(
      _ textView: UITextView, editMenuForTextIn range: NSRange,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      guard let view = textView as? ResponseTextView, let actions = view.selectionActions,
        let block = view.sourceBlock,
        let quote = ChatQuote.selection(
          source: view.source, block: block, range: range,
          messageID: view.messageID, partID: view.partID)
      else { return UIMenu(children: suggestedActions) }
      let custom = UIMenu(
        options: .displayInline,
        children: [
          UIAction(title: "Comentar") { [weak view] _ in
            view?.clearSelection()
            actions.comment(quote)
          },
          UIAction(title: "Pergunta paralela") { [weak view] _ in
            view?.clearSelection()
            actions.sideQuestion(quote.text)
          },
        ])
      return UIMenu(
        children: Array(suggestedActions.prefix(1)) + [custom] + suggestedActions.dropFirst())
    }
  }
}

struct ResponseMarkdown: View {
  @Environment(\.appTheme) private var theme
  @Environment(ToastCenter.self) private var toast
  @Environment(\.responseSelection) private var selectionActions
  @Environment(\.responseSelectionChanged) private var selectionChanged
  let text: String
  let messageID: String
  let partID: String
  @State private var blocks: [MarkdownBlock] = []
  @State private var measuredHeight: CGFloat?
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
                toast.show("Código copiado")
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Copiar código")
            }.foregroundStyle(theme.color(.textSecondary))
            SelectableResponseText(
              block: block, messageID: messageID, partID: partID, theme: theme,
              selectionChanged: selectionChanged?.selected)
          }
          .padding(12).background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 10))
          .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 0.5)
          }
        default:
          HStack(alignment: .top, spacing: 10) {
            if block.kind == .quote { Rectangle().fill(theme.color(.border)).frame(width: 3) }
            SelectableResponseText(
              block: block, messageID: messageID, partID: partID, theme: theme,
              source: text, actions: selectionActions, selectionChanged: selectionChanged?.selected)
          }
          .padding(.leading, CGFloat(max(0, block.depth - 1)) * 15)
          .padding(block.kind == .table ? 8 : 0)
          .background(
            block.kind == .table ? theme.color(.codeSurface) : theme.color(.background).opacity(0))
        }
      }
    }
    .frame(minHeight: blocks.isEmpty ? measuredHeight : nil)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: { _, height in
      if !blocks.isEmpty { measuredHeight = height }
    }
    .task(id: text) {
      let source = text
      let parsed = await Task.detached(priority: .userInitiated) { MarkdownBlocks.parse(source) }
        .value
      if !Task.isCancelled { blocks = parsed }
    }
    .onDisappear { blocks = [] }
  }
}
