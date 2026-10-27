import OpenCodeKit
import SwiftUI

extension EnvironmentValues {
  /// Agent responses join consecutive prose blocks into one selectable text.
  @Entry var responseProse = false
}

struct ResponseBlocks: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.responseProse) private var joinsProse
  @Environment(\.responseFilesStable) private var stable
  let blocks: [MarkdownBlock]
  let source: String
  let messageID: String
  let partID: String
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let openNote: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(sections) { section in
        switch section {
        case .prose(let prose):
          ResponseProseText(prose: prose, source: source, messageID: messageID, partID: partID, rasters: rasters,
            openNote: openNote)
            .padding(.top, prose.spacing.first ?? 0)
        case .block(let block):
          let index = blocks.firstIndex { $0.id == block.id } ?? 0
          ResponseBlockItem(block: block, source: source, messageID: messageID, partID: partID, rasters: rasters,
            openNote: openNote, notesHeader: isFootnote(block) && (index == 0 || !isFootnote(blocks[index - 1])))
            .padding(.top, MarkdownBlocks.spacing(block, after: index > 0 ? blocks[index - 1] : nil))
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  /// Prose joins once the response completes; while it streams, each block keeps its own text.
  private var sections: [MarkdownSection] {
    joinsProse ? MarkdownBlocks.sections(blocks, streaming: !stable) : blocks.map { .block($0) }
  }
  private func isFootnote(_ block: MarkdownBlock) -> Bool { if case .footnote = block.kind { true } else { false } }
}

/// One block other than prose, with its quotation borders, indentation and, for the first footnote, the
/// notes heading. The transcript lays each one out as its own item.
struct ResponseBlockItem: View {
  @Environment(\.appTheme) private var theme
  let block: MarkdownBlock
  let source: String
  let messageID: String
  let partID: String
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let openNote: (String) -> Void
  var notesHeader = false
  var body: some View {
    // Every stack level re-measures its children on each layout pass; most blocks need neither.
    if notesHeader {
      VStack(alignment: .leading, spacing: 8) {
        Text("Notas").appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.markdownHeading))
        quoted
      }
    } else {
      quoted
    }
  }
  @ViewBuilder private var quoted: some View {
    let content = ResponseBlock(block: block, source: source, messageID: messageID, partID: partID, rasters: rasters, openNote: openNote)
    if block.quoteDepth > 0 {
      HStack(alignment: .top, spacing: 12.8) {
        ForEach(0..<block.quoteDepth, id: \.self) { _ in
          Rectangle().fill(theme.color(.markdownQuoteBorder)).frame(width: 2)
        }
        content
      }
      .padding(.leading, block.indent)
    } else {
      content.padding(.leading, block.indent)
    }
  }
}

/// Paragraphs, headings, list items, quotations and rules of one part as a single text, so a
/// selection, copy or quotation can span them; indentation and borders are part of the text.
private struct ResponseProseText: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.responseSelection) private var actions
  @Environment(\.responseSelectionChanged) private var selection
  @Environment(\.conversationSearch) private var highlights
  let prose: MarkdownProse
  let source: String
  let messageID: String
  let partID: String
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let openNote: (String) -> Void
  var body: some View {
    SelectableResponseText(block: prose.block, messageID: messageID, partID: partID, theme: theme, prose: prose,
      source: source, actions: actions, selectionChanged: selection?.selected,
      highlights: highlights, rasters: rasters, openNote: openNote)
  }
}

private struct ResponseBlock: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.responseSelection) private var actions
  @Environment(\.responseSelectionChanged) private var selection
  @Environment(\.conversationSearch) private var highlights
  let block: MarkdownBlock
  let source: String
  let messageID: String
  let partID: String
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let openNote: (String) -> Void
  var body: some View {
    switch block.kind {
    case .image(let source):
      if FileViewerKind(path: source) == .audiovisual {
        FileMediaReference(source: source, name: block.text)
      } else { FeedImageView(source: source, name: block.text) }
    case .rule: Rectangle().fill(theme.color(.markdownRule)).frame(height: 1)
    case .code(let language):
      if language?.lowercased() == "mermaid" {
        ResponseDiagram(block: block, messageID: messageID, partID: partID)
      } else {
        ResponseCode(source: source, block: block, messageID: messageID, partID: partID)
      }
    case .table:
      if let table = block.table {
        ResponseTable(block: block, table: table, source: source, messageID: messageID, partID: partID, rasters: rasters, openNote: openNote)
      } else { text }
    case .formula:
      ResponseFormulaBlock(block: block, rasters: rasters, fallback: text)
    case .details(_, let open):
      ResponseDisclosure(block: block, source: source, messageID: messageID, partID: partID,
        rasters: rasters, openNote: openNote, initiallyOpen: open)
    case .footnote(_, let number):
      HStack(alignment: .top, spacing: 8) {
        Text("\(number).").appFont(.secondary).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).frame(width: 24, alignment: .trailing)
        AnyView(ResponseBlocks(blocks: block.children, source: source, messageID: messageID, partID: partID, rasters: rasters, openNote: openNote))
      }
    default: text
    }
  }
  private var text: some View {
    SelectableResponseText(block: block, messageID: messageID, partID: partID, theme: theme,
      source: source, actions: actions, selectionChanged: selection?.selected,
      highlights: highlights, rasters: rasters, openNote: openNote)
  }
}

private struct ResponseDisclosure: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.responseSelectionChanged) private var selection
  @Environment(\.transcriptMemory) private var memory
  @State private var initial: Bool
  /// The conversation's memory keeps the reader's choice when the response is rebuilt.
  private var expanded: Bool { memory?.detail(key) ?? initial }
  private var key: String { "\(messageID):\(partID):\(block.id)" }
  let block: MarkdownBlock
  let source: String
  let messageID: String
  let partID: String
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let openNote: (String) -> Void
  init(block: MarkdownBlock, source: String, messageID: String, partID: String,
    rasters: [ResponseFormulaKey: ResponseFormulaRaster], openNote: @escaping (String) -> Void, initiallyOpen: Bool) {
    self.block = block
    self.source = source
    self.messageID = messageID
    self.partID = partID
    self.rasters = rasters
    self.openNote = openNote
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    _initial = State(initialValue: initiallyOpen || arguments.contains("-OpenCodeMarkdownFixture") && arguments.contains("-OpenCodeMarkdownExpandDetails"))
    #else
    _initial = State(initialValue: initiallyOpen)
    #endif
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        if let memory { memory.setDetail(key, expanded: !expanded) } else { initial.toggle() }
        selection?.selected()
      } label: {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "chevron.right").appSymbol(.inline).frame(width: 14, height: 26).rotationEffect(.degrees(expanded ? 90 : 0))
          SelectableResponseText(block: block, messageID: messageID, partID: partID, theme: theme,
            rasters: rasters, openNote: openNote).allowsHitTesting(false)
          Spacer(minLength: 0)
        }.frame(minHeight: 26).padding(.vertical, 6).contentShape(Rectangle())
      }
      .buttonStyle(.plain).foregroundStyle(theme.color(.markdownBody))
      .accessibilityLabel(block.copyText.isEmpty ? "Detalhes" : block.copyText)
      .accessibilityValue(expanded ? "Expandido" : "Recolhido")
      .accessibilityIdentifier("markdown-details-\(block.id)")
      if expanded {
        AnyView(ResponseBlocks(blocks: block.children, source: source, messageID: messageID, partID: partID, rasters: rasters, openNote: openNote))
          .padding(.leading, 20).padding(.top, 6)
      }
    }
  }
}

private struct ResponseFormulaBlock<Fallback: View>: View {
  @Environment(\.appTheme) private var theme
  @Environment(ToastCenter.self) private var toast
  let block: MarkdownBlock
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let fallback: Fallback
  var body: some View {
    if let formula = block.runs.first?.formula, let metrics = formula.metrics {
      GeometryReader { geometry in
        ScrollView(.horizontal) {
          Group {
            if let raster = rasters[ResponseFormulaKey(formula)], let image = UIImage(data: raster.png, scale: raster.scale) {
              Image(uiImage: image).frame(width: metrics.width, height: metrics.height)
            } else {
              Rectangle().fill(theme.color(.background).opacity(0)).frame(width: metrics.width, height: metrics.height)
            }
          }
          .frame(minWidth: geometry.size.width, minHeight: metrics.height)
          .background(ResponseFormulaMenu { copy(formula) })
        }
      }
      .frame(height: metrics.height).padding(.vertical, 6.5)
      .accessibilityElement(children: .ignore).accessibilityLabel("Fórmula: " + formula.source)
      .accessibilityAction(named: "Copiar fórmula") { copy(formula) }
    } else { fallback }
  }
  private func copy(_ formula: MarkdownFormula) {
    UIPasteboard.general.string = formula.source
    Haptics.play(.selection)
    toast.show("Fórmula copiada")
  }
}

/// A context menu on the formula alone. SwiftUI's `.contextMenu` inside a List row claims the whole
/// cell, so a long press anywhere in the response opened it instead of selecting text.
private struct ResponseFormulaMenu: UIViewRepresentable {
  let copy: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
    return view
  }
  func updateUIView(_ view: UIView, context: Context) { context.coordinator.copy = copy }
  final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
    var copy: (() -> Void)?
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
      UIContextMenuConfiguration(actionProvider: { [weak self] _ in
        UIMenu(children: [UIAction(title: "Copiar fórmula", image: UIImage(systemName: "doc.on.doc")) { _ in self?.copy?() }])
      })
    }
  }
}
