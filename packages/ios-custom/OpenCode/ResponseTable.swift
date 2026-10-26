import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

struct ResponseTable: View {
  @Environment(\.appTheme) private var theme
  @Environment(ToastCenter.self) private var toast
  @Environment(\.responseSelection) private var actions
  @Environment(\.responseSelectionChanged) private var selection
  @Environment(\.conversationSearch) private var highlights
  @Environment(\.conversationImages) private var imageContext
  @Environment(\.openFile) private var fileAction
  @Environment(\.responseFilesStable) private var filesStable
  @Environment(\.responseQuotes) private var quotes
  @AppStorage("OpenCodeMarkdownTableWrap") private var wrap = true
  @State private var exporting = false
  @State private var document = ResponseTextDocument(text: "")
  @State private var exportType = UTType.plainText
  let block: MarkdownBlock
  let table: MarkdownTable
  let source: String
  let messageID: String
  let partID: String
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let openNote: (String) -> Void

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 0) {
        Spacer()
        Button { wrap.toggle(); selection?.selected() } label: {
          Image(systemName: "text.word.spacing")
        }
        .accessibilityLabel(wrap ? "Desativar quebra das células" : "Ativar quebra das células")
        .accessibilityValue(wrap ? "Ativada" : "Desativada")
        .accessibilityIdentifier("markdown-table-wrap-\(block.id)")
        Menu {
          Button("Copiar CSV") { copy(table.delimited(",")) }
          Button("Copiar TSV") { copy(table.delimited("\t")) }
          Button("Copiar Markdown") { copy(table.markdown) }
        } label: { Image(systemName: "doc.on.doc") }
        .accessibilityLabel("Copiar tabela")
        Menu {
          Button("Exportar CSV") { export(table.delimited(","), type: .commaSeparatedText) }
          Button("Exportar Markdown") { export(table.markdown, type: ResponseTextDocument.markdownType) }
        } label: { Image(systemName: "square.and.arrow.up") }
        .accessibilityLabel("Exportar tabela")
      }
      .buttonStyle(MarkdownToolbarButton())
      .foregroundStyle(theme.color(.codeHeaderText))
      if table.rows.contains(where: { $0.contains { $0.contains { $0.image != nil } } }) {
        ResponseMediaTable(block: block, table: table, source: source, messageID: messageID,
          partID: partID, rasters: rasters, openNote: openNote, wrap: wrap)
      } else {
        ResponseTableContent(
          block: block, table: table, source: source, messageID: messageID, partID: partID,
          theme: theme, wrap: wrap, actions: actions, selected: selection?.selected,
          highlights: highlights, rasters: rasters, openNote: openNote,
          imageContext: imageContext, fileOpen: fileAction?.open, folderOpen: fileAction?.folder, filesStable: filesStable, quotes: quotes)
      }
    }
    .fileExporter(isPresented: $exporting, document: document, contentType: exportType,
      defaultFilename: exportType == .commaSeparatedText ? "tabela.csv" : "tabela.md") {
        if case .success = $0 { toast.show("Tabela exportada") }
    }
  }
  private func copy(_ text: String) {
    UIPasteboard.general.string = text
    Haptics.play(.selection)
    toast.show("Tabela copiada")
  }
  private func export(_ text: String, type: UTType) {
    document = ResponseTextDocument(text: text)
    exportType = type
    exporting = true
  }
}

struct MarkdownToolbarButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.appSymbol(.inline).frame(width: 36, height: 36)
      .opacity(configuration.isPressed ? 0.55 : 1)
      .contentShape(Rectangle())
  }
}

struct ResponseTextDocument: FileDocument {
  static let markdownType = UTType(filenameExtension: "md") ?? .plainText
  static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText, .svg, markdownType] }
  var text: String
  init(text: String) { self.text = text }
  init(configuration: ReadConfiguration) throws {
    text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

private struct ResponseTableContent: UIViewRepresentable {
  @Environment(\.dynamicTypeSize) private var typeSize
  let block: MarkdownBlock
  let table: MarkdownTable
  let source: String
  let messageID: String
  let partID: String
  let theme: AppTheme
  let wrap: Bool
  let actions: ResponseSelectionActions?
  let selected: (() -> Void)?
  let highlights: ConversationSearchHighlight
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let openNote: (String) -> Void
  let imageContext: ConversationImageContext?
  let fileOpen: ((String) -> Void)?
  let folderOpen: ((String) -> Void)?
  let filesStable: Bool
  let quotes: ResponseQuoteContext

  func makeUIView(context: Context) -> ResponseTableView { ResponseTableView() }
  func updateUIView(_ view: ResponseTableView, context: Context) {
    var changed = view.wrap != wrap
    if view.columns != table.alignments.count || view.cells.count != table.rows.count {
      changed = true
      view.cells.flatMap { $0 }.forEach { $0.clearSelection(); $0.removeFromSuperview() }
      view.cells = table.rows.map { row in row.map { _ in ResponseTextView(frame: .zero, textContainer: nil) } }
      view.coordinators = table.rows.map { row in row.map { _ in SelectableResponseText.Coordinator() } }
      view.cells.flatMap { $0 }.forEach {
        $0.isEditable = false
        $0.isSelectable = true
        $0.isScrollEnabled = false
        $0.backgroundColor = theme.uiColor(.tableSurface).withAlphaComponent(0)
        $0.textContainer.lineFragmentPadding = 0
        view.addSubview($0)
      }
    }
    view.columns = table.alignments.count
    view.accessibilityIdentifier = "markdown-table-content-\(block.id)"
    view.wrap = wrap
    view.backgroundColor = theme.uiColor(.tableSurface)
    view.border = theme.uiColor(.tableSeparator).withAlphaComponent(theme.value(.tableSeparator).opacity * 0.6)
    view.layer.borderColor = theme.uiColor(.tableBorder).withAlphaComponent(theme.value(.tableBorder).opacity * 0.8).cgColor
    for (row, cells) in table.rows.enumerated() {
      for (column, runs) in cells.enumerated() {
        let previous = view.coordinators[row][column].rendering
        let cell = SelectableResponseText(
          block: block.cell(runs, alignment: table.alignments[column]), messageID: messageID, partID: partID,
          theme: theme, source: source, actions: actions, selectionChanged: selected,
          highlights: highlights, rasters: rasters, wrap: wrap, tableHeader: row == 0, openNote: openNote,
          fileContextOverride: imageContext, fileOpenOverride: fileOpen, folderOpenOverride: folderOpen, filesStableOverride: filesStable,
          contentSizeOverride: typeSize.uiCategory, quotesOverride: quotes)
        view.cells[row][column].delegate = view.coordinators[row][column]
        cell.configure(view.cells[row][column], coordinator: view.coordinators[row][column])
        if previous != view.coordinators[row][column].rendering { changed = true }
      }
    }
    if changed { view.invalidateMeasurement() }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ResponseTableView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return CGSize(width: width, height: uiView.measure(width).height)
  }
  static func dismantleUIView(_ view: ResponseTableView, coordinator: Void) {
    view.cells.flatMap { $0 }.forEach { $0.clearSelection(); $0.delegate = nil }
  }
}

private final class ResponseTableView: UIScrollView {
  struct Measurement {
    let widths: [CGFloat]
    let heights: [CGFloat]
    var width: CGFloat { widths.reduce(0, +) }
    var height: CGFloat { heights.reduce(0, +) }
  }
  var cells: [[ResponseTextView]] = []
  var coordinators: [[SelectableResponseText.Coordinator]] = []
  var columns = 0
  var wrap = true
  var border = UIColor.clear
  private var measurements: [CGFloat: Measurement] = [:]
  private var separators: [CGRect] = []
  private var layoutWidth: CGFloat?
  override init(frame: CGRect) {
    super.init(frame: frame)
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = true
    isDirectionalLockEnabled = true
    layer.cornerRadius = 8
    layer.borderWidth = 1
    clipsToBounds = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }
  func invalidateMeasurement() {
    measurements.removeAll(keepingCapacity: true)
    layoutWidth = nil
    setNeedsLayout()
    setNeedsDisplay()
  }
  func measure(_ width: CGFloat) -> Measurement {
    if let cached = measurements[width] { return cached }
    guard columns > 0 else { return Measurement(widths: [], heights: []) }
    let natural = (0..<columns).map { column in
      max(120, cells.map { row in
        row[column].attributedText.boundingRect(with: CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width + 32
      }.max() ?? 120)
    }
    var widths = natural
    if wrap && natural.reduce(0, +) > width {
      var pending = Set(0..<columns)
      var remaining = max(width, CGFloat(columns) * 120)
      while !pending.isEmpty {
        let share = remaining / CGFloat(pending.count)
        let short = pending.filter { natural[$0] <= share }
        if short.isEmpty {
          pending.forEach { widths[$0] = share }
          break
        }
        short.forEach { widths[$0] = natural[$0]; remaining -= natural[$0]; pending.remove($0) }
      }
    }
    let extra = max(0, width - widths.reduce(0, +)) / CGFloat(columns)
    widths = widths.map { $0 + extra }
    let heights = cells.map { row in
      (row.enumerated().map { column, text in text.fittingSize(width: widths[column] - 32).height }.max() ?? 26) + 20
    }
    let result = Measurement(widths: widths, heights: heights)
    if measurements.count >= 8 { measurements.removeAll(keepingCapacity: true) }
    measurements[width] = result
    return result
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    guard layoutWidth != bounds.width else { return }
    layoutWidth = bounds.width
    let layout = measure(bounds.width)
    contentSize = CGSize(width: layout.width, height: layout.height)
    separators = []
    var y: CGFloat = 0
    for (row, texts) in cells.enumerated() {
      var x: CGFloat = 0
      for (column, text) in texts.enumerated() {
        let height = text.fittingSize(width: layout.widths[column] - 32).height
        text.frame = CGRect(x: x + 16, y: y + 10, width: layout.widths[column] - 32, height: height)
        x += layout.widths[column]
        if column < columns - 1 { separators.append(CGRect(x: x, y: y, width: 1, height: layout.heights[row])) }
      }
      y += layout.heights[row]
      if row < cells.count - 1 { separators.append(CGRect(x: 0, y: y, width: layout.width, height: 1)) }
    }
  }
  override func draw(_ rect: CGRect) {
    super.draw(rect)
    border.setFill()
    separators.forEach { UIBezierPath(rect: $0).fill() }
  }
}
