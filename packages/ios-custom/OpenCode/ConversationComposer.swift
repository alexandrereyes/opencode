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
  private var selection: ModelReference? { store.selectedModel(draft) }
  private var models: [ModelInfo] {
    ConversationProjection.visibleModels(store.models, preferences: store.preferences?.data.models)
      .filter { ConversationProjection.matchesModel($0, query: search) }
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
  private var providers: [String] {
    let order = store.preferences?.data.models?.providerOrder ?? []
    return Set(models.map(\.providerID)).sorted {
      let a = order.firstIndex(of: $0) ?? Int.max
      let b = order.firstIndex(of: $1) ?? Int.max
      return a == b ? $0 < $1 : a < b
    }
  }
  var body: some View {
    NavigationStack {
      List {
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
        if !favorites.isEmpty {
          Section("Favoritos") {
            ForEach(favorites, id: \.identity) { modelRow($0, showProvider: true) }
          }
        }
        if models.isEmpty {
          Section {
            Text(
              search.isEmpty
                ? "Nenhum modelo visível. Configure os modelos na aplicação web."
                : "Nenhum modelo encontrado."
            )
            .font(.subheadline).foregroundStyle(theme.color(.textSecondary))
            .listRowBackground(theme.color(.surface))
          }
        }
        ForEach(providers, id: \.self) { provider in
          Section(provider) {
            ForEach(
              models.filter { $0.providerID == provider }.sorted { $0.name < $1.name }, id: \.id
            ) { model in
              modelRow(model)
            }
          }
        }
      }
      .scrollContentBackground(.hidden).background(theme.color(.background))
      .foregroundStyle(theme.color(.text)).tint(theme.color(.primary))
      .searchable(text: $search, prompt: "Buscar modelo")
      .navigationTitle("Modelo e esforço").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluir") { dismiss() } } }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
  private func modelRow(_ model: ModelInfo, showProvider: Bool = false) -> some View {
    Button {
      let preference = store.preferences?.data.models
      let saved = preference?.variant[model.identity]
      let configured = preference?.default
      let variant =
        configured?.modelID == model.id && configured?.providerID == model.providerID
        ? configured?.variant : saved
      draft.model = ModelReference(
        id: model.id, providerID: model.providerID,
        variant: model.variants?.contains { $0.id == variant } == true ? variant : nil)
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.name)
          if showProvider {
            Text(model.providerID).font(.caption).foregroundStyle(theme.color(.textSecondary))
          }
        }
        if ConversationProjection.favorite(model, preferences: store.preferences?.data.models) {
          Image(systemName: "star.fill").foregroundStyle(theme.color(.primary)).font(.caption)
        }
        Spacer()
        if model.id == selection?.id && model.providerID == selection?.providerID {
          Image(systemName: "checkmark")
        }
      }
    }.listRowBackground(theme.color(.surface))
  }
}
