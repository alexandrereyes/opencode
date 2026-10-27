import AVFoundation
import AppKit
import OpenCodeKit
import SwiftUI

/// The chat column, built from the iPhone's shared pieces (`OpenCode/ConversationColumn/`): user bubbles on the
/// right with Desfazer, Copiar and the time; the assistant's text at full width; activity cards with their
/// timeline; the response footer; the running tray with the queue; and the composer with the model and MCP
/// capsules over `build · Contexto · Cache`. File names in the answers open Arquivos at their folder.
struct MacTranscriptView: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: MacTranscriptStore
  let runtime: MacRuntime
  /// Set while a subagent is open in the middle column, for the way back.
  let parentTitle: String?
  @State private var revertCandidate: ConversationMessage?
  @State private var reader = MacReadAloud()
  @State private var viewport: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      if let parentTitle {
        HStack {
          Button {
            runtime.selection.childID = nil
          } label: {
            Label(parentTitle, systemImage: "chevron.left").lineLimit(1)
          }
          .buttonStyle(.plain).foregroundStyle(theme.color(.text))
          Spacer()
          Text("Subagente").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        }
        .appFont(.secondary)
        .padding(.horizontal, 24).padding(.vertical, 8)
        ContextHairline()
      }
      transcript
      VStack(spacing: 8) {
        if store.session?.revert != nil { revertBar }
        tray
        MacComposer(store: store)
      }
      .frame(maxWidth: 760)
      .padding(.horizontal, 24).padding(.bottom, 10).padding(.top, 6)
      .frame(maxWidth: .infinity)
    }
    .environment(\.openURL, OpenURLAction { url in
      if let path = FileReference.path(url) {
        open(path)
        return .handled
      }
      return .systemAction
    })
    .alert("Redefinir para este ponto?", isPresented: Binding(
      get: { revertCandidate != nil }, set: { if !$0 { revertCandidate = nil } }), presenting: revertCandidate
    ) { message in
      Button("Cancelar", role: .cancel) { revertCandidate = nil }
      Button("Redefinir", role: .destructive) {
        revertCandidate = nil
        Task { await store.revert(to: message) }
      }
    } message: { _ in
      Text("A mensagem volta para o campo de texto e as seguintes ficam ocultas até Refazer. Enviar uma nova mensagem apaga as ocultas de vez.")
    }
  }

  private var transcript: some View {
    let marks = store.marks
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          if let error = store.error {
            Label(error, systemImage: "exclamationmark.triangle").appFont(.caption)
              .foregroundStyle(theme.color(.error))
          }
          ForEach(store.activity.messages) { item in
            MacMessageView(
              item: item, store: store, footer: marks.footers.contains(item.id), reader: reader,
              revert: store.acting.contains("revert") ? nil : { revertCandidate = $0 },
              openChild: { runtime.selection.childID = $0 })
            .id(item.id)
          }
          if store.loaded && store.activity.messages.isEmpty {
            Text("Nenhuma mensagem nesta conversa.").appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
          }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
        // A short conversation sits at the bottom, by the composer. Filling the viewport keeps AppKit from
        // drawing the document's top edge as a line across the column.
        .frame(minHeight: viewport, alignment: .bottom)
        .frame(maxWidth: .infinity)
      }
      .defaultScrollAnchor(.bottom)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
      .onChange(of: store.activity.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
    }
  }

  @ViewBuilder private var tray: some View {
    let model = store.modelLabel(store.session?.model).components(separatedBy: " · ").first
    ConversationRunTray(
      run: store.running
        ? ConversationRunTrayRun(
          model: model.flatMap { $0.isEmpty ? nil : $0 } ?? "Agente",
          started: ConversationProjection.executionStarted(store.messages, complete: store.complete),
          background: nil, backgroundBusy: false,
          stop: { Task { await store.stop() } }, stopping: store.acting.contains("stop"))
        : nil,
      queue: store.queue.map {
        ConversationRunTrayItem(id: $0.id, text: $0.payload.displayText, actionable: !store.acting.contains($0.id))
      },
      editDisabled: store.sending,
      sendNow: { item in
        guard let queued = store.queue.first(where: { $0.id == item.id }) else { return }
        Task { await store.promote(queued) }
      },
      edit: { item in
        guard let queued = store.queue.first(where: { $0.id == item.id }) else { return }
        Task { await store.edit(queued) }
      },
      remove: { item in
        guard let queued = store.queue.first(where: { $0.id == item.id }) else { return }
        Task { await store.cancel(queued) }
      })
  }

  /// After Desfazer: the hidden part waits for Refazer until the next prompt commits it.
  private var revertBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.uturn.backward").foregroundStyle(theme.color(.icon))
      Text("Mensagens seguintes ocultas").foregroundStyle(theme.color(.textSecondary))
      Spacer()
      Button("Refazer") { Task { await store.revert(to: nil) } }
        .buttonStyle(.plain).foregroundStyle(theme.color(.primary))
        .disabled(store.acting.contains("revert"))
    }
    .appFont(.footnote)
    .padding(.horizontal, 14).padding(.vertical, 8)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 12))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color(.border), lineWidth: 0.7) }
  }

  /// A file named in the answer opens Arquivos already in its folder, with the file selected.
  private func open(_ source: String) {
    guard let directory = store.session?.location.directory else { return }
    Task {
      let path = try? await store.sessions.client.fileLinkMatches(source, directory: directory).first
      guard let path else {
        store.sessions.toast.show("Arquivo não encontrado: \(source)", kind: .error)
        return
      }
      runtime.showFiles(at: URL(fileURLWithPath: path).deletingLastPathComponent().path, file: path)
    }
  }
}

// MARK: - Messages

private struct MacMessageView: View {
  @Environment(\.appTheme) private var theme
  let item: ConversationActivityMessage
  let store: MacTranscriptStore
  let footer: Bool
  let reader: MacReadAloud
  let revert: ((ConversationMessage) -> Void)?
  let openChild: (String) -> Void

  private var message: ConversationMessage { item.message }

  var body: some View {
    if message.type == .user {
      MacUserBubble(message: message, revert: revert)
    } else if message.type == .assistant || !item.rows.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(item.rows) { row in
          switch row.kind {
          case .text:
            if let entry = row.parts.first { MacMarkdownText(text: entry.part.text ?? "") }
          case .divider:
            ContextHairline()
          case .group:
            MacActivityGroup(row: row, store: store, openChild: openChild)
          case .tool, .unknown:
            ForEach(ConversationActivityItem.project(row.parts)) { activity in
              MacActivityItem(item: activity, store: store, openChild: openChild)
            }
          }
        }
        if let error = message.error {
          Text(error.object?["message"]?.string ?? error.formatted).appFont(.caption)
            .foregroundStyle(theme.color(.error)).textSelection(.enabled)
        }
        if footer, message.time.completed != nil, message.error == nil, !message.responseText.isEmpty {
          responseFooter
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if message.type != .idle || message.outcome == "interrupted" || message.outcome == "failed" {
      Text(message.notice).appFont(.caption)
        .foregroundStyle(theme.color(message.type == .idle ? .warning : .textSecondary))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// `Opus 5.5 · xhigh · 27/10 07:18`, Copiar and Ouvir, like the iPhone.
  private var responseFooter: some View {
    HStack(spacing: 12) {
      Text(ConversationProjection.footer(message, models: store.models)).monospacedDigit()
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(responseText, forType: .string)
        store.sessions.toast.show("Resposta copiada")
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .buttonStyle(.plain).help("Copiar resposta").accessibilityLabel("Copiar resposta")
      Button {
        reader.toggle(message.id, text: responseText)
      } label: {
        Image(systemName: reader.speaking == message.id ? "stop" : "play")
      }
      .buttonStyle(.plain).help(reader.speaking == message.id ? "Parar leitura" : "Ouvir resposta")
      .accessibilityLabel(reader.speaking == message.id ? "Parar leitura" : "Ouvir resposta")
    }
    .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
  }

  /// The turn's answer: every response text since the prompt that started it, like the iPhone's Copiar.
  private var responseText: String {
    let messages = store.messages
    guard let end = messages.firstIndex(where: { $0.id == message.id }) else { return message.responseText }
    let start = messages[..<end].lastIndex { $0.type == .user }.map { $0 + 1 } ?? 0
    return messages[start...end].map(\.responseText).filter { !$0.isEmpty }.joined(separator: "\n\n")
  }
}

/// The prompt on the right in the user's bubble, with Desfazer, Copiar and the time below it.
private struct MacUserBubble: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let revert: ((ConversationMessage) -> Void)?

  var body: some View {
    HStack {
      Spacer(minLength: 80)
      VStack(alignment: .trailing, spacing: 5) {
        Text(message.displayText)
          .appFont(.message)
          .foregroundStyle(theme.color(.userBubbleText))
          .textSelection(.enabled)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(theme.color(.userBubble), in: RoundedRectangle(cornerRadius: 16))
        HStack(spacing: 12) {
          if let revert {
            Button { revert(message) } label: { Image(systemName: "arrow.uturn.backward") }
              .buttonStyle(.plain).help("Redefinir para este ponto").accessibilityLabel("Redefinir para este ponto")
          }
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.displayText, forType: .string)
          } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.plain).help("Copiar mensagem").accessibilityLabel("Copiar mensagem")
          Text(ConversationProjection.date(message.time.created, format: "HH:mm")).monospacedDigit()
        }
        .appFont(.bubbleMeta).foregroundStyle(theme.color(.textSecondary))
        .padding(.trailing, 4)
      }
    }
  }
}

// MARK: - Activity

/// An activity group as the shared card: closed by default; open, its timeline lists the first items and
/// folds the rest behind `Mais N ferramentas…`.
private struct MacActivityGroup: View {
  let row: ConversationActivityRow
  let store: MacTranscriptStore
  let openChild: (String) -> Void
  private let folded = 4

  private var expanded: Bool { store.expansion(row.id) }
  private var showsAll: Bool { store.expansion(row.id + ":all") }

  var body: some View {
    let items = row.items.isEmpty ? ConversationActivityItem.project(row.parts) : row.items
    let hidden = items.count > folded + 1 && !showsAll ? Array(items.dropFirst(folded)) : []
    ConversationActivityCard(parts: row.parts, expanded: expanded, pending: row.pending,
      identifier: "tool-group-\(row.id)") {
      store.expanded[row.id] = !expanded
    } content: {
      ConversationTimeline {
        ForEach(hidden.isEmpty ? items : Array(items.prefix(folded))) { item in
          ConversationTimelineRow(done: item.completed) {
            MacActivityItem(item: item, store: store, openChild: openChild)
          }
        }
        if !hidden.isEmpty {
          ConversationTimelineRow(done: hidden.allSatisfy(\.completed)) {
            Button {
              store.expanded[row.id + ":all"] = true
            } label: {
              ConversationTimelineLabel(icon: "ellipsis", name: "Mais \(hidden.map(\.parts.count).reduce(0, +)) ferramentas…",
                duration: total(hidden).map(ConversationProjection.duration)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func total(_ items: [ConversationActivityItem]) -> Double? {
    let spans = items.map(\.duration)
    guard spans.allSatisfy({ $0 != nil }) else { return nil }
    return spans.compactMap { $0 }.reduce(0, +)
  }
}

/// One timeline item, drawn with the shared `ConversationTimelineLabel`: grouped reads, edited files with
/// `+N −M`, searches, skills, notices, reasoning, a subagent with its agent chip and the button that opens it,
/// and any other call with its target. A call with output opens it below.
private struct MacActivityItem: View {
  @Environment(\.appTheme) private var theme
  let item: ConversationActivityItem
  let store: MacTranscriptStore
  let openChild: (String) -> Void

  private var duration: String? { item.duration.map(ConversationProjection.duration) }
  private var key: String { "detail:" + item.id }
  private var open: Bool { store.expansion(key) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      label
      if open, let detail { detailView(detail) }
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
      if item.files.count == 1, let file = item.files.first {
        ConversationTimelineLabel(icon: "pencil", name: title, target: (file.path as NSString).lastPathComponent,
          duration: duration, lines: 1) { counts(file) }
      } else {
        ConversationTimelineLabel(icon: "pencil", name: title,
          target: item.files.isEmpty ? "" : "\(item.files.count) arquivos", monospaced: false, duration: duration) {
          EmptyView()
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

  /// A call with something to show opens it; one without stays a plain line (a disabled button would dim it).
  @ViewBuilder private func toggle(@ViewBuilder _ content: () -> some View) -> some View {
    if detail == nil {
      content()
    } else {
      Button {
        store.expanded[key] = !open
      } label: {
        content().contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  private func subagent(_ part: ConversationPart) -> some View {
    let id = part.input["agent"]?.string ?? "subagent"
    let agent = store.agents.first { $0.id == id }
    let child = part.metadata["sessionID"]?.string
    let running = child.map(store.sessions.active.contains) ?? part.running
    let color = theme.agentColor(agent, id: id)
    return Button {
      if let child { openChild(child) }
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
  }

  private func counts(_ file: ConversationActivityFile) -> some View {
    HStack(spacing: 5) {
      if file.additions > 0 || file.status == "added" { Text("+\(file.additions)").foregroundStyle(theme.color(.success)) }
      if file.deletions > 0 || file.status == "deleted" { Text("−\(file.deletions)").foregroundStyle(theme.color(.error)) }
    }
    .monospacedDigit().fixedSize()
  }

  /// What a call opens to: its error, its output, or a reasoning's text.
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
    .frame(maxHeight: 220)
    .fixedSize(horizontal: false, vertical: true)
    .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
  }
}

extension MacTranscriptStore {
  func expansion(_ key: String) -> Bool { expanded[key] == true }
}

// MARK: - Markdown

/// The assistant's Markdown, block by block: headings, paragraphs, bullet and numbered lists, quotes and code.
/// Inline styles and links come from `AttributedString(markdown:)`; code spans naming a file become
/// `opencode-file:` links, like the iPhone's file references. Each block's text is selectable.
struct MacMarkdownText: View {
  @Environment(\.appTheme) private var theme
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(MacMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(let level, let value):
          Text(MacMarkdown.inline(value)).font(.system(size: level <= 2 ? 15 : 14, weight: .semibold))
            .foregroundStyle(theme.color(.textStrong)).padding(.top, 2)
        case .paragraph(let value):
          Text(MacMarkdown.inline(value)).appFont(.message).lineSpacing(3).foregroundStyle(theme.color(.text))
        case .item(let marker, let indent, let value):
          HStack(alignment: .firstTextBaseline, spacing: 9) {
            // Like the iPhone's answers: a primary dot for bullets, the number for ordered items.
            Text(marker).monospacedDigit().foregroundStyle(theme.color(marker == "•" ? .primary : .textSecondary))
            Text(MacMarkdown.inline(value)).lineSpacing(3).foregroundStyle(theme.color(.text))
          }
          .appFont(.message).padding(.leading, CGFloat(indent) * 16 + 4)
        case .quote(let value):
          Text(MacMarkdown.inline(value)).appFont(.message).lineSpacing(3).foregroundStyle(theme.color(.textSecondary))
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(theme.color(.borderStrong)).frame(width: 2) }
        case .code(let value):
          ScrollView(.horizontal) {
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.color(.codeText))
              .padding(10)
          }
          .scrollIndicators(.never)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
          .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.codeBorder), lineWidth: 0.7) }
        case .rule:
          ContextHairline()
        }
      }
    }
    .tint(theme.color(.textAccent))
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum MacMarkdown {
  enum Block: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case item(String, Int, String)
    case quote(String)
    case code(String)
    case rule
  }

  static func blocks(_ text: String) -> [Block] {
    var blocks: [Block] = []
    var paragraph: [String] = []
    var fence: [String]?
    func flush() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
      paragraph = []
    }
    for line in text.components(separatedBy: "\n") {
      if fence != nil {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          blocks.append(.code(fence!.joined(separator: "\n")))
          fence = nil
        } else {
          fence!.append(line)
        }
        continue
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        flush()
        fence = []
      } else if trimmed.isEmpty {
        flush()
      } else if let heading = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
        flush()
        blocks.append(.heading(heading.output.1.count, String(heading.output.2)))
      } else if trimmed.firstMatch(of: /^([-*_])\s*(\1\s*){2,}$/) != nil {
        flush()
        blocks.append(.rule)
      } else if let item = line.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.+)$/) {
        flush()
        let marker = String(item.output.2)
        blocks.append(.item(marker.first?.isNumber == true ? marker : "•", item.output.1.count / 2,
          String(item.output.3)))
      } else if let quote = line.firstMatch(of: /^\s*>\s?(.*)$/) {
        flush()
        blocks.append(.quote(String(quote.output.1)))
      } else {
        paragraph.append(line)
      }
    }
    if let fence { blocks.append(.code(fence.joined(separator: "\n"))) }
    flush()
    return blocks
  }

  static func inline(_ text: String) -> AttributedString {
    let linked = text.replacing(/`([^`\n]+)`/) { match in
      let code = String(match.output.1)
      guard FileReference.inline(code) != nil else { return "`\(code)`" }
      return "[\(code)](\(FileReference.link(code).absoluteString))"
    }
    return (try? AttributedString(
      markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

// MARK: - Read aloud

/// Ouvir: reads a response with the system's Brazilian Portuguese voice; a second click stops it.
@MainActor @Observable final class MacReadAloud: NSObject, AVSpeechSynthesizerDelegate {
  private(set) var speaking: String?
  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func toggle(_ id: String, text: String) {
    let wasSpeaking = speaking == id
    synthesizer.stopSpeaking(at: .immediate)
    speaking = nil
    guard !wasSpeaking else { return }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "pt-BR")
    speaking = id
    synthesizer.speak(utterance)
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.speaking = nil }
  }
}
