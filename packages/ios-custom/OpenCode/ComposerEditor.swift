import OpenCodeKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposerEditor: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
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
    !draft.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !draft.attachments.isEmpty
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let trigger = draft.trigger {
        ComposerSuggestions(store: store, trigger: trigger) { item in
          if item.token.kind == .command && item.token.value == "client"
            && item.token.id != "compact"
          {
            let value = NSMutableAttributedString(attributedString: draft.text)
            value.replaceCharacters(in: trigger.range, with: "")
            draft.selection = NSRange(location: trigger.range.location, length: 0)
            draft.text = value
            draft.focused = false
            models = item.token.id == "model"
            agents = item.token.id == "agent"
            return
          }
          draft.insert(item.token, replacing: trigger.range)
        }
      }
      if draft.replacing != nil {
        HStack {
          Label("Editando mensagem da fila", systemImage: "pencil").font(.caption)
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
        Text(error).font(.caption).foregroundStyle(theme.color(.error)).accessibilityIdentifier(
          "send-error")
      }
      VStack(alignment: .leading, spacing: 12) {
        if !draft.attachments.isEmpty { attachmentRow.padding(.trailing, showExpand ? 26 : 0) }
        if draft.importing {
          ProgressView("Preparando anexos…").font(.caption).tint(theme.color(.primary))
        }
        ComposerTextView(
          draft: draft, theme: theme, expanded: expanded, owner: editorID
        )
        .overlay(alignment: .topLeading) {
          if draft.text.length == 0 {
            Text("Mensagem").font(.body).foregroundStyle(theme.color(.textSecondary))
              .allowsHitTesting(false)
          }
        }
        .onGeometryChange(for: Bool.self) {
          $0.size.height > UIFont.preferredFont(forTextStyle: .body).lineHeight * 3 + 2
        } action: {
          longText = $0
        }
        .padding(.trailing, showExpand && draft.attachments.isEmpty ? 26 : 0)
        controls
      }
      .padding(14).background(
        theme.color(.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 22)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 22).strokeBorder(theme.color(.border), lineWidth: 0.7)
      }
      .overlay(alignment: .topTrailing) {
        if showExpand {
          Button(
            "Expandir compositor", systemImage: "arrow.up.left.and.arrow.down.right", action: expand
          )
          .labelStyle(.iconOnly).font(.system(size: 12)).foregroundStyle(
            theme.color(.textSecondary)
          )
          .frame(width: 28, height: 28).padding(7).buttonStyle(.plain)
        }
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 60).onEnded { value in
          if !expanded && value.translation.height < -60 && abs(value.translation.width) < 70 {
            expand()
          }
        })
    }
    .sheet(isPresented: $models) { ConversationModelPicker(store: store, draft: draft) }
    .sheet(isPresented: $agents) { agentSheet }
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
    .onAppear { draft.editorOwner = editorID }
    .onDisappear {
      if draft.editorOwner == editorID { draft.editorOwner = nil }
      Task { await draft.persist() }
    }
  }
  private var controls: some View {
    HStack(spacing: 10) {
      Menu {
        Menu("Imagens e arquivos", systemImage: "photo") {
          Button("Fotos", systemImage: "photo.on.rectangle") {
            draft.focused = false
            photos = true
          }
          Button("Arquivos", systemImage: "folder") {
            draft.focused = false
            files = true
          }
        }
        Button("Comandos", systemImage: "slash.circle") { draft.insertTrigger("/") }
        Button("Contexto", systemImage: "at") { draft.insertTrigger("@") }
        if !expanded {
          Button(
            "Expandir compositor", systemImage: "arrow.up.left.and.arrow.down.right", action: expand
          )
        }
      } label: {
        Image(systemName: "plus").font(.system(size: 18)).frame(width: 31, height: 31)
          .overlay { Circle().strokeBorder(theme.color(.border), lineWidth: 1) }
      }.accessibilityLabel("Adicionar")
      Button {
        draft.focused = false
        models = true
      } label: {
        Text(store.modelLabel(store.selectedModel(draft))).font(.system(size: 12)).lineLimit(1)
      }.accessibilityLabel("Modelo e esforço").accessibilityIdentifier("model-picker")
      Spacer(minLength: 2)
      Button {
        draft.focused = false
        agents = true
      } label: {
        Text(draft.agent ?? store.session?.agent ?? "build").font(.system(size: 12)).lineLimit(1)
      }.accessibilityLabel("Agente").accessibilityIdentifier("agent-picker")
      Button {
        Task { await store.send(draft) }
      } label: {
        Group {
          if draft.sending {
            ProgressView().tint(theme.color(.onPrimary))
          } else {
            Image(systemName: hasContent ? "arrow.up" : "mic.fill").font(
              .system(size: 19, weight: .medium))
          }
        }.foregroundStyle(theme.color(.onPrimary)).frame(width: 36, height: 36)
          .background(theme.color(.primary), in: Circle())
      }
      .disabled(
        !hasContent || draft.sending || draft.importing || !store.ready
          || store.selectedModel(draft) == nil
      )
      .buttonStyle(ComposerSendStyle()).accessibilityLabel(
        hasContent ? "Enviar mensagem" : "Microfone"
      )
      .accessibilityHint(hasContent ? "" : "Em breve")
      .contextMenu {
        if hasContent && store.executing {
          Button(
            store.preferences?.data.settings.followUpBehavior == .queue
              ? "Enviar agora" : "Adicionar à fila"
          ) {
            Task { await store.send(draft, alternate: true) }
          }
        }
      }
    }.foregroundStyle(theme.color(.textSecondary)).buttonStyle(.plain).disabled(
      draft.sending || draft.importing)
  }
  private var attachmentRow: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(draft.attachments) { attachment in
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
          if let model = agent.model { draft.model = model }
          agents = false
        } label: {
          HStack {
            AgentPixels(color: theme.agentColor(agent, id: agent.id), running: false)
            Text(agent.name)
            Spacer()
            if agent.id == (draft.agent ?? store.session?.agent) { Image(systemName: "checkmark") }
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
      Text(attachment.name).font(.caption).lineLimit(1).frame(maxWidth: 130)
      Button("Remover \(attachment.name)", systemImage: "xmark", action: remove).labelStyle(
        .iconOnly
      )
      .font(.caption).frame(width: 24, height: 34)
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
