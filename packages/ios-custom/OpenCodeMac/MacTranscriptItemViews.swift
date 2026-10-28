import AppKit
import OpenCodeKit
import SwiftUI

/// The SwiftUI content of a hosted transcript item on the Mac. Prose is native and never reaches here; the rest
/// draws the iPhone's items (and its shared pieces in `OpenCode/ConversationColumn/` and the request cards) at
/// desktop density inside the centered content column.
struct MacTranscriptItemView: View {
  let item: TranscriptItem
  let context: MacTranscriptContext

  var body: some View {
    content.padding(.horizontal, padded ? context.inset : 0)
  }

  private var padded: Bool {
    switch item.kind {
    case .prompt, .pending, .older, .day: false
    default: true
    }
  }

  @ViewBuilder private var content: some View {
    switch item.kind {
    case .older(let loading):
      MacOlderRow(loading: loading, load: context.loadOlder)
    case .day(let created):
      MacDayChip(created: created)
    case .prompt(let message, let expanded):
      MacPromptRow(message: message.presented(isChild: context.store.isChild), pending: nil, expanded: expanded,
        context: context)
    case .pending(let inbox, let expanded):
      MacPromptRow(message: inbox.message, pending: inbox, expanded: expanded, context: context)
    case .prose, .unparsed:
      Color.clear
    case .block(let part, let block, let notes):
      MacResponseBlock(part: part, block: block, notes: notes, context: context)
    case .rule:
      MacRule()
    case .activity(let row, _, _):
      MacActivityRow(id: row.id, grouped: row.kind == .group, parts: row.parts, items: row.items,
        pending: row.pending, context: context)
    case .shell(let message, _):
      MacActivityRow(id: message.id, grouped: false,
        parts: message.tools.enumerated().map { index, part in
          ConversationActivityPart(id: part.id ?? "\(message.id):\(index)", messageID: message.id, part: part)
        }, items: [], pending: false, context: context)
    case .notice(let message):
      MacNotice(message: message)
    case .failure(let text, let warning):
      Text(text).appFont(.caption).foregroundStyle(context.theme.color(warning ? .warning : .error)).textSelection(.enabled)
    case .footer(let message):
      MacFooter(message: message, context: context)
    case .permission(let request):
      ConversationPermissionCard(request: request, store: context.store)
    case .question(let form):
      ConversationQuestionCard(form: form, store: context.store)
    }
  }
}

private struct MacOlderRow: View {
  @Environment(\.appTheme) private var theme
  let loading: Bool
  let load: () -> Void
  var body: some View {
    HStack {
      Spacer()
      if loading {
        ProgressView().controlSize(.small)
      } else {
        Button("Mensagens anteriores", action: load).buttonStyle(.plain).appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary))
      }
      Spacer()
    }
    .padding(.vertical, 6)
  }
}

private struct MacDayChip: View {
  @Environment(\.appTheme) private var theme
  let created: Double
  var body: some View {
    Text(ConversationProjection.day(created)).appFont(.footnote, weight: .medium)
      .foregroundStyle(theme.color(.textSecondary))
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(theme.color(.codeSurface), in: Capsule())
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)
  }
}

private struct MacRule: View {
  @Environment(\.appTheme) private var theme
  var body: some View { Rectangle().fill(theme.color(.borderStrong)).frame(height: 1).accessibilityHidden(true) }
}

private struct MacNotice: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  var body: some View {
    Text(message.notice).appFont(.caption)
      .foregroundStyle(theme.color(message.type == "idle" ? .warning : .textSecondary))
      .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
  }
}

// MARK: - Prompts

/// A user prompt on the right: the bubble (two lines, then Mostrar mensagem completa, like the iPhone), its
/// quotes and attachments, and below it Desfazer, Copiar and the time. The same row sits inline and pinned at the
/// top; clicking a pinned prompt brings its turn's first row right below it.
private struct MacPromptRow: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let pending: InboxItem?
  let expanded: Bool
  let context: MacTranscriptContext
  @State private var copied = false

  private var store: ConversationStore { context.store }
  private var bubbleTheme: AppTheme { pending == nil ? theme : theme.pendingUserBubble }
  private var text: String { message.displayText }
  private var folds: Bool {
    let quotes = !message.quotes.isEmpty
    return quotes || MacPromptRow.truncates(text, width: bubbleWidth)
  }
  /// The text's width inside the bubble: the content column less the 80-point spacer and the bubble's padding.
  private var bubbleWidth: CGFloat { max(120, min(760, context.width - context.inset * 2) - 80 - 28) }

  var body: some View {
    HStack {
      Spacer(minLength: 80)
      VStack(alignment: .trailing, spacing: 5) {
        bubble
        meta
      }
    }
    .padding(.horizontal, context.inset).padding(.vertical, 8)
    .background(theme.color(.background))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(pending == nil ? "conversation-user-\(message.id)" : "pending-user-\(message.id)")
  }

  private var bubble: some View {
    let shown = expanded || !folds
    let attachments = MacPromptAttachments(message)
    return VStack(alignment: .trailing, spacing: 8) {
      if shown {
        ForEach(message.quotes) { quote in
          MacQuoteCard(quote: quote).frame(maxWidth: 520)
        }
      }
      if !text.isEmpty {
        Text(text)
          .appFont(.message)
          .foregroundStyle(bubbleTheme.color(.userBubbleText))
          .lineLimit(shown ? nil : 2)
          .textSelection(.enabled)
          .multilineTextAlignment(.leading)
          .frame(maxHeight: shown ? context.viewport * 0.4 : nil, alignment: .top)
          .contentShape(Rectangle())
          .onTapGesture { tapped() }
      } else if !shown, !message.quotes.isEmpty {
        Label(message.quotes.map { $0.comment.isEmpty ? $0.text : $0.comment }.joined(separator: " · "),
          systemImage: "text.quote")
          .appFont(.message).lineLimit(2).foregroundStyle(bubbleTheme.color(.userBubbleSecondary))
      }
      if !attachments.files.isEmpty {
        HStack(spacing: 6) {
          ForEach(Array(attachments.files.enumerated()), id: \.offset) { _, name in
            Label(name, systemImage: "doc").lineLimit(1).frame(maxWidth: 160)
              .appFont(.caption).foregroundStyle(bubbleTheme.color(.userBubbleSecondary))
              .padding(.horizontal, 8).padding(.vertical, 2)
              .background(theme.color(.codeSurface).opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
      if shown, !attachments.images.isEmpty {
        HStack(spacing: 8) {
          ForEach(Array(attachments.images.enumerated()), id: \.offset) { _, image in
            MacFeedImage(source: image.source, name: image.name, size: 48, context: context)
          }
        }
      }
      if folds {
        Button(expanded ? "Mostrar menos" : "Mostrar mensagem completa") {
          context.store.memory.setBubble(message.id, expanded: !expanded)
        }
        .buttonStyle(.plain).appFont(.caption, weight: .medium)
        .foregroundStyle(bubbleTheme.color(.userBubbleSecondary))
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .background(bubbleTheme.color(.userBubble), in: RoundedRectangle(cornerRadius: 16))
  }

  @ViewBuilder private var meta: some View {
    HStack(spacing: 12) {
      if let pending, let status = store.pendingStatus(pending) {
        Text(status.waiting ? "Pendente" : "Enviando…").foregroundStyle(theme.color(status.waiting ? .warning : .textSecondary))
        if status.actions {
          Button("Mover para a fila") { Task { await store.moveToQueue(pending) } }
            .buttonStyle(.plain).disabled(!store.actionable(pending))
          Button { Task { await store.deletePending(pending) } } label: { Image(systemName: "trash") }
            .buttonStyle(.plain).help("Excluir mensagem pendente").disabled(!store.actionable(pending))
        }
      } else if pending == nil, !store.isChild {
        Button { context.revert(message) } label: { Image(systemName: "arrow.uturn.backward") }
          .buttonStyle(.plain).help("Redefinir para este ponto").accessibilityLabel("Redefinir para este ponto")
          .disabled(store.reversion.pending)
      }
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.copyText, forType: .string)
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          copied = false
        }
      } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
        .buttonStyle(.plain).help("Copiar mensagem").accessibilityLabel("Copiar mensagem")
      Text(ConversationProjection.date(message.time.created, format: "HH:mm")).monospacedDigit()
    }
    .appFont(.bubbleMeta).foregroundStyle(theme.color(.textSecondary))
    .padding(.trailing, 4)
  }

  private func tapped() {
    if context.pinned == "prompt:" + message.id, context.revealTurn(message.id) { return }
    if folds, !expanded {
      context.store.memory.setBubble(message.id, expanded: true)
    }
  }

  /// Whether the prompt needs more than two lines at this bubble width.
  @MainActor static func truncates(_ text: String, width: CGFloat) -> Bool {
    guard !text.isEmpty else { return false }
    let font = NSFont.systemFont(ofSize: AppTextStyle.message.size)
    let height = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
    return height > ceil(font.ascender - font.descender + font.leading) * 2 + 2
  }
}

/// A quote carried by a prompt: the passage (four lines) and its comment.
private struct MacQuoteCard: View {
  @Environment(\.appTheme) private var theme
  let quote: ChatQuote
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Citação", systemImage: "quote.bubble").appFont(.caption).lineLimit(1)
      Text(quote.text).appFont(.secondary).lineLimit(4)
      if !quote.comment.isEmpty {
        Text(quote.comment).appFont(.secondary).foregroundStyle(theme.color(.userBubbleText))
      }
    }
    .foregroundStyle(theme.color(.userBubbleSecondary))
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 12)
    .overlay(alignment: .leading) { Rectangle().fill(theme.color(.primary)).frame(width: 2) }
  }
}

/// A prompt's images and other files, from the same message fields as the iPhone's bubble.
struct MacPromptAttachments {
  let images: [FeedImage]
  let files: [String]
  init(_ message: ConversationMessage) {
    images = (message.files ?? []).compactMap { file in
      guard let image = FeedImage.attachment(file) else { return nil }
      return FeedImage(source: image.source,
        name: file.object?["name"]?.string ?? file.object?["filename"]?.string ?? image.name)
    }
    let others = (message.files ?? []).filter {
      !($0.object?["mime"]?.string ?? $0.object?["mimeType"]?.string ?? "").hasPrefix("image/")
        && $0.object?["type"]?.string != "image"
    }
    let names = others.map { file in
      file.object?["name"]?.string ?? file.object?["filename"]?.string
        ?? (file.object?["uri"]?.string ?? file.object?["path"]?.string ?? file.object?["url"]?.string)
          .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Arquivo anexado"
    }
    let represented = Set(images.map(\.name) + names)
    files = names + (message.metadata?["attachments"]?.array ?? []).map {
      $0.object?["name"]?.string ?? "Arquivo anexado"
    }.filter { !represented.contains($0) }
  }
}

/// An image from the conversation (an attachment, a Markdown image, a server file), loaded by the shared
/// `FeedImageLoader`; clicking opens it at full size.
struct MacFeedImage: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var scale
  let source: String
  let name: String
  var size: CGFloat? = nil
  let context: MacTranscriptContext
  @State private var image: CGImage?
  @State private var failed = false

  var body: some View {
    Button {
      if let image { context.openImage(image, name) }
    } label: {
      Group {
        if let image {
          Image(decorative: image, scale: scale).resizable()
            .aspectRatio(contentMode: size == nil ? .fit : .fill)
        } else if failed {
          Label("Imagem indisponível", systemImage: "photo.badge.exclamationmark").appFont(.caption)
        } else {
          ProgressView().controlSize(.small)
        }
      }
      .frame(width: size, height: size)
      .frame(maxWidth: size == nil ? 520 : nil, maxHeight: size == nil ? 360 : nil, alignment: .leading)
      .frame(minHeight: size == nil && image == nil ? 120 : nil)
      .clipShape(RoundedRectangle(cornerRadius: size == nil ? 10 : 8))
      .overlay { RoundedRectangle(cornerRadius: size == nil ? 10 : 8).strokeBorder(theme.color(.border).opacity(0.4)) }
    }
    .buttonStyle(.plain).help(name)
    .task(id: source) {
      guard let images = context.images else { failed = true; return }
      do {
        image = try await FeedImageLoader.shared.load(source, client: images.client, directory: images.directory,
          maxPixelSize: Int((size ?? 520) * scale))
      } catch { failed = !Task.isCancelled }
    }
  }
}

// MARK: - Responses

/// The finished response's model, effort, date, copy and read-aloud line.
private struct MacFooter: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let context: MacTranscriptContext
  var body: some View {
    let store = context.store
    let reading = store.readAloud.messageID == message.id
    HStack(spacing: 12) {
      Text(ConversationProjection.footer(message, models: store.displayModels)).monospacedDigit()
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.responseText(endingAt: message.id), forType: .string)
        store.toast.show("Resposta copiada")
      } label: { Image(systemName: "doc.on.doc") }
        .buttonStyle(.plain).help("Copiar resposta").accessibilityLabel("Copiar resposta")
      Button { store.readAloudResponse(endingAt: message.id) } label: {
        Image(systemName: reading ? "stop" : "play")
      }
      .buttonStyle(.plain).help(reading ? "Parar leitura" : "Ouvir resposta")
      .accessibilityLabel(reading ? "Parar leitura" : "Ouvir resposta")
    }
    .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
  }
}

/// A non-prose Markdown block: code with highlight.js colors, tables, images, display formulas, Mermaid
/// diagrams (the shared JS engine's SVG), footnotes and disclosures.
private struct MacResponseBlock: View {
  @Environment(\.appTheme) private var theme
  let part: TranscriptPart
  let block: MarkdownBlock
  let notes: Bool
  let context: MacTranscriptContext

  var body: some View {
    switch block.kind {
    case .code(let language):
      if MarkdownCodeProjection.language(language) == "mermaid" || language?.lowercased() == "mermaid" {
        MacDiagram(source: block.text, block: block)
      } else {
        MacCodeBlock(block: block, language: language)
      }
    case .table:
      MacTable(block: block)
    case .formula:
      if let formula = block.runs.first?.formula {
        MacFormula(formula: formula, raster: context.rasters(part)[ResponseFormulaKey(formula)])
      } else {
        MacBlockText(blocks: [block])
      }
    case .image:
      MacFeedImage(source: block.runs.first?.image ?? block.text, name: block.text, context: context)
    case .footnote(let id, _):
      VStack(alignment: .leading, spacing: 6) {
        if notes { Text("Notas").appFont(.caption, weight: .semibold).foregroundStyle(theme.color(.textSecondary)) }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(id).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
          MacBlockText(blocks: block.children)
        }
      }
    case .details:
      MacDetails(block: block, part: part, context: context)
    default:
      MacBlockText(blocks: [block])
    }
  }
}

/// Simple selectable text for blocks without their own view (notes, disclosures' bodies, formulas).
private struct MacBlockText: View {
  @Environment(\.appTheme) private var theme
  let blocks: [MarkdownBlock]
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(blocks) { block in
        if let formula = block.runs.first?.formula, block.kind == .formula {
          MacFormula(formula: formula)
        } else {
          Text(MacResponseTextStyle.attributed(block, theme: theme)).textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MacFormula: View {
  @Environment(\.appTheme) private var theme
  let formula: MarkdownFormula
  var raster: ResponseFormulaRaster?
  var body: some View {
    Group {
      if let raster, let metrics = formula.metrics, let image = NSImage(data: raster.png) {
        Image(nsImage: image).resizable().frame(width: metrics.width, height: metrics.height)
      } else {
        Text(formula.source).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.color(.codeText))
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 6)
    .contextMenu {
      Button("Copiar fórmula") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formula.source, forType: .string)
      }
    }
  }
}

private struct MacCodeBlock: View {
  @Environment(\.appTheme) private var theme
  let block: MarkdownBlock
  let language: String?
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language?.isEmpty == false ? language! : "código").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(block.codeDisplay.text, forType: .string)
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
          }
        } label: {
          Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc").appFont(.caption)
        }
        .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary))
      }
      .padding(.horizontal, 12).padding(.vertical, 6)
      Rectangle().fill(theme.color(.codeBorder)).frame(height: 0.7)
      ScrollView(.horizontal) {
        Text(MacResponseTextStyle.attributed(block.codeDisplay, theme: theme))
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: true)
          .padding(12)
      }
      .scrollIndicators(.automatic)
    }
    .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.codeBorder), lineWidth: 0.7) }
  }
}

private struct MacTable: View {
  @Environment(\.appTheme) private var theme
  let block: MarkdownBlock
  var body: some View {
    let table = block.table
    let rows = table?.rows ?? []
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { column, runs in
              MacTableCell(block: block, runs: runs, alignment: alignment(column), header: index == 0)
            }
          }
          if index < rows.count - 1 {
            Rectangle().fill(theme.color(.border)).frame(height: 0.7).gridCellUnsizedAxes(.horizontal)
          }
        }
      }
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border), lineWidth: 0.7) }
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .scrollIndicators(.automatic)
  }

  private func alignment(_ column: Int) -> MarkdownTable.Alignment {
    guard let alignments = block.table?.alignments, alignments.indices.contains(column) else { return .leading }
    return alignments[column]
  }
}

private struct MacTableCell: View {
  @Environment(\.appTheme) private var theme
  let block: MarkdownBlock
  let runs: [MarkdownRun]
  let alignment: MarkdownTable.Alignment
  let header: Bool
  var body: some View {
    let frame: Alignment = switch alignment {
    case .center: .center
    case .trailing: .trailing
    case .leading: .leading
    }
    Text(MacResponseTextStyle.attributed(block.cell(runs, alignment: alignment), theme: theme, tableHeader: header))
      .textSelection(.enabled)
      .frame(minWidth: 60, maxWidth: 360, alignment: frame)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(header ? theme.color(.tableSurface) : Color.clear)
  }
}

private struct MacDiagram: View {
  @Environment(\.appTheme) private var theme
  let source: String
  let block: MarkdownBlock
  @State private var image: NSImage?
  @State private var failed = false
  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
          .frame(maxWidth: min(image.size.width, 760), maxHeight: 520)
          .padding(10)
          .frame(maxWidth: .infinity)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
      } else if failed {
        MacCodeBlock(block: block, language: "mermaid")
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
      }
    }
    .task(id: source) {
      let svg = await ResponseEngines.shared.diagram(source)
      guard let data = svg?.data(using: .utf8), let picture = NSImage(data: data) else { failed = true; return }
      image = picture
    }
  }
}

private struct MacDetails: View {
  @Environment(\.appTheme) private var theme
  let block: MarkdownBlock
  let part: TranscriptPart
  let context: MacTranscriptContext
  private var key: String { "details:\(part.partID):\(block.id)" }
  private var open: Bool { context.store.memory.detail(key) ?? false }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        context.store.memory.setDetail(key, expanded: !open)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
          Text(MacResponseTextStyle.attributed(block, theme: theme))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if open { MacBlockText(blocks: block.children).padding(.leading, 16) }
    }
  }
}

// MARK: - Activity

/// An activity group as the shared card (`ConversationActivityCard` + `ConversationTimeline`), closed by default;
/// open, the first four items and `Mais N ferramentas…`. Expansion lives in the conversation's expansion memory,
/// so it survives streaming, paging and returning, as on the iPhone.
private struct MacActivityRow: View {
  let id: String
  let grouped: Bool
  let parts: [ConversationActivityPart]
  let items: [ConversationActivityItem]
  let pending: Bool
  let context: MacTranscriptContext
  private let folded = 4
  private var store: ConversationStore { context.store }
  private var expanded: Bool { store.expansionValues[id] ?? false }
  private var showsAll: Bool { store.expansionValues[id + ":all"] ?? false }

  var body: some View {
    let items = self.items.isEmpty ? ConversationActivityItem.project(parts) : self.items
    if grouped {
      let hidden = items.count > folded + 1 && !showsAll ? Array(items.dropFirst(folded)) : []
      ConversationActivityCard(parts: parts, expanded: expanded, pending: pending,
        identifier: "tool-group-\(id)") {
        store.expansionValues[id] = !expanded
      } content: {
        ConversationTimeline {
          ForEach(hidden.isEmpty ? items : Array(items.prefix(folded))) { item in
            ConversationTimelineRow(done: item.completed) { MacActivityItem(item: item, context: context) }
          }
          if !hidden.isEmpty {
            ConversationTimelineRow(done: hidden.allSatisfy(\.completed)) {
              Button {
                store.expansionValues[id + ":all"] = true
              } label: {
                ConversationTimelineLabel(icon: "ellipsis",
                  name: "Mais \(hidden.map(\.parts.count).reduce(0, +)) ferramentas…",
                  duration: total(hidden).map(ConversationProjection.duration)).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(items) { item in MacActivityItem(item: item, context: context) }
      }
    }
  }

  private func total(_ items: [ConversationActivityItem]) -> Double? {
    let spans = items.map(\.duration)
    guard spans.allSatisfy({ $0 != nil }) else { return nil }
    return spans.compactMap { $0 }.reduce(0, +)
  }
}

/// One timeline item: grouped reads, files with `+N −M` and their diffs, searches, skills, notices, reasoning,
/// a subagent (its agent chip and the pixel button that opens it in the middle column), any other call with its
/// target; a call with output or an error opens it below.
private struct MacActivityItem: View {
  @Environment(\.appTheme) private var theme
  let item: ConversationActivityItem
  let context: MacTranscriptContext
  private var store: ConversationStore { context.store }
  private var duration: String? { item.duration.map(ConversationProjection.duration) }
  private var key: String { "activity:detail:" + (item.parts.first?.id ?? item.id) }
  private var open: Bool { store.expansionValues[key] ?? false }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      label
      if open, let detail { detailView(detail) }
      if item.kind == .files, open { diffs }
    }
  }

  @ViewBuilder private var label: some View {
    let first = item.parts.first
    switch item.kind {
    case .read:
      let names = item.parts.map(\.part.readGroupName).filter { !$0.isEmpty }
      ConversationTimelineLabel(icon: "doc.text", name: "Ler", target: names.joined(separator: ", "),
        duration: duration, lines: 1)
    case .skills:
      ConversationTimelineLabel(icon: "sparkles",
        name: item.parts.count == 1 ? "Carregou a habilidade" : "Carregou as habilidades",
        target: item.parts.compactMap(\.part.skillName).joined(separator: ", "), duration: duration)
    case .files:
      let title = first?.part.groupTitle ?? "Patch"
      toggle(always: !item.files.isEmpty) {
        if item.files.count == 1, let file = item.files.first {
          ConversationTimelineLabel(icon: "pencil", name: title, target: (file.path as NSString).lastPathComponent,
            duration: duration, lines: 1) { counts(file) }
        } else {
          ConversationTimelineLabel(icon: "pencil", name: title,
            target: item.files.isEmpty ? "" : "\(item.files.count) arquivos", monospaced: false, duration: duration) {
            EmptyView()
          }
        }
      }
    case .search, .part:
      if let entry = first { part(entry) }
    }
  }

  @ViewBuilder private func part(_ entry: ConversationActivityPart) -> some View {
    let part = entry.part
    if let notice = entry.notice {
      ConversationTimelineLabel(icon: "info.circle", name: notice.notice, lines: 6)
    } else if part.type == .reasoning {
      toggle { ConversationTimelineLabel(icon: "brain", name: entry.reasoningLabel, duration: duration) }
    } else if part.name == "subagent", !part.failed {
      subagent(part)
    } else {
      toggle {
        ConversationTimelineLabel(
          icon: part.failed ? "exclamationmark.triangle" : part.icon, name: part.groupTitle,
          target: part.activityTarget + (part.exitCode.map { " · código \($0)" } ?? ""),
          tone: part.failed ? .error : .text, duration: duration)
      }
    }
  }

  @ViewBuilder private func toggle(always: Bool = false, @ViewBuilder _ content: () -> some View) -> some View {
    if detail == nil && !always {
      content()
    } else {
      Button {
        store.expansionValues[key] = !open
      } label: {
        content().contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  private func subagent(_ part: ConversationPart) -> some View {
    let id = part.input["agent"]?.string ?? "subagent"
    let agent = store.agents.first { $0.id == id }
    let child = store.subagentChild(part)
    let running = child.map(store.active.contains) ?? part.running
    let color = theme.agentColor(agent, id: id)
    return Button {
      if let child { context.openChild(child) }
    } label: {
      ConversationTimelineLabel(icon: part.icon, name: "Agente ·", target: part.input["description"]?.string ?? "Subagente",
        monospaced: false, duration: duration ?? (running ? nil : part.elapsed(now: Date().timeIntervalSince1970 * 1000))) {
        Text(agent?.name ?? id).appFont(.footnote, weight: .medium).foregroundStyle(color).lineLimit(1)
          .padding(.horizontal, 8).padding(.vertical, 2)
          .overlay { Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.7) }
          .fixedSize()
        AgentPixels(color: color, size: 10, running: running, grid: true)
          .frame(width: 22, height: 22)
          .background(theme.color(.surfaceRaised), in: Circle())
          .overlay { Circle().strokeBorder(theme.color(.border), lineWidth: 0.7) }
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
          .padding(.vertical, -5)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(child == nil)
    .help(child == nil ? "" : "Abrir o subagente")
    .accessibilityIdentifier("open-subagent-\(child ?? "")")
  }

  private func counts(_ file: ConversationActivityFile) -> some View {
    HStack(spacing: 5) {
      if file.additions > 0 || file.status == "added" { Text("+\(file.additions)").foregroundStyle(theme.color(.success)) }
      if file.deletions > 0 || file.status == "deleted" { Text("−\(file.deletions)").foregroundStyle(theme.color(.error)) }
    }
    .monospacedDigit().fixedSize()
  }

  /// Each changed file with its patch, colored by line; a file opens Arquivos.
  private var diffs: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(item.files) { file in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Button(file.path) { context.openPath(file.path) }.buttonStyle(.plain)
              .appFont(.caption, design: .monospaced).foregroundStyle(theme.color(.textAccent)).lineLimit(1)
            counts(file).appFont(.caption)
          }
          ForEach(Array(file.patches.enumerated()), id: \.offset) { _, patch in
            ScrollView(.horizontal) {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).prefix(400).enumerated()),
                  id: \.offset) { _, line in
                  Text(line.isEmpty ? " " : String(line))
                    .foregroundStyle(theme.color(line.hasPrefix("+") ? .syntaxAdded : line.hasPrefix("-") ? .syntaxRemoved
                      : line.hasPrefix("@@") ? .textSecondary : .codeText))
                }
              }
              .appFont(.caption, design: .monospaced).textSelection(.enabled).padding(10)
            }
            .frame(maxHeight: 320)
            .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
  }

  private var detail: String? {
    guard item.kind == .part || item.kind == .search, let part = item.parts.first?.part else { return nil }
    if part.type == .reasoning { return part.text?.isEmpty == false ? part.text : nil }
    if let error = part.errorText { return error }
    return part.output.isEmpty ? nil : part.output
  }

  private func detailView(_ text: String) -> some View {
    ScrollView {
      Text(text).appFont(.caption, design: .monospaced).foregroundStyle(theme.color(.codeText))
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
    .frame(maxHeight: 240)
    .fixedSize(horizontal: false, vertical: true)
    .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
  }
}
