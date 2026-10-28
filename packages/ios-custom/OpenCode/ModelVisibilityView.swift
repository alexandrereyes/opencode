import OpenCodeKit
import SwiftUI

/// What "Gerenciar modelos" reads and changes: the conversation's catalog on the iPhone, the server's catalog in
/// the Mac's Ajustes.
@MainActor protocol ModelVisibilitySource: AnyObject {
  var models: [ModelInfo] { get }
  var providers: [ProviderInfo] { get }
  var preferences: Preferences? { get }
  var acting: Set<String> { get }
  var toast: ToastCenter { get }
  func providerName(_ id: String) -> String
  func updateModels(_ intents: [PreferenceIntent], success: String) async
}

#if os(iOS)
extension ConversationStore: ModelVisibilitySource {}
#endif

struct ModelVisibilityView<Source: ModelVisibilitySource>: View {
  @Environment(\.appTheme) private var theme
  let store: Source
  @State private var search = ""
  @FocusState private var searchFocused: Bool
  private var enabled: [ModelInfo] { store.models.filter { $0.enabled != false } }
  private var filtered: [ModelInfo] {
    enabled.filter {
      ConversationProjection.matchesModel(
        $0, query: search, providerName: store.providerName($0.providerID))
    }
  }
  private var providers: [ProviderInfo] {
    ConversationProjection.modelProviders(
      filtered, providers: store.providers,
      order: store.preferences?.data.models?.providerOrder ?? [])
  }
  var body: some View {
    #if os(iOS)
    list
      .searchable(text: $search, prompt: "Buscar em todos os modelos")
      .searchFocused($searchFocused)
      .onSubmit(of: .search) { searchFocused = false }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Gerenciar modelos").navigationBarTitleDisplayMode(.inline)
      .toastOverlay(store.toast)
    #else
    VStack(spacing: 0) {
      TextField("Buscar em todos os modelos", text: $search).textFieldStyle(.roundedBorder).padding(12)
      list
    }
    .toastOverlay(store.toast)
    #endif
  }

  private var list: some View {
    List {
      Section {
        Text(
          "Escolha quais modelos aparecem no seletor. O controle do provedor altera todos os seus modelos, mesmo durante uma busca."
        )
        .font(.footnote).foregroundStyle(theme.color(.textSecondary))
      }.listRowBackground(theme.color(.surface))
      ForEach(providers) { provider in
        Section {
          ForEach(
            filtered.filter { $0.providerID == provider.id }.sorted {
              $0.name.localizedCompare($1.name) == .orderedAscending
            }, id: \.id
          ) { model in
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(model.name).font(.subheadline)
                Text(model.id).font(.caption2).foregroundStyle(theme.color(.textSecondary))
              }
              Spacer()
              Toggle(
                model.name,
                isOn: Binding(
                  get: { visible(model) },
                  set: { value in
                    Task {
                      await store.updateModels(
                        [
                          .modelVisibility(
                            providerID: model.providerID, modelID: model.id, visible: value)
                        ],
                        success: value ? "Modelo visível no seletor" : "Modelo ocultado do seletor")
                    }
                  })
              ).labelsHidden().accessibilityLabel("Mostrar \(model.name)")
                .accessibilityIdentifier("visible-\(model.identity)")
            }.listRowBackground(theme.color(.surface))
          }
        } header: {
          HStack {
            Text(provider.name).font(.subheadline.weight(.semibold))
            Spacer()
            Toggle(
              provider.name,
              isOn: Binding(
                get: { enabled.filter { $0.providerID == provider.id }.allSatisfy(visible) },
                set: { value in
                  let intents = enabled.filter { $0.providerID == provider.id }.map {
                    PreferenceIntent.modelVisibility(
                      providerID: $0.providerID, modelID: $0.id, visible: value)
                  }
                  Task {
                    await store.updateModels(
                      intents,
                      success: value
                        ? "Modelos do provedor visíveis" : "Modelos do provedor ocultados")
                  }
                })
            ).labelsHidden()
              .accessibilityIdentifier("provider-visible-\(provider.id)")
              .accessibilityLabel("Mostrar todos de \(provider.name)")
          }
        }
      }
    }
    .disabled(store.acting.contains("models"))
    .scrollContentBackground(.hidden).background(theme.color(.background))
    .foregroundStyle(theme.color(.text)).tint(theme.color(.primary))
  }
  private func visible(_ model: ModelInfo) -> Bool {
    !ConversationProjection.visibleModels([model], preferences: store.preferences?.data.models)
      .isEmpty
  }
}
