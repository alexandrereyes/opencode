import OpenCodeKit
import SwiftUI

struct ResponseBlocks: View {
  @Environment(\.appTheme) private var theme
  let blocks: [MarkdownBlock]
  let source: String
  let messageID: String
  let partID: String
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let openNote: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
        VStack(alignment: .leading, spacing: 8) {
          if case .footnote = block.kind, index == 0 || !isFootnote(blocks[index - 1]) {
            Text("Notas").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.color(.markdownHeading))
          }
          HStack(alignment: .top, spacing: 12.8) {
            ForEach(0..<block.quoteDepth, id: \.self) { _ in
              Rectangle().fill(theme.color(.markdownQuoteBorder)).frame(width: 2)
            }
            ResponseBlock(block: block, source: source, messageID: messageID, partID: partID, rasters: rasters, openNote: openNote)
          }
          .padding(.leading, block.indent)
        }
        .padding(.top, spacing(index))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func isFootnote(_ block: MarkdownBlock) -> Bool { if case .footnote = block.kind { true } else { false } }
  private func spacing(_ index: Int) -> CGFloat {
    guard index > 0 else { return 0 }
    if case .heading = blocks[index].kind { return 20 }
    if blocks[index].marker != nil && blocks[index - 1].marker != nil { return 4 }
    if isFootnote(blocks[index]) && !isFootnote(blocks[index - 1]) { return 20 }
    return 10.4
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
    case .image(let source): FeedImageView(source: source, name: block.text)
    case .rule: Rectangle().fill(theme.color(.markdownRule)).frame(height: 1)
    case .code(let language):
      if language?.lowercased() == "mermaid" {
        ResponseDiagram(block: block, messageID: messageID, partID: partID)
      } else {
        ResponseCode(block: block, messageID: messageID, partID: partID)
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
        Text("\(number).").font(.system(size: 14)).foregroundStyle(theme.color(.textSecondary)).frame(width: 24, alignment: .trailing)
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
  @State private var expanded: Bool
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
    _expanded = State(initialValue: initiallyOpen || arguments.contains("-OpenCodeMarkdownFixture") && arguments.contains("-OpenCodeMarkdownExpandDetails"))
    #else
    _expanded = State(initialValue: initiallyOpen)
    #endif
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { expanded.toggle(); selection?.selected() } label: {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "chevron.right").font(.system(size: 14)).frame(width: 14, height: 26).rotationEffect(.degrees(expanded ? 90 : 0))
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
        }
      }
      .frame(height: metrics.height).padding(.vertical, 6.5)
      .accessibilityElement(children: .ignore).accessibilityLabel("Fórmula: " + formula.source)
      .contextMenu {
        Button("Copiar fórmula") {
          UIPasteboard.general.string = formula.source
          Haptics.play(.selection)
          toast.show("Fórmula copiada")
        }
      }
    } else { fallback }
  }
}
