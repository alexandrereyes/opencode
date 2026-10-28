import OpenCodeKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A quote comment edits its own ephemeral draft in this same editor (see QuoteCommentEditor):
/// no model, MCP or agent selectors and no `/` commands, which only run from the message itself;
/// no fullscreen (its sheet already rises with the keyboard), and submitting commits the comment
/// to the quote instead of sending.
struct ComposerComment {
  let placeholder: String
  /// Bytes of the message draft's other attachments, which share the draft's 25 MiB limit.
  let reservedBytes: Int
  let commit: () -> Void
}

struct ComposerEditor: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.voiceController) private var voice
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var store: ConversationStore
  @Bindable var draft: ConversationDraft
  let expanded: Bool
  var comment: ComposerComment? = nil
  let expand: () -> Void
  @State private var models = false
  @State private var photos = false
  @State private var files = false
  @State private var selectedPhotos: [PhotosPickerItem] = []
  @State private var editorID = UUID()
  @State private var longText = false
  @State private var suggestionReturn = ComposerSuggestionReturn()
  private var showExpand: Bool { comment == nil && !expanded && (longText || !draft.attachments.isEmpty) }
  private var hasContent: Bool {
    draft.hasText
      || !draft.attachments.isEmpty || !draft.quotes.isEmpty
  }
  private var canSubmit: Bool {
    guard comment == nil else { return hasContent && !draft.importing && !draft.recording.visible }
    return hasContent && !draft.sending && !draft.importing && !draft.recording.visible && store.ready
      && store.selectedModel(draft) != nil
  }
  private func submit() {
    guard canSubmit else { return }
    if let comment { return comment.commit() }
    Task { await store.send(draft) }
  }
  private func choose(_ item: ComposerSuggestion, replacing trigger: ComposerTrigger) {
    if item.token.kind == .command && item.token.value == "client"
      && item.token.id != "compact"
    {
      draft.replace(trigger.range, with: NSAttributedString())
      draft.focused = false
      if item.token.id == "btw" {
        let question = draft.document.expanded.text.trimmingCharacters(
          in: .whitespacesAndNewlines)
        store.sideQuestion = SideQuestionLaunch(text: question, submit: !question.isEmpty)
        draft.text = NSAttributedString()
        draft.selection = NSRange(location: 0, length: 0)
        return
      }
      models = item.token.id == "model"
      draft.choosingAgent = item.token.id == "agent" && !store.isChild && !store.masterMode
      return
    }
    draft.insert(item.token, replacing: trigger.range)
  }
  /// Return's pick: the panel's first item, only if it was loaded for the trigger still being typed.
  private func firstSuggestion() -> (() -> Void)? {
    guard let trigger = draft.trigger, comment == nil || trigger.character != "/",
      let first = suggestionReturn.first, first.trigger == trigger
    else { return nil }
    return { choose(first.item, replacing: trigger) }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let trigger = draft.trigger, comment == nil || trigger.character != "/" {
        ComposerSuggestions(store: store, trigger: trigger, ready: suggestionReturn) { choose($0, replacing: trigger) }
      }
      if draft.replacing != nil {
        HStack {
          Label("Editando mensagem da fila", systemImage: "pencil").appFont(.caption)
          Spacer()
          Button("Cancelar edição", systemImage: "xmark") {
            draft.editing = nil
            draft.replacing = nil
            draft.submission = nil
          }
          .labelStyle(.iconOnly)
        }.foregroundStyle(theme.color(.textSecondary))
      }
      if let error = draft.error {
        Text(error).appFont(.caption).foregroundStyle(theme.color(.error)).accessibilityIdentifier(
          "send-error")
      }
      if !draft.quotes.isEmpty { DraftQuotesCard(draft: draft) }
      if draft.recording.state == .pending { DictationPendingView(recording: draft.recording) }
      if let error = draft.recording.error, draft.recording.state != .pending {
        Text(error).appFont(.caption).foregroundStyle(theme.color(.error))
      }
      if voice?.sessionID != nil && !hasContent {
        Text("Encerre a chamada para ditar uma mensagem.").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      }
      VStack(alignment: .leading, spacing: 12) {
        if draft.attachments.contains(where: { $0.quoteID == nil }) {
          attachmentRow.padding(.trailing, showExpand ? 26 : 0)
        }
        if draft.importing {
          ProgressView("Preparando anexos…").appFont(.caption).tint(theme.color(.primary))
        }
        ComposerTextView(
          draft: draft, theme: theme, expanded: expanded, owner: editorID,
          label: comment == nil ? "Mensagem" : "Comentário",
          identifier: comment == nil ? "conversation-composer" : "comment-composer",
          submit: submit, canSubmit: canSubmit, firstSuggestion: firstSuggestion,
          importImages: { providers in
            Task { await store.importImages(providers, draft: draft, reservedBytes: comment?.reservedBytes ?? 0) }
          }
        )
        .overlay(alignment: .topLeading) {
          if draft.isEmpty {
            // The message field's placeholder repeats nothing VoiceOver needs; its label already says "Mensagem".
            Text(comment?.placeholder ?? "Pergunte qualquer coisa…").appFont(.body)
              .foregroundStyle(theme.color(.textSecondary)).allowsHitTesting(false)
              .accessibilityHidden(comment == nil)
          }
        }
        .onGeometryChange(for: Bool.self) {
          $0.size.height > UIFont.preferredFont(forTextStyle: .body).lineHeight * 3 + 2
        } action: {
          longText = $0
        }
        .padding(.trailing, showExpand && draft.attachments.isEmpty ? 26 : 0)
        .simultaneousGesture(
          DragGesture(minimumDistance: 60).onEnded { value in
            if comment == nil && !expanded && !draft.recording.visible && value.translation.height < -60 && abs(value.translation.width) < 70 { expand() }
          })
        controls
      }
      .padding(16).background(
        theme.color(.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 22)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 22).strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale)
      }
      .background {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-OpenCodeSizingDiagnostics") {
          LayoutBoundsProbe(id: "composer-card")
        }
        #endif
      }
      .overlay(alignment: .topTrailing) {
        if showExpand {
          Button(
            "Expandir compositor", systemImage: "arrow.up.left.and.arrow.down.right", action: expand
          )
          .labelStyle(.iconOnly).appSymbol(.inline).foregroundStyle(
            theme.color(.textSecondary)
          )
          .frame(width: 28, height: 28).padding(7).buttonStyle(.plain)
        }
      }
    }
    .sheet(isPresented: $models) { ConversationModelPicker(store: store, draft: draft).sessionAlertOverlay() }
    .sheet(isPresented: comment == nil ? $draft.choosingAgent : .constant(false)) { agentSheet.sessionAlertOverlay() }
    .sheet(item: $draft.commenting) { quote in
      QuoteCommentEditor(quote: quote, store: store, draft: draft)
        .sessionAlertOverlay()
    }
    // The message composer below the comment sheet presents the side question.
    .sheet(item: comment == nil ? $store.sideQuestion : .constant(nil)) { launch in
      SideQuestionSheet(store: store, launch: launch).sessionAlertOverlay()
    }
    .photosPicker(
      isPresented: $photos, selection: $selectedPhotos, maxSelectionCount: 10, matching: .images
    )
    .onChange(of: selectedPhotos) { _, items in
      guard !items.isEmpty else { return }
      Task {
        draft.importing = true
        defer {
          draft.importing = false
          selectedPhotos = []
        }
        for item in items {
          do {
            guard let data = try await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first ?? .jpeg
            await store.importAttachment(
              data,
              name:
                "Foto-\(UUID().uuidString.prefix(6)).\(type.preferredFilenameExtension ?? "jpg")",
              mime: type.preferredMIMEType ?? "image/jpeg", draft: draft,
              reservedBytes: comment?.reservedBytes ?? 0)
          } catch { store.toast.show("Não foi possível importar a foto.", kind: .error) }
        }
      }
    }
    .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true)
    { result in
      Task {
        draft.importing = true
        defer { draft.importing = false }
        do {
          for url in try result.get() {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= AttachmentEncoding.draftLimit else { throw AttachmentError.tooLarge }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            let mime =
              UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
              ?? "application/octet-stream"
            await store.importAttachment(
              data, name: url.lastPathComponent, mime: mime, draft: draft,
              reservedBytes: comment?.reservedBytes ?? 0)
          }
        } catch { store.toast.show(error.localizedDescription, kind: .error) }
      }
    }
    .onAppear {
      draft.editorOwner = editorID
      draft.recording.willUseAudio = { voice?.sessionID == nil }
    }
    .onChange(of: voice?.sessionID) { _, id in if id != nil { draft.recording.suspend() } }
    .alert("Baixar transcrição no aparelho?", isPresented: $draft.recording.asksDownload) {
      Button("Baixar por Wi-Fi") { draft.recording.transcription.download(cellular: false) }
      Button("Usar dados móveis") { draft.recording.transcription.download(cellular: true) }
      Button("Agora não", role: .cancel) {}
    } message: { Text(TranscriptionController.downloadMessage) }
    .alert("Permita o microfone", isPresented: $draft.recording.permissionDenied) {
      Button("Abrir Ajustes") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
      Button("Cancelar", role: .cancel) {}
    } message: { Text("Ative o microfone nos Ajustes para ditar mensagens. A transcrição é feita neste iPhone.") }
    .onDisappear {
      draft.recording.suspend()
      if draft.editorOwner == editorID { draft.editorOwner = nil }
      Task { await draft.persist() }
    }
  }
  private var controls: some View {
    // The compact microphone's slot; its hold is tracked inside it so a moving finger re-renders only that view.
    let beside = hasContent && !draft.recording.visible
    let available = !draft.sending && !draft.importing && voice?.sessionID == nil
    return ZStack(alignment: .bottomTrailing) {
      Group {
        if typeSize.isAccessibilitySize {
          ScrollView(.horizontal) { controlRow.fixedSize(horizontal: true, vertical: false) }.scrollIndicators(.hidden)
        } else { controlRow }
      }.padding(.trailing, beside ? 104 : 52).opacity(draft.recording.capturing || draft.recording.discarding ? 0 : 1)
        .allowsHitTesting(!draft.recording.capturing).accessibilityHidden(draft.recording.capturing)
      if draft.recording.capturing || draft.recording.discarding {
        DictationRecordingPanel(recording: draft.recording, hasContent: hasContent)
      }
      HStack(spacing: 0) {
        DictationCompactMicrophone(recording: draft.recording, hasContent: hasContent, available: available)
        DictationAction(recording: draft.recording, hasContent: hasContent, canSubmit: canSubmit,
          sending: draft.sending, available: available,
          submit: submit, submission: comment == nil ? .message : .comment)
          .contextMenu {
            if comment == nil && hasContent && store.executing {
              Button(store.preferences?.data.settings.followUpBehavior == .queue ? "Enviar agora" : "Adicionar à fila") {
                Task { await store.send(draft, alternate: true) }
              }.disabled(!canSubmit)
            }
          }
      }
    }.frame(minHeight: 44)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: beside)
  }
  private var controlRow: some View {
    HStack(spacing: 8) {
      Menu {
        if comment == nil && !expanded {
          Button(
            "Expandir compositor", systemImage: "arrow.up.left.and.arrow.down.right", action: expand
          )
        }
        Button("Fotos", systemImage: "photo.on.rectangle") {
          draft.focused = false
          photos = true
        }
        Button("Arquivos", systemImage: "folder") {
          draft.focused = false
          files = true
        }
      } label: {
        Image(systemName: "plus").appSymbol(.action).frame(width: 31, height: 36)
          .overlay { Circle().strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale) }
      }.menuOrder(.fixed).accessibilityLabel("Adicionar")
      if comment == nil { selectors } else { Spacer(minLength: 2) }
    }.frame(minHeight: 36).foregroundStyle(theme.color(.textSecondary)).buttonStyle(.plain).disabled(
      draft.sending || draft.importing)
  }
  @ViewBuilder private var selectors: some View {
    ComposerModelChip(label: store.modelLabel(store.selectedModel(draft))) {
      draft.focused = false
      models = true
    }.accessibilityLabel("Modelo e esforço")
      .accessibilityValue(store.modelLabel(store.selectedModel(draft))).accessibilityIdentifier("model-picker")
    if !expanded && !store.isNewSession && store.mcps.summary.visible {
      ConversationMCPPill(store: store.mcps)
    }
    // The agent lives in the footer below the card (ComposerFooter).
    Spacer(minLength: 2)
  }
  private var attachmentRow: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(draft.attachments.filter { $0.quoteID == nil }) { attachment in
          DraftAttachmentChip(attachment: attachment, url: draft.persistence.file(attachment)) {
            draft.remove(attachment)
          }.disabled(draft.sending || draft.importing)
        }
      }
    }.scrollIndicators(.hidden)
  }
  private var agentSheet: some View {
    NavigationStack {
      List(store.agents.filter { $0.hidden != true && $0.mode != "subagent" }) { agent in
        Button {
          draft.agent = agent.id
          if !store.isNewSession, let model = agent.model { draft.model = model }
          draft.choosingAgent = false
        } label: {
          HStack {
            AgentPixels(color: theme.agentColor(agent, id: agent.id), running: false)
            Text(agent.name)
            Spacer()
            if agent.id == store.selectedAgent(draft) { Image(systemName: "checkmark") }
          }
        }.listRowBackground(theme.color(.surface))
      }.scrollContentBackground(.hidden).background(theme.color(.background))
        .navigationTitle("Agente").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Concluir") { draft.choosingAgent = false } }
        }
    }.presentationDetents([
      .height(
        min(
          500,
          CGFloat(store.agents.filter { $0.hidden != true && $0.mode != "subagent" }.count) * 48
            + 110))
    ])
    .presentationDragIndicator(.visible).tint(theme.color(.primary))
  }
}

private struct DraftAttachmentChip: View {
  @Environment(\.appTheme) private var theme
  let attachment: DraftAttachment
  let url: URL
  let remove: () -> Void
  @State private var image: CGImage?
  var body: some View {
    HStack(spacing: 7) {
      if let image {
        Image(decorative: image, scale: 2).resizable().scaledToFill().frame(width: 34, height: 34)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: 5))
      } else {
        Image(systemName: attachment.mime.hasPrefix("image/") ? "photo" : "doc").frame(width: 24)
      }
      Text(attachment.name).appFont(.caption).lineLimit(1).frame(maxWidth: 130)
      Button("Remover \(attachment.name)", systemImage: "xmark", action: remove).labelStyle(
        .iconOnly
      )
      .appSymbol(.inline).frame(width: 24, height: 34)
    }.foregroundStyle(theme.color(.textSecondary)).padding(6)
      .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 10))
      .task(id: url) {
        guard attachment.mime.hasPrefix("image/") else { return }
        image = await Task.detached {
          (try? Data(contentsOf: url)).flatMap { AttachmentImage.thumbnail($0, maxPixelSize: 100) }
        }.value
      }
  }
}
