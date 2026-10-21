import OpenCodeKit
import SwiftUI

/// TextKit storage preserves attributed ranges and selection for wave 3's inline tokens.
struct ComposerTextView: UIViewRepresentable {
  @Binding var text: NSAttributedString
  let theme: AppTheme
  var enabled: Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView(usingTextLayoutManager: true)
    view.backgroundColor = theme.uiColor(.surface).withAlphaComponent(0)
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.delegate = context.coordinator
    view.accessibilityLabel = "Mensagem"
    view.accessibilityIdentifier = "conversation-composer"
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let toolbar = UIToolbar()
    toolbar.items = [
      .flexibleSpace(),
      UIBarButtonItem(
        title: "Concluir", style: .prominent,
        target: context.coordinator, action: #selector(Coordinator.dismissKeyboard)),
    ]
    toolbar.sizeToFit()
    view.inputAccessoryView = toolbar
    context.coordinator.view = view
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.parent = self
    view.isEditable = enabled
    view.tintColor = theme.uiColor(.primary)
    let value = NSMutableAttributedString(attributedString: text)
    if value.length > 0 {
      value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) {
        attributes, range, _ in
        if attributes[.font] == nil {
          value.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: range)
        }
        if attributes[.foregroundColor] == nil {
          value.addAttribute(.foregroundColor, value: theme.uiColor(.text), range: range)
        }
      }
    }
    if !view.attributedText.isEqual(to: value) {
      let selection = view.selectedRange
      view.attributedText = value
      view.selectedRange = NSRange(location: min(selection.location, value.length), length: 0)
    }
    view.typingAttributes = [
      .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: theme.uiColor(.text),
    ]
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    guard let width = proposal.width else { return nil }
    let line = UIFont.preferredFont(forTextStyle: .body).lineHeight
    let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    uiView.isScrollEnabled = fitting.height > line * 6 + 2
    return CGSize(width: width, height: max(line + 2, min(line * 6 + 2, fitting.height)))
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ComposerTextView
    weak var view: UITextView?
    init(_ parent: ComposerTextView) { self.parent = parent }
    func textViewDidChange(_ textView: UITextView) { parent.text = textView.attributedText }
    @objc func dismissKeyboard() { view?.resignFirstResponder() }
  }
}

struct ConversationComposer: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  @Bindable var draft: ConversationDraft
  @State private var models = false
  private var hasText: Bool {
    !draft.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if draft.editing != nil {
        HStack {
          Label("Editando mensagem da fila", systemImage: "pencil").font(.caption)
          Spacer()
          Button("Cancelar edição", systemImage: "xmark") {
            draft.editing = nil
            draft.submission = nil
          }.labelStyle(.iconOnly)
        }.foregroundStyle(theme.color(.textSecondary))
      }
      if let error = draft.error {
        Text(error).font(.caption).foregroundStyle(theme.color(.error)).accessibilityIdentifier(
          "send-error")
      }
      VStack(alignment: .leading, spacing: 12) {
        ComposerTextView(text: $draft.text, theme: theme, enabled: !draft.sending)
          .overlay(alignment: .topLeading) {
            if draft.text.length == 0 {
              Text("Mensagem").font(.body).foregroundStyle(theme.color(.textSecondary))
                .allowsHitTesting(false)
            }
          }
        HStack(spacing: 10) {
          Menu {
            Button("Imagens e arquivos", systemImage: "photo") {}.disabled(true)
            Button("Comandos", systemImage: "slash.circle") {}.disabled(true)
            Button("Contexto", systemImage: "at") {}.disabled(true)
          } label: {
            Image(systemName: "plus").font(.system(size: 18)).frame(width: 31, height: 31)
              .overlay { Circle().strokeBorder(theme.color(.border), lineWidth: 1) }
          }.accessibilityLabel("Adicionar").accessibilityHint("Opções disponíveis em breve")
          Button {
            models = true
          } label: {
            Text(store.modelLabel(store.selectedModel(draft))).font(.system(size: 12)).lineLimit(1)
          }.accessibilityLabel("Modelo e esforço").accessibilityIdentifier("model-picker")
            .accessibilityValue(store.modelLabel(store.selectedModel(draft)))
          Spacer(minLength: 2)
          Menu {
            ForEach(store.agents.filter { $0.hidden != true && $0.mode != "subagent" }) { agent in
              Button {
                draft.agent = agent.id
                if let model = agent.model { draft.model = model }
              } label: {
                if agent.id == (draft.agent ?? store.session?.agent) {
                  Label(agent.name, systemImage: "checkmark")
                } else {
                  Text(agent.name)
                }
              }
            }
          } label: {
            Text(draft.agent ?? store.session?.agent ?? "build").font(.system(size: 12)).lineLimit(
              1)
          }.accessibilityLabel("Agente").accessibilityIdentifier("agent-picker")
          Button {
            Task { await store.send(draft) }
          } label: {
            Group {
              if draft.sending {
                ProgressView().tint(theme.color(.onPrimary))
              } else {
                Image(systemName: hasText ? "arrow.up" : "mic.fill").font(
                  .system(size: 19, weight: .medium))
              }
            }.foregroundStyle(theme.color(.onPrimary)).frame(width: 36, height: 36)
              .background(theme.color(.primary), in: Circle())
          }
          .disabled(!hasText || draft.sending || !store.ready || store.selectedModel(draft) == nil)
          .buttonStyle(ComposerSendStyle())
          .accessibilityLabel(hasText ? "Enviar mensagem" : "Microfone")
          .accessibilityHint(hasText ? "" : "Em breve")
          .contextMenu {
            if hasText && store.executing {
              Button(
                store.preferences?.data.settings.followUpBehavior == .queue
                  ? "Enviar agora" : "Adicionar à fila"
              ) {
                Task { await store.send(draft, alternate: true) }
              }
            }
          }
        }.foregroundStyle(theme.color(.textSecondary)).buttonStyle(.plain)
          .disabled(draft.sending)
      }
      .padding(14).background(
        theme.color(.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 22)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 22).strokeBorder(theme.color(.border), lineWidth: 0.7)
      }
    }
    .sheet(isPresented: $models) { ConversationModelPicker(store: store, draft: draft) }
  }
}

private struct ComposerSendStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
  }
}

struct ConversationModelPicker: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: ConversationStore
  @Bindable var draft: ConversationDraft
  @State private var search = ""
  @State private var detent = PresentationDetent.large
  @FocusState private var searchFocused: Bool
  private var selection: ModelReference? { store.selectedModel(draft) }
  private var models: [ModelInfo] {
    ConversationProjection.visibleModels(store.models, preferences: store.preferences?.data.models)
      .filter {
        ConversationProjection.matchesModel(
          $0, query: search, providerName: store.providerName($0.providerID))
      }
  }
  private var favorites: [ModelInfo] {
    let saved = store.preferences?.data.models
    return models.filter { ConversationProjection.favorite($0, preferences: saved) }.sorted {
      a, b in
      let first =
        saved?.favorites?.firstIndex { $0.providerID == a.providerID && $0.modelID == a.id }
        ?? Int.max
      let second =
        saved?.favorites?.firstIndex { $0.providerID == b.providerID && $0.modelID == b.id }
        ?? Int.max
      return first == second ? a.name < b.name : first < second
    }
  }
  private var providers: [ProviderInfo] {
    ConversationProjection.modelProviders(
      models, providers: store.providers,
      order: store.preferences?.data.models?.providerOrder ?? [])
  }
  var body: some View {
    NavigationStack {
      List {
        effortSection
        defaultSection
        if !favorites.isEmpty {
          Section("Favoritos") {
            ForEach(favorites, id: \.identity) { modelRow($0, showProvider: true) }
          }
        }
        if models.isEmpty {
          Section {
            Text(
              search.isEmpty
                ? "Nenhum modelo visível. Escolha quais modelos mostrar."
                : "Nenhum modelo encontrado."
            )
            .font(.subheadline).foregroundStyle(theme.color(.textSecondary))
            .listRowBackground(theme.color(.surface))
          }
        }
        ForEach(providers) { provider in
          providerSection(provider)
        }
        Section {
          NavigationLink {
            ModelVisibilityView(store: store)
          } label: {
            Label("Gerenciar modelos", systemImage: "slider.horizontal.3")
          }.listRowBackground(theme.color(.surface))
        }
      }
      .scrollContentBackground(.hidden).background(theme.color(.background))
      .toastOverlay(store.toast)
      .foregroundStyle(theme.color(.text)).tint(theme.color(.primary))
      .searchable(text: $search, prompt: "Buscar modelo")
      .searchFocused($searchFocused)
      .onSubmit(of: .search) { searchFocused = false }
      .navigationTitle("Modelo e esforço").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluir") { dismiss() } } }
    }.presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
  }
  @ViewBuilder private var effortSection: some View {
    if let selected = store.models.first(where: {
      $0.id == selection?.id && $0.providerID == selection?.providerID
    }) {
      Section {
        Picker(
          "Esforço · \(selected.name)",
          selection: Binding(
            get: { selection?.variant ?? "default" },
            set: { value in
              guard var model = selection else { return }
              model.variant = value == "default" ? nil : value
              draft.model = model
            })
        ) {
          Text("Padrão").tag("default")
          ForEach((selected.variants ?? []).filter { $0.id != "default" }) {
            Text($0.id).tag($0.id)
          }
        }.pickerStyle(.menu).listRowBackground(theme.color(.surface))
      } footer: {
        Text(
          "A seleção só é aplicada ao enviar. Mensagens na fila usam a seleção ativa quando forem executadas."
        )
      }
    }
  }
  @ViewBuilder private var defaultSection: some View {
    if let model = store.preferences?.data.models?.default {
      Section("Padrão para novas sessões") {
        HStack {
          Text(
            store.modelLabel(
              ModelReference(
                id: model.modelID, providerID: model.providerID, variant: model.variant)))
          Spacer()
          Button("Limpar") {
            Task {
              await store.updateModels([.modelDefault(nil)], success: "Modelo padrão removido")
            }
          }
          .accessibilityLabel("Limpar modelo padrão").disabled(store.acting.contains("models"))
        }.font(.subheadline).listRowBackground(theme.color(.surface))
      }
    }
  }
  private func providerSection(_ provider: ProviderInfo) -> some View {
    let items = models.filter { $0.providerID == provider.id }.sorted {
      $0.name.localizedCompare($1.name) == .orderedAscending
    }
    return Section(provider.name) {
      ForEach(items, id: \.id) { model in modelRow(model, showProvider: false) }
    }
  }
  private func modelRow(_ model: ModelInfo, showProvider: Bool = false) -> some View {
    let favorite = ConversationProjection.favorite(
      model, preferences: store.preferences?.data.models)
    let context = model.limit.context.formatted(
      .number.locale(Locale(identifier: "pt_BR")).notation(.compactName).precision(
        .fractionLength(0...1)))
    let subtitle =
      "\(showProvider ? store.providerName(model.providerID) + " · " : "")\(context) tokens · \(model.variants?.count ?? 0) níveis"
    return HStack(spacing: 12) {
      Button {
        draft.model = reference(model)
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
              Text(model.name).foregroundStyle(theme.color(.text))
              if isDefault(model) {
                Label("Padrão", systemImage: "pin.fill").font(.caption2).foregroundStyle(
                  theme.color(.info))
              }
            }
            Text(subtitle)
              .font(.caption).foregroundStyle(theme.color(.textSecondary))
          }
          Spacer(minLength: 0)
          if model.id == selection?.id && model.providerID == selection?.providerID {
            Image(systemName: "checkmark")
          }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("choose-\(model.identity)")
      Button {
        Task {
          await store.updateModels(
            [.modelFavorite(providerID: model.providerID, modelID: model.id, favorite: !favorite)],
            success: !favorite ? "Modelo adicionado aos favoritos" : "Modelo removido dos favoritos"
          )
        }
      } label: {
        Image(systemName: favorite ? "star.fill" : "star")
          .foregroundStyle(theme.color(.primary)).frame(width: 32, height: 36)
      }.buttonStyle(.borderless).disabled(store.acting.contains("models"))
        .accessibilityLabel("\(favorite ? "Desfavoritar" : "Favoritar") \(model.name)")
        .accessibilityIdentifier("favorite-\(model.identity)")
    }
    .contextMenu { defaultAction(model) }
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      defaultAction(model).tint(theme.color(.primary))
    }
    .listRowBackground(theme.color(.surface))
  }
  private func isDefault(_ model: ModelInfo) -> Bool {
    let current = store.preferences?.data.models?.default
    return current?.providerID == model.providerID && current?.modelID == model.id
  }
  private func defaultAction(_ model: ModelInfo) -> some View {
    Button(
      isDefault(model) ? "Limpar modelo padrão" : "Usar como padrão para novas sessões",
      systemImage: "pin"
    ) {
      Task {
        await store.updateModels(
          [.modelDefault(isDefault(model) ? nil : reference(model))],
          success: isDefault(model) ? "Modelo padrão removido" : "Modelo padrão definido")
      }
    }.disabled(store.acting.contains("models"))
  }
  private func reference(_ model: ModelInfo) -> ModelReference {
    if let selection, selection.id == model.id && selection.providerID == model.providerID {
      return selection
    }
    let preference = store.preferences?.data.models
    let saved = preference?.variant[model.identity]
    let configured = preference?.default
    let variant =
      configured?.modelID == model.id && configured?.providerID == model.providerID
      ? configured?.variant : saved
    return ModelReference(
      id: model.id, providerID: model.providerID,
      variant: model.variants?.contains { $0.id == variant } == true ? variant : nil)
  }
}
