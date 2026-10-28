import OpenCodeKit
import SwiftUI

struct AgentPixels: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let color: Color
  var size: CGFloat = 18
  var running = true
  /// Idle, the still grid instead of the stopped square: the activity timeline's agent button.
  var grid = false
  var body: some View {
    if running || grid {
      TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion || !running)) { context in
        Canvas { canvas, bounds in
          let tick = Int(context.date.timeIntervalSince1970 * 7)
          for row in 0..<5 {
            for column in 0..<5 {
              let alpha = reduceMotion || !running ? 1.0 : Double((row * 3 + column + tick) % 5 + 1) / 5
              let rect = CGRect(
                x: CGFloat(column) * bounds.width / 5, y: CGFloat(row) * bounds.height / 5,
                width: bounds.width / 7, height: bounds.height / 7)
              canvas.fill(Path(rect), with: .color(color.opacity(alpha)))
            }
          }
        }
      }.frame(width: size, height: size)
    } else {
      RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 1.2)
        .overlay { Rectangle().fill(color).padding(4) }.frame(width: size, height: size)
    }
  }
}

extension AppTheme {
  func agentRole(_ agent: AgentInfo?, id: String) -> ThemeRole {
    switch agent?.color {
    case "primary": return .agentPrimary
    case "secondary": return .agentSecondary
    case "accent": return .agentAccent
    case "success": return .agentStateSuccess
    case "warning": return .agentStateWarning
    case "error": return .agentError
    case "info": return .agentStateInfo
    default: break
    }
    switch id {
    case "build": return .agentBuild
    case "explore": return .agentExplore
    case "plan": return .agentPlan
    case "review": return .agentReview
    case "writer": return .agentWriter
    default:
      let palette: [ThemeRole] = [
        .agentAsk, .agentLegacyBuild, .agentDocs, .agentLegacyPlan, .agentInfo, .agentSuccess,
        .agentWarning, .agentProperty, .agentConstant, .agentAdded, .agentDeleted,
        .agentLegacyWarning,
      ]
      let hash = id.lowercased().utf16.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
      return palette[Int(hash) % palette.count]
    }
  }
}

/// A tap on a pinned prompt's body returns to the start of its turn. The handler answers whether it took
/// the tap and resolves the turn only when invoked; equality ignores it, so the bubble never re-renders for it.
struct UserPromptJump: Equatable {
  let perform: (String) -> Bool
  static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
  @Entry var userPromptJump: UserPromptJump? = nil
}

struct UserBubble: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.userPromptJump) private var promptJump
  @Environment(\.userMessageRevert) private var reversion
  @Environment(\.userMessagePending) private var pendingInput
  @Environment(\.userMessageUndelivered) private var undelivered
  @Environment(ToastCenter.self) private var toast
  @Environment(\.conversationSearch) private var highlights
  @Environment(\.conversationQuotes) private var quoteContext
  @Environment(\.transcriptMemory) private var memory
  @AppStorage("OpenCodeCollapsibleUserMessages") private var collapsible = true
  @State private var localExpanded = false
  @State private var localTruncated = false
  /// The conversation's memory keeps the reader's choice when the bubble is rebuilt.
  private var expanded: Bool { memory?.bubble(message.id) ?? localExpanded }
  /// Measured asynchronously by the prompt; remembered so a rebuilt bubble starts at its known height.
  private var truncated: Bool { memory?.truncated(message.id) ?? localTruncated }
  private func setTruncated(_ value: Bool) {
    if let memory { memory.setTruncated(message.id, value: value) } else { localTruncated = value }
  }
  let message: ConversationMessage
  let maximumTextHeight: CGFloat
  var body: some View {
    HStack {
      Spacer(minLength: 36)
      VStack(alignment: .trailing, spacing: 4) {
        VStack(alignment: .trailing, spacing: 8) {
          if message.masterOrigin != nil {
            Text("Sessão mestra").appFont(.footnote).foregroundStyle(theme.color(.userBubbleSecondary))
              .accessibilityIdentifier("master-origin-" + message.id)
          }
          UserMessageContent(maximumHeight: maximumTextHeight) {
            // Folded bubbles hide quotes and file comments behind their expansion control. Without prompt
            // text, one clamped line of their comments stands in for the prompt so the bubble is never empty.
            if folded && message.displayText.isEmpty {
              UserPrompt(
                text: contextSummary, theme: theme, collapsed: true, maximumHeight: maximumTextHeight,
                revealRange: nil, truncationChanged: { setTruncated($0) }, expand: { setExpanded(true) },
                jump: promptJump.map { jump in { jump.perform(message.id) } }
              ).accessibilityIdentifier("user-context-summary-\(message.id)")
            }
            if !folded {
              ForEach(Array(quotes.enumerated()), id: \.offset) { index, quote in
                UserMessageContextCard(
                  summary: "Citação de uma resposta", text: quote.object?["text"]?.string ?? "",
                  comment: quote.object?["comment"]?.string ?? "",
                  id: "\(message.id)-quote-\(index)")
                if let mark = quoteContext.index.carried(by: message.id).first(where: { $0.number == index + 1 }) {
                  Button("Ir ao trecho citado", systemImage: "text.quote") {
                    quoteContext.source?(mark.quote)
                  }.appFont(.caption).buttonStyle(.plain).foregroundStyle(theme.color(.userBubbleSecondary))
                    .accessibilityIdentifier("quote-source-\(message.id)-\(index)")
                }
              }
              ForEach(Array(comments.enumerated()), id: \.offset) { index, comment in
                UserMessageContextCard(
                  summary: comment.object?["path"]?.string ?? "Comentário em arquivo", text: "",
                  comment: comment.object?["comment"]?.string ?? "",
                  id: "\(message.id)-comment-\(index)")
              }
            }
            if !message.displayText.isEmpty {
              UserPrompt(
                text: promptText, theme: theme, collapsed: collapsible && !expanded,
                maximumHeight: maximumTextHeight, revealRange: searchRange,
                truncationChanged: { setTruncated($0) }, expand: { setExpanded(true) },
                jump: promptJump.map { jump in { jump.perform(message.id) } }
              ).accessibilityIdentifier("user-prompt-\(message.id)")
            }
          }.accessibilityIdentifier("user-content-\(message.id)")
          // Folded bubbles omit image thumbnails; their expansion control below reveals them.
          UserMessageAttachmentsView(attachments: UserMessageAttachments(message, includesImages: !folded))
          if collapsible && (expanded || truncated || hasContext) {
            Button(expanded ? "Mostrar menos" : "Mostrar mensagem completa") {
              setExpanded(!expanded)
            }.appFont(.path).foregroundStyle(theme.color(.userBubbleSecondary))
              .buttonStyle(.plain).accessibilityValue(expanded ? "Expandido" : "Recolhido")
              .accessibilityIdentifier("user-prompt-toggle-\(message.id)")
          }
        }
        .foregroundStyle(theme.color(.userBubbleText))
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(theme.color(.userBubble), in: RoundedRectangle(cornerRadius: 16))
        .background {
          #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("-OpenCodeSizingDiagnostics") {
            LayoutBoundsProbe(id: "user-bubble-" + message.id)
          }
          #endif
        }
        .background { UserMessageCopyMenu(message: message, toast: toast).frame(width: 0, height: 0) }
        // Its buttons and the prompt's own tap take precedence; the actions below the bubble are outside it.
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { _ = promptJump?.perform(message.id) }
        HStack(spacing: 8) {
          if let pendingInput {
            pendingActions(pendingInput)
          } else if let reversion {
            Button {
              reversion.revert(message.id)
            } label: {
              Image(systemName: "arrow.uturn.backward").appFont(.bubbleMeta)
                .frame(width: 28, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(reversion.pending)
              .accessibilityLabel("Redefinir para este ponto")
              .accessibilityIdentifier("user-revert-" + message.id)
          }
          UserMessageCopyButton(message: message).id(message.id)
          if undelivered {
            Text("Pendente ·").appFont(.bubbleMeta).accessibilityIdentifier("user-pending-" + message.id)
          }
          Text(ConversationProjection.date(message.time.created, format: "HH:mm"))
            .appFont(.bubbleMeta).monospacedDigit()
            .accessibilityIdentifier("user-time-" + message.id)
        }.foregroundStyle(theme.color(.textSecondary))
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("user-meta-" + message.id)
      }
    }
    .onChange(of: collapsible) { _, value in if !value { setExpanded(false) } }
    .onAppear { if quoteContext.revealedMessage == message.id { setExpanded(true) } }
    .onChange(of: quoteContext.revealedMessage) { _, id in if id == message.id { setExpanded(true) } }
    .onChange(of: highlights.current) { _, current in
      if highlights.matches.contains(where: { $0.id == current && $0.messageID == message.id }) {
        setExpanded(true)
      }
    }
  }
  private var quotes: [JSONValue] { message.metadata?["quotes"]?.array ?? [] }
  private var comments: [JSONValue] { message.metadata?["comments"]?.array ?? [] }
  private var hasContext: Bool { !quotes.isEmpty || !comments.isEmpty }
  /// Long prompts and any attached quote/comment start folded, as in the custom web.
  private var folded: Bool { collapsible && !expanded && (truncated || hasContext) }
  /// Each quote's own comment (else its passage) and each file comment, joined into one line of prompt text.
  private var contextSummary: AttributedString {
    let parts = quotes.map { quote in
      let comment = quote.object?["comment"]?.string ?? ""
      return comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? quote.object?["text"]?.string ?? "" : comment
    } + comments.map { $0.object?["comment"]?.string ?? $0.object?["path"]?.string ?? "" }
    let line = parts.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
      .filter { !$0.isEmpty }.joined(separator: " · ")
    let color = theme.uiColor(.userBubbleSecondary)
    let icon = UIImage(systemName: "quote.bubble", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .small))
    let value = NSMutableAttributedString(attributedString: NSAttributedString(
      attachment: NSTextAttachment(image: (icon ?? UIImage()).withTintColor(color, renderingMode: .alwaysOriginal))))
    value.append(NSAttributedString(string: " " + line, attributes: [.foregroundColor: color]))
    return (try? AttributedString(value, including: \.uiKit)) ?? AttributedString(line)
  }
  private func setExpanded(_ value: Bool) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      if let memory { memory.setBubble(message.id, expanded: value) } else { localExpanded = value }
    }
  }
  @ViewBuilder private func pendingActions(_ pending: UserMessagePendingAction) -> some View {
    Button(action: pending.queue) {
      Image(systemName: "arrow.down.to.line").appFont(.bubbleMeta)
        .frame(width: 28, height: 24).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(pending.busy)
      .accessibilityLabel("Mover mensagem pendente para a fila")
      .accessibilityIdentifier("user-pending-queue-" + message.id)
    Button(action: pending.remove) {
      Image(systemName: "trash").appFont(.bubbleMeta)
        .frame(width: 28, height: 24).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(pending.busy)
      .accessibilityLabel("Excluir mensagem pendente")
      .accessibilityIdentifier("user-pending-delete-" + message.id)
  }
  private var searchRange: NSRange? {
    guard let match = highlights.matches.first(where: { $0.id == highlights.current && $0.messageID == message.id }) else { return nil }
    let display = ((message.text ?? "") as NSString).range(of: message.displayText)
    guard display.location != NSNotFound else { return nil }
    let range = NSIntersectionRange(display, match.range)
    guard range.length > 0 else { return nil }
    return NSRange(location: range.location - display.location, length: range.length)
  }
  private var promptText: AttributedString {
    var text = AttributedString(message.displayText)
    if let value = message.metadata?["composerTokens"],
      let data = try? JSONEncoder().encode(value),
      let spans = try? JSONDecoder().decode([ComposerSpan].self, from: data)
    {
      let document = ComposerDocument(text: message.displayText, tokens: spans)
      for span in document.validTokens {
        if let range = Range(span.range, in: message.displayText),
          let lower = AttributedString.Index(range.lowerBound, within: text),
          let upper = AttributedString.Index(range.upperBound, within: text)
        {
          text[lower..<upper].uiKit.foregroundColor = theme.uiColor(span.token.kind.role)
          text[lower..<upper].uiKit.backgroundColor = theme.uiColor(span.token.kind.role).withAlphaComponent(0.12)
        }
      }
    }
    let displayRange = ((message.text ?? "") as NSString).range(of: message.displayText)
    if displayRange.location != NSNotFound {
      for match in highlights.matches where match.messageID == message.id {
        let intersection = NSIntersectionRange(displayRange, match.range)
        guard intersection.length > 0,
          let range = Range(NSRange(location: intersection.location - displayRange.location, length: intersection.length), in: message.displayText),
          let lower = AttributedString.Index(range.lowerBound, within: text),
          let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
        text[lower..<upper].uiKit.backgroundColor = theme.uiColor(.primary).withAlphaComponent(match.id == highlights.current ? 0.3 : 0.1)
      }
    }
    return text
  }
}

struct ConversationStep: View {
  @Environment(\.appTheme) private var theme
  let parts: [ConversationPart]
  let id: String
  let store: ConversationStore
  let openChild: (String) -> Void
  var references: [ConversationActivityPart] = []
  var items: [ConversationActivityItem] = []
  var grouped = true
  var busy = false
  private var expanded: Bool { !grouped || (store.expansionValues[id] ?? revealed) }
  private func detail(_ key: String) -> Bool {
    store.expansionValues["activity:detail:\(key)"] == true
  }
  private func toggleDetail(_ key: String) {
    store.expansionValues["activity:detail:\(key)"] = !detail(key)
    if !detail(key) { store.memory.setOutput(key, value: nil) }
  }
  private var pending: Bool {
    busy || parts.contains { $0.running }
  }
  private var revealed: Bool { parts.contains { $0.id != nil && $0.id == store.revealedToolID } }
  var body: some View {
    Group {
      if grouped {
        ConversationActivityCard(parts: entries, expanded: expanded, pending: pending, identifier: "tool-group-\(id)") {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { store.expansionValues[id] = !expanded }
        } content: {
          ConversationTimeline {
            ForEach(shownItems) { item in
              ConversationTimelineRow(done: item.completed) { row(item) }
            }
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(shownItems) { row($0) }
        }
      }
    }.onChange(of: store.revealedToolID, initial: true) { _, id in
      guard let id else { return }
      if parts.contains(where: { $0.id == id }) {
        store.expansionValues[self.id] = true
        store.revealedToolID = nil
      }
    }
    // Fetched output stays with the conversation while the step is open, so a rebuilt row keeps its height.
    .onChange(of: expanded) { _, open in
      if !open { entries.forEach { store.memory.setOutput($0.id, value: nil) } }
    }
  }
  private var shownItems: [ConversationActivityItem] { items.isEmpty ? ConversationActivityItem.project(entries) : items }
  @ViewBuilder private func row(_ item: ConversationActivityItem) -> some View {
    let duration = item.duration.map(ConversationProjection.duration)
    if item.kind != .part {
      ConversationActivityItemView(item: item, store: store)
    } else if let entry = item.parts.first {
      let part = entry.part
      if let notice = entry.notice {
        ConversationTimelineLabel(icon: "info.circle", name: notice.notice, lines: 6)
      } else if part.type == "reasoning" {
        let key = entry.id
        Button {
          toggleDetail(key)
        } label: {
          ConversationTimelineLabel(icon: "brain", name: entry.reasoningLabel) {
            Image(systemName: detail(key) ? "chevron.down" : "chevron.right").appSymbol(.disclosure)
              .foregroundStyle(theme.color(.icon))
          }.contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityLabel(entry.reasoningLabel)
          .accessibilityValue(detail(key) ? "Expandido" : "Recolhido")
          .accessibilityIdentifier("reasoning-\(entry.id)")
        if detail(key) {
          ResponseMarkdown(text: part.text ?? "", messageID: entry.messageID, partID: entry.id)
        }
      } else if part.type == "tool", !part.suppressed || part.failed {
        if part.name == "subagent", !part.failed {
          subagent(part)
        } else {
          tool(part, key: entry.id, duration: duration)
        }
      } else if part.type != "tool" {
        ConversationTimelineLabel(icon: "questionmark.square.dashed", name: "Conteúdo da sessão · \(part.type.description)")
      }
    }
  }
  private var entries: [ConversationActivityPart] {
    if !references.isEmpty { return references }
    return parts.enumerated().map { index, part in
      ConversationActivityPart(id: part.id ?? "\(id):\(index)", messageID: id, part: part)
    }
  }
  private func subagent(_ part: ConversationPart) -> some View {
    let id = part.input["agent"]?.string ?? "subagent"
    let agent = store.agents.first { $0.id == id }
    let childID = store.subagentChild(part)
    let running = childID.map(store.active.contains) ?? part.running
    let child = store.children.first { $0.id == childID }
    let color = theme.agentColor(agent, id: id)
    return Button {
      if let childID { openChild(childID) }
    } label: {
      TimelineView(.periodic(from: running ? .now : .distantFuture, by: 1)) { context in
        let elapsed = running && child != nil
          ? ConversationProjection.duration(
            context.date.timeIntervalSince1970 * 1000
              - ConversationProjection.workStarted(child: child!, shells: store.shells))
          : part.elapsed(now: context.date.timeIntervalSince1970 * 1000)
        ConversationTimelineLabel(icon: part.icon, name: "Agente ·", target: part.input["description"]?.string ?? "Subagente",
          monospaced: false, duration: elapsed) {
          Text(agent?.name ?? id).appFont(.footnote, weight: .medium).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .overlay { Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.7) }
            .fixedSize()
          AgentPixels(color: color, size: 11, running: running, grid: true)
            .frame(width: 24, height: 24)
            .background(theme.color(.surfaceRaised), in: Circle())
            .overlay { Circle().strokeBorder(theme.color(.border), lineWidth: 0.7) }
            // Centered on the text and overhanging its line instead of making it taller, so the row's dot
            // stays on the text.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .padding(.vertical, -5)
        }.contentShape(Rectangle())
      }
    }.buttonStyle(.plain).disabled(childID == nil)
  }
  private func tool(_ part: ConversationPart, key: String, duration: String? = nil) -> some View {
    let waiting = store.pendingTool(part)
    return VStack(alignment: .leading, spacing: 8) {
      Button {
        toggleDetail(key)
      } label: {
        if grouped {
          ConversationTimelineLabel(
            icon: part.failed ? "exclamationmark.triangle" : part.icon, name: waiting ?? part.groupTitle,
            target: waiting != nil ? "" : part.activityTarget + (part.exitCode.map { " · código \($0)" } ?? ""),
            tone: waiting != nil ? (part.name == "question" ? .info : .error) : part.failed ? .error : .text,
            duration: duration
          ).contentShape(Rectangle())
        } else {
        TimelineView(.periodic(from: part.running && waiting == nil ? .now : .distantFuture, by: 1))
        { context in
          HStack(alignment: .top, spacing: 10) {
            Image(
              systemName: part.failed
                ? "exclamationmark.triangle"
                : part.icon
            )
            .frame(width: 18)
            Text(
              "\(Text(waiting ?? part.summary(now: context.date.timeIntervalSince1970 * 1000)))\(Text(part.exitCode.map { " · código \($0)" } ?? "").foregroundColor(theme.color(.error)))"
            )
            .appFont(.caption).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
          }
          .foregroundStyle(
            theme.color(
              waiting != nil
                ? (part.name == "question" ? .info : .error)
                : part.failed ? .error : .text)
          )
          .padding(part.running ? 9 : 2)
          .background(
            theme.color(.codeSurface).opacity(part.running ? 1 : 0),
            in: RoundedRectangle(cornerRadius: 8))
        }
        }
      }.buttonStyle(.plain)
      if detail(key) {
        VStack(alignment: .leading, spacing: 8) {
          if let error = part.errorText { Text(error).foregroundStyle(theme.color(.error)) }
          ToolOutputImages(part: part, messageID: references.first { $0.part.id == part.id }?.messageID
            ?? store.messages.first { $0.content?.contains { $0.id == part.id } == true }?.id)
          if !part.diffs.isEmpty {
            ForEach(Array(part.diffs.enumerated()), id: \.offset) { _, file in
              Text(file["file"]?.string ?? "").fontWeight(.medium)
              ForEach(
                Array(
                  ConversationPart.patchLines(file["patch"]?.string ?? "").enumerated()),
                id: \.offset
              ) { _, line in
                Text(line).foregroundStyle(
                  theme.color(
                    line.hasPrefix("+")
                      ? .diffAdd
                      : line.hasPrefix("-")
                        ? .diffDelete : line.hasPrefix("@@") ? .textSecondary : .text))
              }
            }
          } else {
            Text(
              store.memory.output(key)
                ?? (part.output.isEmpty
                  ? (part.state?.object?["input"]?.formatted ?? "Sem saída disponível")
                  : part.output))
            if let exit = part.metadata["exit"]?.number, exit != 0 {
              Text("Processo encerrado com código \(Int(exit))").foregroundStyle(
                theme.color(.error))
            }
          }
          ForEach(Array((part.metadata["resources"]?.array ?? []).enumerated()), id: \.offset) { _, value in
            if let id = value.object?["id"]?.string {
              Button("Abrir \(value.object?["label"]?.string ?? "recurso")", systemImage: "rectangle.on.rectangle") {
                ResourceLinks.open(id)
              }
              .appFont(.caption, weight: .medium).buttonStyle(.plain).foregroundStyle(theme.color(.primary))
              .accessibilityIdentifier("tool-resource-" + id)
            }
          }
          Button("Copiar", systemImage: "doc.on.doc") {
            UIPasteboard.general.string =
              part.diffs.isEmpty
              ? store.memory.output(key) ?? part.output
              : part.diffs.compactMap { $0["patch"]?.string }.joined(separator: "\n")
            Haptics.play(.selection)
            store.toast.show(part.diffs.isEmpty ? "Saída copiada" : "Diff copiado")
          }
          .appFont(.caption).buttonStyle(.plain)
        }
        .appFont(.caption, design: .monospaced).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .id(part.id ?? key)
    .task(id: "\(detail(key)):\(part.status ?? "")") {
      guard detail(key), part.name == "shell" else { return }
      repeat {
        if let output = try? await store.shellOutput(part), !Task.isCancelled {
          store.memory.setOutput(key, value: output)
        }
        if !part.running { return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      } while !Task.isCancelled
    }
  }
}
