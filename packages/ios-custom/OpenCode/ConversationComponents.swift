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
  let message: ConversationMessage
  var compact = false
  var body: some View {
    HStack {
      Spacer(minLength: 36)
      VStack(alignment: .trailing, spacing: 8) {
        if !compact {
          ForEach(Array((message.files ?? []).enumerated()), id: \.offset) { _, file in
            if let object = file.object, object["mime"]?.string?.hasPrefix("image/") == true,
              let encoded = object["data"]?.string, let data = Data(base64Encoded: encoded),
              let image = UIImage(data: data)
            {
              VStack(spacing: 5) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 160, height: 110)
                  .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
                  .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                      theme.color(.border), lineWidth: 0.5)
                  }
                Label(object["name"]?.string ?? "Imagem anexada", systemImage: "photo")
                  .font(.caption).foregroundStyle(theme.color(.textSecondary))
              }.accessibilityLabel(object["name"]?.string ?? "Imagem anexada")
            }
          }
          ForEach(Array((message.metadata?["quotes"]?.array ?? []).enumerated()), id: \.offset) {
            _, quote in
            VStack(alignment: .leading, spacing: 6) {
              Text("Citação de uma resposta").font(.caption).foregroundStyle(
                theme.color(.textSecondary))
              Text(quote.object?["text"]?.string ?? "").font(.subheadline)
              Text(quote.object?["comment"]?.string ?? "").font(.subheadline).fontWeight(.medium)
            }.padding(.leading, 10).overlay(alignment: .leading) {
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
        }
        if !message.displayText.isEmpty {
          Text(message.displayText).font(.system(size: 16)).multilineTextAlignment(.leading)
            .lineLimit(compact ? 2 : nil).textSelection(.enabled)
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
    }
  }
}

struct ConversationComposer: View {
  @Environment(\.appTheme) private var theme
  let model: String
  let agent: String
  // AttributedString is the native storage for wave 3's inline mention tokens.
  @State private var text = AttributedString()
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      TextEditor(text: $text)
        .font(.system(size: 17)).disabled(true).frame(height: 26)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .leading) {
          if text.characters.isEmpty {
            Text("Mensagem").font(.system(size: 17)).foregroundStyle(theme.color(.textSecondary))
          }
        }
      HStack(spacing: 12) {
        Image(systemName: "plus").font(.system(size: 18)).frame(width: 31, height: 31)
          .overlay { Circle().strokeBorder(theme.color(.border), lineWidth: 1) }
        Text(model).font(.system(size: 12)).lineLimit(1)
        Spacer(minLength: 4)
        Text(agent).font(.system(size: 12)).lineLimit(1)
        Image(systemName: "mic.fill").font(.system(size: 19)).foregroundStyle(
          theme.color(.onPrimary)
        )
        .frame(width: 36, height: 36).background(theme.color(.primary), in: Circle())
      }.foregroundStyle(theme.color(.textSecondary))
    }
    .padding(14).background(
      theme.color(.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 22)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 22).strokeBorder(theme.color(.border), lineWidth: 0.7)
    }
    .accessibilityElement(children: .combine).accessibilityHint(
      "Envio disponível em uma próxima versão")
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
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        expanded = !(expanded ?? pending)
      } label: {
        HStack(spacing: 6) {
          Text(ConversationProjection.stepLabel(parts)).font(.system(size: 13))
          Image(systemName: (expanded ?? pending) ? "chevron.down" : "chevron.right").font(
            .system(size: 10))
        }.foregroundStyle(theme.color(.textSecondary)).frame(
          maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain).accessibilityLabel(ConversationProjection.stepLabel(parts))
      if expanded ?? pending {
        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
          if part.type == "reasoning" {
            DisclosureGroup {
              Text(part.text ?? "").font(.footnote).textSelection(.enabled)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "sparkles")
                Text(
                  "Pensou\(part.time?.completed.map { " \(ConversationProjection.duration($0 - (part.time?.created ?? $0)))" } ?? "")"
                )
              }
            }.font(.system(size: 14)).foregroundStyle(theme.color(.textSecondary))
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
      TimelineView(.periodic(from: .now, by: 1)) { context in
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
                  - (store.shells.first { $0.metadata?["sessionID"]?.string == child?.id }?.time
                    .started ?? child!.time.updated))
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
    VStack(alignment: .leading, spacing: 8) {
      Button {
        if !detail.insert(key).inserted { detail.remove(key) }
      } label: {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          HStack(alignment: .top, spacing: 10) {
            Image(
              systemName: part.failed
                ? "exclamationmark.triangle"
                : part.running
                  ? "circle.dotted"
                  : part.name == "read"
                    ? "doc.text"
                    : ["edit", "write", "patch"].contains(part.name) ? "pencil" : "terminal"
            )
            .frame(width: 18)
            Text(part.summary(now: context.date.timeIntervalSince1970 * 1000)).font(
              .system(size: 13)
            ).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
          }
          .foregroundStyle(
            theme.color(part.failed ? .error : part.running ? .success : .text)
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
                Array((file["patch"]?.string ?? "").components(separatedBy: "\n").enumerated()),
                id: \.offset
              ) { _, line in
                Text(line).foregroundStyle(
                  theme.color(
                    line.hasPrefix("+") ? .diffAdd : line.hasPrefix("-") ? .diffDelete : .text))
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
          }
        }
        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
      }
    }
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
