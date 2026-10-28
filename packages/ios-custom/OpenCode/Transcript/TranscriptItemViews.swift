import OpenCodeKit
import SwiftUI

/// The SwiftUI content of a hosted transcript item. Prose is rendered natively and never reaches here.
struct TranscriptItemView: View {
  let item: TranscriptItem
  let context: TranscriptContext
  var body: some View {
    content.frame(maxWidth: .infinity, alignment: .leading).modifier(TranscriptEnvironment(context: context))
  }

  @ViewBuilder private var content: some View {
    switch item.kind {
    case .older(let loading):
      TranscriptOlderRow(loading: loading, load: context.loadOlder)
    case .day(let created):
      TranscriptDayChip(created: created)
    case .prompt(let message, _):
      TranscriptPrompt(message: message.presented(isChild: context.store.isChild), context: context)
    case .pending(let inbox, _):
      TranscriptPending(item: inbox, context: context)
    case .prose, .unparsed:
      Color.clear
    case .block(let part, let block, let notes):
      TranscriptBlock(part: part, block: block, notes: notes, context: context)
        .padding(.horizontal, AppLayout.margin)
    case .rule:
      TranscriptRule().padding(.horizontal, AppLayout.margin)
    case .activity(let row, _, _):
      ConversationStep(
        parts: row.parts.map(\.part), id: row.id, store: context.store, openChild: context.openChild,
        references: row.parts, items: row.items, grouped: row.kind == .group, busy: row.pending)
        .padding(.horizontal, AppLayout.margin)
    case .shell(let message, _):
      ConversationStep(parts: message.tools, id: message.id, store: context.store, openChild: context.openChild)
        .padding(.horizontal, AppLayout.margin)
    case .notice(let message):
      TranscriptNotice(message: message).padding(.horizontal, AppLayout.margin)
    case .failure(let text, let warning):
      TranscriptFailure(text: text, warning: warning).padding(.horizontal, AppLayout.margin)
    case .footer(let message):
      TranscriptFooter(message: message, store: context.store).padding(.horizontal, AppLayout.margin)
    case .permission(let request):
      ConversationPermissionCard(request: request, store: context.store).padding(.horizontal, AppLayout.margin)
    case .question(let form):
      ConversationQuestionCard(form: form, store: context.store).padding(.horizontal, AppLayout.margin)
    }
  }
}

private struct TranscriptOlderRow: View {
  @Environment(\.appTheme) private var theme
  let loading: Bool
  let load: () -> Void
  var body: some View {
    HStack {
      Spacer()
      if loading {
        ProgressView().controlSize(.small)
      } else {
        Button("Mensagens anteriores", action: load).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      }
      Spacer()
    }
    .padding(.vertical, 6)
    .accessibilityLabel(loading ? "Carregando mensagens anteriores" : "Mensagens anteriores")
  }
}

private struct TranscriptDayChip: View {
  @Environment(\.appTheme) private var theme
  let created: Double
  var body: some View {
    Text(ConversationProjection.day(created)).appFont(.footnote, weight: .medium)
      .foregroundStyle(theme.color(.textSecondary))
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(theme.color(.codeSurface), in: Capsule())
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)
  }
}

/// A delivered prompt. The same view sits inline and pinned under the header; the layout moves it.
private struct TranscriptPrompt: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let context: TranscriptContext
  var body: some View {
    UserBubble(message: message, maximumTextHeight: context.size.height * 0.4)
      .padding(.horizontal, AppLayout.margin).padding(.vertical, 8)
      .background(theme.color(.background))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("conversation-pinned-user")
  }
}

private struct TranscriptPending: View {
  @Environment(\.appTheme) private var theme
  let item: InboxItem
  let context: TranscriptContext
  var body: some View {
    PendingUserMessage(item: item, store: context.store, maximumTextHeight: context.size.height * 0.4)
      .padding(.horizontal, AppLayout.margin).padding(.vertical, 8)
      .background(theme.color(.background))
  }
}

private struct TranscriptBlock: View {
  @Environment(\.appTheme) private var theme
  let part: TranscriptPart
  let block: MarkdownBlock
  let notes: Bool
  let context: TranscriptContext
  var body: some View {
    ResponseBlockItem(block: block, source: part.source, messageID: part.messageID, partID: part.partID,
      rasters: context.rasters(part), openNote: { context.openNote(part, $0) }, notesHeader: notes)
      .environment(\.responseQuotes, context.responseQuotes(part))
      .environment(\.responseFilesStable, part.stable)
  }
}

private struct TranscriptRule: View {
  @Environment(\.appTheme) private var theme
  var body: some View {
    Rectangle().fill(theme.color(.borderStrong)).frame(height: 1).accessibilityHidden(true)
  }
}

private struct TranscriptNotice: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  var body: some View {
    Text(message.notice).appFont(.caption)
      .foregroundStyle(theme.color(message.type == "idle" ? .warning : .textSecondary))
      .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
  }
}

private struct TranscriptFailure: View {
  @Environment(\.appTheme) private var theme
  let text: String
  let warning: Bool
  var body: some View {
    Text(text).appFont(.caption).foregroundStyle(theme.color(warning ? .warning : .error))
  }
}

/// The finished response's model, effort, date, copy and read-aloud line.
private struct TranscriptFooter: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let store: ConversationStore
  var body: some View {
    HStack(spacing: 10) {
      Text(ConversationProjection.footer(message, models: store.displayModels))
        .appFont(.caption).monospacedDigit()
      Button {
        UIPasteboard.general.string = store.responseText(endingAt: message.id)
        Haptics.play(.selection)
        store.toast.show("Resposta copiada")
      } label: {
        Image(systemName: "doc.on.doc").appSymbol(.inline)
      }
      .buttonStyle(.plain).accessibilityLabel("Copiar resposta")
      Button {
        Haptics.play(.selection)
        store.readAloudResponse(endingAt: message.id)
      } label: {
        Image(systemName: "play").appSymbol(.inline)
      }
      .buttonStyle(.plain).accessibilityLabel("Ouvir resposta")
      .accessibilityIdentifier("read-aloud-message-" + message.id)
    }.foregroundStyle(theme.color(.textSecondary))
  }
}

/// A footnote opened from a response.
struct TranscriptNote: Identifiable {
  let part: TranscriptPart
  let note: String
  var id: String { part.partID + "#" + note }
  init(part: TranscriptPart, id: String) {
    self.part = part
    note = id
  }
}

struct TranscriptNoteSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let note: TranscriptNote
  var body: some View {
    NavigationStack {
      ScrollView {
        if let block = ResponseMarkdownCache.shared.cached(note.part.source)?.first(where: {
          if case .footnote(let id, _) = $0.kind { id == note.note } else { false }
        }) {
          ResponseBlocks(blocks: block.children, source: note.part.source, messageID: note.part.messageID,
            partID: note.part.partID, rasters: [:], openNote: { _ in }).padding(20)
        }
      }
      .background(theme.color(.background))
      .navigationTitle("Nota de rodapé").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
}
