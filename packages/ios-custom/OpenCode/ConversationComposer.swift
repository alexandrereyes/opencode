import OpenCodeKit
import SwiftUI

struct ConversationComposer: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionAlerts) private var alerts
  let store: ConversationStore
  @Bindable var draft: ConversationDraft
  @State private var expandedSendRevision = 0
  @State private var expandedNavigationID: UUID?
  var body: some View {
    VStack(spacing: 0) {
      ConversationRevertStatus(store: store, draft: draft)
      if !draft.expanded {
        ComposerEditor(store: store, draft: draft, expanded: false) { draft.expanded = true }
      }
    }
    .fullScreenCover(isPresented: $draft.expanded, onDismiss: {
      if draft.sendRevision == expandedSendRevision,
        alerts?.center.navigationID == expandedNavigationID { draft.focused = true }
    }) {
      NavigationStack {
        VStack(spacing: 8) {
          FloatingVoiceHost()
          ComposerEditor(store: store, draft: draft, expanded: true) { draft.expanded = false }
        }
          .padding(12).background(theme.color(.background))
          .navigationTitle("Mensagem").navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Recolher", systemImage: "arrow.down.right.and.arrow.up.left") {
                draft.expanded = false
              }
            }
          }.toastOverlay(store.toast).onAppear { draft.focused = true }
      }.tint(theme.color(.primary)).sessionAlertOverlay(voice: false)
        .onAppear {
          expandedNavigationID = alerts?.center.navigationID
          expandedSendRevision = draft.sendRevision
        }
    }
    .task { await draft.load() }
    .onChange(of: draft.persistenceError) { _, error in
      if let error {
        store.toast.show(error, kind: .error)
        draft.persistenceError = nil
      }
    }
  }
}

struct ComposerSendStyle: ButtonStyle {
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
              if store.isNewSession {
                Task { await store.updateModels([.modelVariant(model)], success: "Esforço salvo") }
              }
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
                Text("Padrão").font(.caption2).foregroundStyle(
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
