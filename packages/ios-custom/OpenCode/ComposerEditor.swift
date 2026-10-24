import OpenCodeKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposerEditor: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.voiceController) private var voice
  @Bindable var store: ConversationStore
  @Bindable var draft: ConversationDraft
  let expanded: Bool
  let expand: () -> Void
  @State private var models = false
  @State private var agents = false
  @State private var photos = false
  @State private var files = false
  @State private var selectedPhotos: [PhotosPickerItem] = []
  @State private var editorID = UUID()
  @State private var longText = false
  private var showExpand: Bool { !expanded && (longText || !draft.attachments.isEmpty) }
  private var hasContent: Bool {
    draft.hasText
      || !draft.attachments.isEmpty || !draft.quotes.isEmpty
  }
  private var canSubmit: Bool {
    hasContent && !draft.sending && !draft.importing && !draft.recording.visible && store.ready
      && store.selectedModel(draft) != nil
  }
  private func submit() {
    guard canSubmit else { return }
    Task { await store.send(draft) }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let trigger = draft.trigger {
        ComposerSuggestions(store: store, trigger: trigger) { item in
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
             agents = item.token.id == "agent" && !store.isChild && !store.masterMode
            return
          }
          draft.insert(item.token, replacing: trigger.range)
        }
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
          submit: submit, canSubmit: canSubmit
        )
        .onGeometryChange(for: Bool.self) {
          $0.size.height > UIFont.preferredFont(forTextStyle: .body).lineHeight * 3 + 2
        } action: {
          longText = $0
        }
        .padding(.trailing, showExpand && draft.attachments.isEmpty ? 26 : 0)
        .simultaneousGesture(
          DragGesture(minimumDistance: 60).onEnded { value in
            if !expanded && !draft.recording.visible && value.translation.height < -60 && abs(value.translation.width) < 70 { expand() }
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
    .sheet(isPresented: $agents) { agentSheet.sessionAlertOverlay() }
    .sheet(item: $draft.commenting) { quote in
      QuoteCommentEditor(quote: quote, store: store, draft: draft)
        .sessionAlertOverlay()
    }
    .sheet(item: $store.sideQuestion) { launch in SideQuestionSheet(store: store, launch: launch).sessionAlertOverlay() }
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
              mime: type.preferredMIMEType ?? "image/jpeg", draft: draft)
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
              data, name: url.lastPathComponent, mime: mime, draft: draft)
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
    ZStack(alignment: .bottomTrailing) {
      Group {
        if typeSize.isAccessibilitySize {
          ScrollView(.horizontal) { controlRow.fixedSize(horizontal: true, vertical: false) }.scrollIndicators(.hidden)
        } else { controlRow }
      }.padding(.trailing, 52).opacity(draft.recording.capturing || draft.recording.discarding ? 0 : 1)
        .allowsHitTesting(!draft.recording.capturing).accessibilityHidden(draft.recording.capturing)
      if draft.recording.capturing || draft.recording.discarding {
        DictationRecordingPanel(recording: draft.recording).padding(.trailing, 52)
      }
      DictationAction(recording: draft.recording, hasContent: hasContent, canSubmit: canSubmit,
        sending: draft.sending, available: !draft.sending && !draft.importing && voice?.sessionID == nil,
        submit: submit)
        .contextMenu {
          if hasContent && store.executing {
            Button(store.preferences?.data.settings.followUpBehavior == .queue ? "Enviar agora" : "Adicionar à fila") {
              Task { await store.send(draft, alternate: true) }
            }.disabled(!canSubmit)
          }
        }
    }.frame(minHeight: 44)
  }
  private var controlRow: some View {
    HStack(spacing: 8) {
      Menu {
        if !expanded {
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
      Button {
        draft.focused = false
        models = true
      } label: {
        Text(store.modelLabel(store.selectedModel(draft))).appFont(.chrome).lineLimit(1).minimumScaleFactor(0.75)
      }.accessibilityLabel("Modelo e esforço")
        .accessibilityValue(store.modelLabel(store.selectedModel(draft))).accessibilityIdentifier("model-picker")
      if !expanded && !store.isNewSession && store.mcps.summary.visible {
        ConversationMCPPill(store: store.mcps)
      }
      Spacer(minLength: 2)
      if store.isChild || store.masterMode {
        Text(store.childAgentName).appFont(.chrome).lineLimit(1)
          .accessibilityLabel("Agente: \(store.childAgentName)")
          .accessibilityIdentifier("child-agent")
      } else {
        Button {
          draft.focused = false
          agents = true
        } label: {
          Text(store.selectedAgent(draft)).appFont(.chrome).lineLimit(1)
        }.accessibilityLabel("Agente").accessibilityIdentifier("agent-picker")
      }
    }.frame(minHeight: 36).foregroundStyle(theme.color(.textSecondary)).buttonStyle(.plain).disabled(
      draft.sending || draft.importing)
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
          agents = false
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
          ToolbarItem(placement: .confirmationAction) { Button("Concluir") { agents = false } }
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
