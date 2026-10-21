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
  let message: ConversationMessage
  var compact = false
  var body: some View {
    HStack {
      Spacer(minLength: 36)
      VStack(alignment: .trailing, spacing: 8) {
        if !compact {
          ForEach(Array((message.files ?? []).enumerated()), id: \.offset) { _, file in
            if let object = file.object, object["mime"]?.string?.hasPrefix("image/") == true,
              let encoded = object["data"]?.string
            {
              AttachmentPreview(encoded: encoded, name: object["name"]?.string ?? "Imagem anexada")
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
        }
        if !message.displayText.isEmpty {
          if compact {
            CompactPrompt(text: message.displayText, theme: theme)
          } else {
            Text(promptText).font(.system(size: 16)).multilineTextAlignment(.leading)
          }
        }
        if compact && message.displayText.isEmpty {
          Label(
            message.files?.isEmpty == false ? "Imagem" : "Citação",
            systemImage: message.files?.isEmpty == false ? "photo" : "quote.opening"
          ).font(.subheadline)
        }
        Text(ConversationProjection.date(message.time.created, format: "HH:mm"))
          .font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary))
      }
      .foregroundStyle(theme.color(.userBubbleText))
      .padding(.horizontal, 13).padding(.vertical, 10)
      .background(theme.color(.userBubble), in: RoundedRectangle(cornerRadius: 16))
      .overlay { UserMessageCopyMenu(message: message, toast: toast) }
    }
  }
  private var promptText: AttributedString {
    var text = AttributedString(message.displayText)
    guard let value = message.metadata?["composerTokens"],
      let data = try? JSONEncoder().encode(value),
      let spans = try? JSONDecoder().decode([ComposerSpan].self, from: data)
    else { return text }
    let document = ComposerDocument(text: message.displayText, tokens: spans)
    for span in document.validTokens {
      if let range = Range(span.range, in: message.displayText),
        let lower = AttributedString.Index(range.lowerBound, within: text),
        let upper = AttributedString.Index(range.upperBound, within: text)
      {
        text[lower..<upper].foregroundColor = theme.color(span.token.kind.role)
        text[lower..<upper].backgroundColor = theme.color(span.token.kind.role).opacity(0.12)
      }
    }
    return text
  }
}

struct ConversationStep: View {
  @Environment(\.appTheme) private var theme
  let parts: [ConversationPart]
  let store: ConversationStore
  let openChild: (String) -> Void
  @State private var expanded: Bool?
  @State private var detail: Set<String> = []
  @State private var outputs: [String: String] = [:]
  private var pending: Bool {
    parts.contains { $0.running || $0.childID.map(store.active.contains) == true }
  }
  private var revealed: Bool { parts.contains { $0.id != nil && $0.id == store.revealedToolID } }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        expanded = !(expanded ?? (pending || revealed))
      } label: {
        HStack(spacing: 6) {
          Text(ConversationProjection.stepLabel(parts)).font(.system(size: 13)).lineLimit(1)
          Image(systemName: (expanded ?? (pending || revealed)) ? "chevron.down" : "chevron.right")
            .font(
              .system(size: 10))
        }.foregroundStyle(theme.color(.textSecondary)).frame(
          maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain).accessibilityLabel(ConversationProjection.stepLabel(parts))
      if expanded ?? (pending || revealed) {
        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
          if part.type == "reasoning" {
            let key = "reasoning:\(index)"
            Button {
              if !detail.insert(key).inserted { detail.remove(key) }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "sparkles")
                Text(
                  "Pensou\(part.time?.completed.map { " \(ConversationProjection.duration($0 - (part.time?.created ?? $0)))" } ?? "")"
                )
                Spacer()
                Image(systemName: detail.contains(key) ? "chevron.down" : "chevron.right").font(
                  .system(size: 10))
              }
            }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(
              theme.color(.textSecondary))
            if detail.contains(key) {
              Text(part.text ?? "").font(.footnote).textSelection(.enabled)
            }
          } else if part.type == "tool", part.name != "todowrite" || part.status == "error" {
            if part.name == "subagent" {
              subagent(part)
            } else {
              tool(part, key: part.id ?? "\(index)")
            }
          } else if part.type != "tool" {
            Text("Conteúdo da sessão · \(part.type.description)").font(.footnote).foregroundStyle(
              theme.color(.textSecondary))
          }
        }
      }
    }.onChange(of: store.revealedToolID) { _, id in
      if parts.contains(where: { $0.id == id }) { expanded = true }
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
        if !detail.insert(key).inserted { detail.remove(key) }
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
      if detail.contains(key) {
        VStack(alignment: .leading, spacing: 8) {
          if let error = part.errorText { Text(error).foregroundStyle(theme.color(.error)) }
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
    .task(id: "\(detail.contains(key)):\(part.status ?? "")") {
      guard detail.contains(key), part.name == "shell" else { return }
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
