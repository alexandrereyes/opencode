import OpenCodeKit
import SwiftUI

/// User prompts as bubbles on the right, the assistant's answers as running text. File names in code spans
/// become links that open Arquivos at the file's folder.
struct MacTranscriptView: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: MacTranscriptStore
  let runtime: MacRuntime
  /// Set while a subagent is open in the middle column, for the way back.
  let parentTitle: String?

  var body: some View {
    VStack(spacing: 0) {
      if let parentTitle {
        HStack {
          Button {
            runtime.selection.childID = nil
          } label: {
            Label(parentTitle, systemImage: "chevron.left").lineLimit(1)
          }
          .buttonStyle(.plain).foregroundStyle(theme.color(.textAccent))
          Spacer()
          Text("Subagente").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        }
        .appFont(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 8)
        Divider()
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            if let error = store.error {
              Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(theme.color(.error))
            }
            ForEach(visible) { message in
              MacMessageView(message: message) { open($0) }.id(message.id)
            }
            if store.loaded && visible.isEmpty {
              Text("Nenhuma mensagem nesta conversa.").foregroundStyle(theme.color(.textSecondary))
            }
          }
          .frame(maxWidth: 760, alignment: .leading)
          .padding(.horizontal, 28).padding(.vertical, 20)
          .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .onChange(of: visible.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
      }
      composer
    }
  }

  private var visible: [ConversationMessage] {
    store.messages.filter {
      ($0.type == .user && !$0.displayText.isEmpty) || ($0.type == .assistant && !$0.responseText.isEmpty)
    }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("Pergunte qualquer coisa…", text: $store.draft, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...8)
        .appFont(.body)
        .onSubmit { Task { await store.send() } }
        .disabled(store.session?.model == nil)
      Button {
        Task { await store.send() }
      } label: {
        Image(systemName: store.sending ? "hourglass" : "arrow.up")
          .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.color(.onPrimary))
          .frame(width: 30, height: 30).background(theme.color(.primary), in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.sending)
      .help("Enviar (Return)")
    }
    .padding(12)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 18))
    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(.border), lineWidth: 1) }
    .frame(maxWidth: 760)
    .padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
    .frame(maxWidth: .infinity)
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

private struct MacMessageView: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let open: (String) -> Void

  var body: some View {
    if message.type == .user {
      HStack {
        Spacer(minLength: 80)
        Text(message.displayText)
          .appFont(.message)
          .foregroundStyle(theme.color(.userBubbleText))
          .textSelection(.enabled)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(theme.color(.userBubble), in: RoundedRectangle(cornerRadius: 16))
      }
    } else {
      Text(MacMarkdown.attributed(message.responseText))
        .appFont(.message)
        .lineSpacing(3)
        .foregroundStyle(theme.color(.text))
        .tint(theme.color(.textAccent))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
          if let path = FileReference.path(url) {
            open(path)
            return .handled
          }
          return .systemAction
        })
    }
  }
}

/// Inline Markdown, with headings shown in bold and list markers as bullets; block structure keeps its line
/// breaks. Code spans naming a file become `opencode-file:` links, like the iPhone's file references.
enum MacMarkdown {
  static func attributed(_ text: String) -> AttributedString {
    let blocks = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
      if let heading = line.firstMatch(of: /^#{1,6}\s+(.+)$/) { return "**\(heading.output.1)**" }
      if let item = line.firstMatch(of: /^(\s*)[-*+]\s+(.+)$/) { return "\(item.output.1)•  \(item.output.2)" }
      return String(line)
    }.joined(separator: "\n")
    let linked = blocks.replacing(/`([^`\n]+)`/) { match in
      let code = String(match.output.1)
      guard FileReference.inline(code) != nil else { return "`\(code)`" }
      return "[`\(code)`](\(FileReference.link(code).absoluteString))"
    }
    return (try? AttributedString(
      markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
