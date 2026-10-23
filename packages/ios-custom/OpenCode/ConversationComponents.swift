import OpenCodeKit
import SwiftUI

struct AgentPixels: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let color: Color
  var size: CGFloat = 18
  var running = true
  var body: some View {
    if running {
      TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { context in
        Canvas { canvas, bounds in
          let tick = Int(context.date.timeIntervalSince1970 * 7)
          for row in 0..<5 {
            for column in 0..<5 {
              let alpha = reduceMotion ? 1.0 : Double((row * 3 + column + tick) % 5 + 1) / 5
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

struct UserBubble: View {
  @Environment(\.appTheme) private var theme
  @Environment(ToastCenter.self) private var toast
  @Environment(\.conversationSearch) private var highlights
  @AppStorage("OpenCodeCollapsibleUserMessages") private var collapsible = true
  @State private var expanded = false
  @State private var truncated = false
  let message: ConversationMessage
  let maximumTextHeight: CGFloat
  var body: some View {
    HStack {
      Spacer(minLength: 36)
      VStack(alignment: .trailing, spacing: 8) {
        if message.masterOrigin != nil {
          Text("Sessão mestra").font(.caption2).foregroundStyle(theme.color(.textSecondary))
            .accessibilityIdentifier("master-origin-" + message.id)
        }
        ForEach(Array((message.files ?? []).enumerated()), id: \.offset) { _, file in
          if let image = FeedImage.attachment(file) {
            FeedImageView(source: image.source, name: image.name, compact: true)
          }
        }
        ForEach(Array((message.metadata?["quotes"]?.array ?? []).enumerated()), id: \.offset) {
          _, quote in
          VStack(alignment: .leading, spacing: 6) {
            Text("Citação de uma resposta").font(.caption).foregroundStyle(
              theme.color(.textSecondary))
            Text(quote.object?["text"]?.string ?? "").font(.subheadline)
            Text(quote.object?["comment"]?.string ?? "").font(.subheadline).fontWeight(.medium)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10).overlay(
            alignment: .leading
          ) {
            Rectangle().fill(theme.color(.primary)).frame(width: 2)
          }
        }
        ForEach(Array((message.metadata?["comments"]?.array ?? []).enumerated()), id: \.offset) {
          _, comment in
          Text(
            [comment.object?["path"]?.string, comment.object?["comment"]?.string].compactMap {
              $0
            }.joined(separator: "\n")
          ).font(.subheadline)
        }
        ForEach(Array((message.metadata?["attachments"]?.array ?? []).enumerated()), id: \.offset)
        { _, attachment in
          Label(attachment.object?["name"]?.string ?? "Arquivo anexado", systemImage: "doc")
            .font(.caption).foregroundStyle(theme.color(.textSecondary))
        }
        if !message.displayText.isEmpty {
          UserPrompt(
            text: promptText, theme: theme, collapsed: collapsible && !expanded,
            maximumHeight: maximumTextHeight, revealRange: searchRange,
            truncationChanged: { truncated = $0 }, expand: { setExpanded(true) }
          ).accessibilityIdentifier("user-prompt-\(message.id)")
          if collapsible && (expanded || truncated) {
            Button(expanded ? "Mostrar menos" : "Mostrar mensagem completa") {
              setExpanded(!expanded)
            }.font(.system(size: 14)).foregroundStyle(theme.color(.textSecondary))
              .buttonStyle(.plain).accessibilityValue(expanded ? "Expandido" : "Recolhido")
              .accessibilityIdentifier("user-prompt-toggle-\(message.id)")
          }
        }
        Text(ConversationProjection.date(message.time.created, format: "HH:mm"))
          .font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary))
      }
      .foregroundStyle(theme.color(.userBubbleText))
      .padding(.horizontal, 13).padding(.vertical, 10)
      .background(theme.color(.userBubble), in: RoundedRectangle(cornerRadius: 16))
      .background { UserMessageCopyMenu(message: message, toast: toast).frame(width: 0, height: 0) }
    }
    .onChange(of: collapsible) { _, value in if !value { setExpanded(false) } }
    .onChange(of: highlights.current) { _, current in
      if highlights.matches.contains(where: { $0.id == current && $0.messageID == message.id }) {
        setExpanded(true)
      }
    }
  }
  private func setExpanded(_ value: Bool) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { expanded = value }
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
  var grouped = true
  var busy = false
  @State private var outputs: [String: String] = [:]
  private var expanded: Bool { !grouped || (store.expansionValues[id] ?? (pending || revealed)) }
  private func detail(_ key: String) -> Bool {
    store.expansionValues["activity:detail:\(key)"] == true
  }
  private func toggleDetail(_ key: String) {
    store.expansionValues["activity:detail:\(key)"] = !detail(key)
    if !detail(key) { outputs.removeValue(forKey: key) }
  }
  private var pending: Bool {
    busy || parts.contains { $0.running || $0.childID.map(store.active.contains) == true }
  }
  private var revealed: Bool { parts.contains { $0.id != nil && $0.id == store.revealedToolID } }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if grouped {
        Button {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { store.expansionValues[id] = !expanded }
        } label: {
          HStack(spacing: 6) {
            if pending { ProgressView().controlSize(.mini) }
            Text(ConversationProjection.stepLabel(parts)).font(.system(size: 13))
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10))
          }.foregroundStyle(theme.color(.textSecondary)).frame(
            maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityLabel(ConversationProjection.stepLabel(parts))
        .accessibilityValue(expanded ? "Expandido" : "Recolhido")
        .accessibilityIdentifier("tool-group-\(id)")
      }
      if expanded {
        ForEach(entries) { entry in
          let part = entry.part
          if part.type == "reasoning" {
            let key = entry.id
            Button {
              toggleDetail(key)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "sparkles")
                Text(entry.reasoningLabel)
                Spacer()
                Image(systemName: detail(key) ? "chevron.down" : "chevron.right").font(
                  .system(size: 10))
              }
            }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(
              theme.color(.textSecondary))
              .accessibilityLabel(entry.reasoningLabel)
              .accessibilityIdentifier("reasoning-\(entry.id)")
            if detail(key) {
              ResponseMarkdown(text: part.text ?? "", messageID: entry.messageID, partID: entry.id)
            }
          } else if part.type == "tool", !part.suppressed {
            if part.name == "subagent" || part.name == "task" {
              subagent(part)
            } else {
              tool(part, key: entry.id)
            }
          } else if part.type != "tool" {
            Text("Conteúdo da sessão · \(part.type.description)").font(.footnote).foregroundStyle(
              theme.color(.textSecondary))
          }
        }
      }
    }.onAppear {
      // Remember the initial choice, including automatic expansion of running work.
      // Finishing a tool must not collapse a group the person is reading.
      if grouped && (pending || revealed) && store.expansionValues[id] == nil { store.expansionValues[id] = true }
    }.onChange(of: pending) { _, running in
      if grouped && running && store.expansionValues[id] == nil { store.expansionValues[id] = true }
    }.onChange(of: store.revealedToolID, initial: true) { _, id in
      guard let id else { return }
      if parts.contains(where: { $0.id == id }) {
        store.expansionValues[self.id] = true
        store.revealedToolID = nil
      }
    }
    .onChange(of: expanded) { _, open in if !open { outputs.removeAll() } }
    .onDisappear { outputs.removeAll() }
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
    let running = part.childID.map(store.active.contains) ?? part.running
    let child = store.children.first { $0.id == part.childID }
    return Button {
      if let child = part.childID { openChild(child) }
    } label: {
      TimelineView(.periodic(from: running ? .now : .distantFuture, by: 1)) { context in
        HStack(spacing: 9) {
          AgentPixels(color: theme.agentColor(agent, id: id), running: running)
          HStack(spacing: 7) {
            Text(agent?.name ?? id).font(.system(size: 13, weight: .medium)).foregroundStyle(
              theme.agentColor(agent, id: id))
            Text(part.input["description"]?.string ?? "Subagente").font(.system(size: 12))
              .foregroundStyle(theme.color(.text)).lineLimit(2)
          }
          Spacer(minLength: 3)
          Text(
            running && child != nil
              ? ConversationProjection.duration(
                context.date.timeIntervalSince1970 * 1000
                  - ConversationProjection.workStarted(child: child!, shells: store.shells))
              : part.elapsed(now: context.date.timeIntervalSince1970 * 1000) ?? ""
          )
          .font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.color(.textSecondary))
          Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(
            theme.color(.icon))
        }.padding(10).background(theme.color(.toolSurface), in: RoundedRectangle(cornerRadius: 9))
      }
    }.buttonStyle(.plain).disabled(part.childID == nil)
  }
  private func tool(_ part: ConversationPart, key: String) -> some View {
    let waiting = store.pendingTool(part)
    return VStack(alignment: .leading, spacing: 8) {
      Button {
        toggleDetail(key)
      } label: {
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
            .font(.system(size: 13)).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
          }
          .foregroundStyle(
            theme.color(
              waiting != nil
                ? (part.name == "question" ? .info : .error)
                : part.failed ? .error : part.running ? .success : .text)
          )
          .padding(part.running ? 9 : 2)
          .background(
            theme.color(.codeSurface).opacity(part.running ? 1 : 0),
            in: RoundedRectangle(cornerRadius: 8))
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
              outputs[key]
                ?? (part.output.isEmpty
                  ? (part.state?.object?["input"]?.formatted ?? "Sem saída disponível")
                  : part.output))
            if let exit = part.metadata["exit"]?.number, exit != 0 {
              Text("Processo encerrado com código \(Int(exit))").foregroundStyle(
                theme.color(.error))
            }
          }
          Button("Copiar", systemImage: "doc.on.doc") {
            UIPasteboard.general.string =
              part.diffs.isEmpty
              ? outputs[key] ?? part.output
              : part.diffs.compactMap { $0["patch"]?.string }.joined(separator: "\n")
            Haptics.play(.selection)
            store.toast.show(part.diffs.isEmpty ? "Saída copiada" : "Diff copiado")
          }
          .font(.system(size: 12)).buttonStyle(.plain)
        }
        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .id(part.id ?? key)
    .task(id: "\(detail(key)):\(part.status ?? "")") {
      guard detail(key), part.name == "shell" else { return }
      repeat {
        if let output = try? await store.shellOutput(part), !Task.isCancelled {
          outputs[key] = output
        }
        if !part.running { return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      } while !Task.isCancelled
    }
  }
}
