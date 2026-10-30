import OpenCodeKit
import SwiftUI

/// What the editor starts from: an existing snippet to edit, or a new one (empty, a duplicate, a message's text,
/// the `#` query).
struct SnippetEditorRoute: Identifiable {
  let id = UUID()
  var snippet: Snippet
  var editing: Bool
}

/// The snippet editor, full screen from Você ▸ Snippets and in a sheet over a conversation. Every rule of
/// `SnippetRules` shows under its field while typing; Salvar is enabled only while none is broken.
struct SnippetEditorView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.displayScale) private var displayScale
  let catalog: SnippetCatalog
  let projects: [Project]
  let route: SnippetEditorRoute
  @State private var snippet: Snippet
  @State private var alias = ""
  @State private var addingAlias = false
  @State private var saving = false
  /// The server's refusal, shown under its field until that field changes.
  @State private var refused: SnippetIssue?
  @State private var failure: String?
  @State private var deleting = false
  @FocusState private var focus: Field?
  private enum Field: Hashable { case name, description, content, alias }

  init(catalog: SnippetCatalog, projects: [Project], route: SnippetEditorRoute) {
    self.catalog = catalog
    self.projects = projects
    self.route = route
    _snippet = State(initialValue: route.snippet)
  }

  private var issues: [SnippetIssue] { SnippetRules.issues(snippet, in: catalog.items, projects: projects) }
  /// An empty name or content only disables Salvar; the other problems show under their field.
  private var nameIssue: SnippetIssue? {
    if let refused, refused.field == .name { return refused }
    return snippet.name.isEmpty ? nil : issues.first { $0.field == .name }
  }
  private var aliasIssue: SnippetIssue? {
    if let refused, case .alias = refused.field { return refused }
    return issues.first { if case .alias = $0.field { true } else { false } }
  }
  /// The atalho being typed, checked as if it were already added.
  private var candidateIssue: SnippetIssue? {
    let value = alias.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { return nil }
    var next = snippet
    next.aliases.append(value)
    return SnippetRules.issues(next, in: catalog.items, projects: projects).first { $0.field == .alias(value) }
  }
  private var changed: Bool { !route.editing || snippet != route.snippet }
  private var canSave: Bool { issues.isEmpty && refused == nil && changed && !saving }

  var body: some View {
    NavigationStack {
      List {
        Section {
          trigger
        } header: { Text("Gatilho") } footer: { triggerStatus }
          .listRowBackground(theme.color(.surface))
        Section("Descrição") {
          TextField("Opcional", text: $snippet.description, axis: .vertical).lineLimit(1...3)
            .focused($focus, equals: .description)
            .accessibilityLabel("Descrição").accessibilityIdentifier("snippet-description")
        }.listRowBackground(theme.color(.surface))
        Section {
          contentEditor
        } header: { Text("Conteúdo") } footer: { Text("Texto puro: @, & e $ não viram menções.") }
          .listRowBackground(theme.color(.surface))
        if !snippet.name.isEmpty && nameIssue == nil {
          Section("Prévia") { preview }.listRowBackground(theme.color(.surface))
        }
        Section {
          aliases
        } header: { Text("Atalhos") } footer: {
          if let issue = candidateIssue ?? aliasIssue {
            problem(issue.message).accessibilityIdentifier("snippet-alias-problem")
          } else {
            Text("Outras palavras que encontram este snippet depois do #.")
          }
        }.listRowBackground(theme.color(.surface))
        Section("Escopo") {
          NavigationLink {
            SnippetScopePicker(projects: projects, selection: $snippet.project)
          } label: {
            HStack(spacing: 10) {
              Text(snippet.project == nil ? "Global" : "Projeto")
              Spacer(minLength: 8)
              SnippetScopeLabel(projects: projects, project: snippet.project)
                .foregroundStyle(theme.color(.textSecondary))
            }
          }
          .accessibilityLabel("Escopo")
          .accessibilityValue(scopeName)
          .accessibilityIdentifier("snippet-scope")
        }.listRowBackground(theme.color(.surface))
        if route.editing {
          Section {
            Button("Apagar snippet", role: .destructive) { deleting = true }
              .frame(maxWidth: .infinity).accessibilityIdentifier("snippet-delete")
          }.listRowBackground(theme.color(.error).opacity(0.12))
        }
      }
      .settingsList(theme, voice: false)
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle(route.editing ? "Editar snippet" : "Novo snippet")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancelar") { dismiss() }.accessibilityIdentifier("snippet-cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Salvar") { Task { await save() } }.disabled(!canSave).accessibilityIdentifier("snippet-save")
        }
      }
      .confirmationDialog("Apagar #\(route.snippet.name)?", isPresented: $deleting, titleVisibility: .visible) {
        Button("Apagar snippet", role: .destructive) { Task { await remove() } }
        Button("Cancelar", role: .cancel) {}
      } message: { Text("Ele deixa de aparecer no # do iPhone e do Mac. Mensagens já enviadas não mudam.") }
      .alert("Não foi possível concluir", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        Button("OK") { failure = nil }
      } message: { Text(failure ?? "") }
    }
    .tint(theme.color(.primary))
    // A swipe down would lose typed work; Cancelar stays explicit.
    .interactiveDismissDisabled(changed && snippet != Snippet(id: snippet.id, project: snippet.project))
    // A new snippet starts at its name, once the sheet or cover has finished presenting.
    .background(ComposerCoverAppearance { if !route.editing { focus = .name } }.frame(width: 0, height: 0))
    .onChange(of: snippet) { refused = nil }
    // The rules compare against the whole catalog; a sheet opened from a conversation may be the first to read it.
    .task { await catalog.loadIfNeeded() }
  }

  private var scopeName: String {
    guard let project = snippet.project else { return "Global" }
    return projects.first { $0.id == project }?.displayName ?? "Projeto removido"
  }

  private var trigger: some View {
    HStack(spacing: 10) {
      Text("#").appFont(.body, weight: .semibold).foregroundStyle(theme.color(.composerSnippet))
        .frame(width: 32, height: 32)
        .background(theme.color(.surfaceRaised), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
      TextField("nome", text: $snippet.name)
        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.next)
        .focused($focus, equals: .name)
        .onSubmit { focus = .content }
        .accessibilityLabel("Gatilho")
        .accessibilityHint(nameIssue?.message ?? "Nome que você digita depois do #")
        .accessibilityIdentifier("snippet-name")
    }
    .padding(.horizontal, 6).padding(.vertical, 4)
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(theme.color(nameIssue == nil ? .controlBorder : .error), lineWidth: nameIssue == nil ? 1 / displayScale : 1.5)
    }
    .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
  }

  @ViewBuilder private var triggerStatus: some View {
    if let nameIssue {
      problem(nameIssue.message).accessibilityIdentifier("snippet-name-problem")
    } else if !snippet.name.isEmpty {
      Label {
        Text(availability)
      } icon: {
        Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
      }
      .foregroundStyle(theme.color(.success)).accessibilityIdentifier("snippet-name-available")
    }
  }

  /// "Disponível em opencode2 · substitui o global", "Disponível nos globais".
  private var availability: String {
    let place = "Disponível " + SnippetRules.place(snippet.project, projects: projects)
    return SnippetRules.overridden(snippet, in: catalog.items) == nil ? place : place + " · substitui o global"
  }

  private func problem(_ text: String) -> some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
    }.foregroundStyle(theme.color(.error))
  }

  private var contentEditor: some View {
    TextEditor(text: $snippet.content)
      .focused($focus, equals: .content)
      // It grows with the text instead of scrolling inside the form, so a swipe over it scrolls the form.
      .scrollDisabled(true)
      .frame(minHeight: 120)
      .scrollContentBackground(.hidden)
      .appFont(.body)
      .overlay(alignment: .topLeading) {
        if snippet.content.isEmpty {
          Text("Texto que entra no lugar do #").appFont(.body).foregroundStyle(theme.color(.textWeak))
            .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      .accessibilityLabel("Conteúdo")
      .accessibilityIdentifier("snippet-content")
  }

  private var preview: some View {
    HStack(spacing: 8) {
      SnippetToken(name: snippet.name)
      Image(systemName: "arrow.right").foregroundStyle(theme.color(.textSecondary)).accessibilityHidden(true)
      Text("envia o texto acima").foregroundStyle(theme.color(.textSecondary))
    }
    .appFont(.secondary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("No composer, #\(snippet.name) envia o texto acima")
  }

  private var aliases: some View {
    VStack(alignment: .leading, spacing: 10) {
      MCPFlowLayout(spacing: 8, centered: false) {
        ForEach(snippet.aliases, id: \.self) { value in
          HStack(spacing: 2) {
            Text(value).appFont(.secondary)
            Button("Remover o atalho \(value)", systemImage: "xmark") {
              snippet.aliases.removeAll { $0 == value }
            }.labelStyle(.iconOnly).appSymbol(.inline).buttonStyle(.plain)
              .frame(minWidth: 28, minHeight: 32).contentShape(Rectangle())
              .accessibilityIdentifier("snippet-alias-remove-" + value)
          }
          .foregroundStyle(theme.color(aliasIssue?.field == .alias(value) ? .error : .text))
          .padding(.leading, 12).padding(.trailing, 4)
          .overlay {
            Capsule().strokeBorder(theme.color(aliasIssue?.field == .alias(value) ? .error : .controlBorder),
              lineWidth: 1 / displayScale)
          }
        }
        if !addingAlias {
          Button {
            addingAlias = true
            focus = .alias
          } label: {
            Image(systemName: "plus").appSymbol(.inline).frame(width: 32, height: 32)
              .overlay { Circle().strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale) }
              .contentShape(Circle())
          }.buttonStyle(.plain).accessibilityLabel("Adicionar atalho").accessibilityIdentifier("snippet-alias-add")
        }
      }
      if addingAlias {
        HStack {
          TextField("novo atalho", text: $alias)
            .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
            .focused($focus, equals: .alias)
            .onSubmit(addAlias)
            .accessibilityLabel("Novo atalho").accessibilityIdentifier("snippet-alias-input")
          Button("Adicionar", action: addAlias)
            .disabled(alias.trimmingCharacters(in: .whitespaces).isEmpty || candidateIssue != nil)
            .buttonStyle(.borderless).accessibilityIdentifier("snippet-alias-confirm")
        }
      }
    }.padding(.vertical, 4)
  }

  private func addAlias() {
    let value = alias.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty, candidateIssue == nil else { return }
    snippet.aliases.append(value)
    alias = ""
    addingAlias = false
    focus = nil
  }

  private func save() async {
    saving = true
    defer { saving = false }
    var value = snippet
    value.description = value.description.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try await catalog.save(value, projects: projects)
      Haptics.play(.light)
      dismiss()
    } catch let error as SnippetSaveError {
      refused = error.issue
    } catch {
      failure = "Não foi possível salvar o snippet. \(error.localizedDescription)"
    }
  }

  private func remove() async {
    do {
      try await catalog.remove(route.snippet.id)
      Haptics.play(.light)
      dismiss()
    } catch {
      failure = "Não foi possível apagar o snippet. \(error.localizedDescription)"
    }
  }
}

/// `#name` drawn like the composer's snippet token.
struct SnippetToken: View {
  @Environment(\.appTheme) private var theme
  let name: String
  var body: some View {
    Text("#" + name).appFont(.secondary, weight: .semibold).lineLimit(1)
      .foregroundStyle(theme.color(.composerSnippet))
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background(theme.color(.composerSnippet).opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
  }
}

/// Global, a project (its avatar and name) or a removed project.
struct SnippetScopeLabel: View {
  let projects: [Project]
  let project: String?
  var body: some View {
    if let project {
      if let match = projects.first(where: { $0.id == project }) {
        HStack(spacing: 8) {
          ProjectAvatar(project: match, size: 24, style: .micro)
          Text(match.displayName).lineLimit(1)
        }
      } else {
        Text("Projeto removido")
      }
    } else {
      Label("Todas as conversas", systemImage: "globe")
    }
  }
}

/// Global or one project, with a checkmark on the current choice.
struct SnippetScopePicker: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let projects: [Project]
  @Binding var selection: String?
  var body: some View {
    List {
      Section {
        row(nil, name: "Global") {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Global")
              Text("Em todas as conversas").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
            }
          } icon: { Image(systemName: "globe") }
        }
      }.listRowBackground(theme.color(.surface))
      Section("Projetos") {
        ForEach(projects.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) { project in
          row(project.id, name: project.displayName) {
            HStack(spacing: 10) {
              ProjectAvatar(project: project, size: 28, style: .caption)
              Text(project.displayName)
            }
          }
        }
        if let selection, !projects.contains(where: { $0.id == selection }) {
          row(selection, name: "Projeto removido") { Text("Projeto removido") }
        }
      }.listRowBackground(theme.color(.surface))
    }
    .settingsList(theme, voice: false)
    .navigationTitle("Escopo").navigationBarTitleDisplayMode(.inline)
  }
  private func row(_ value: String?, name: String, @ViewBuilder label: () -> some View) -> some View {
    Button {
      selection = value
      Haptics.play(.selection)
      dismiss()
    } label: {
      HStack {
        label().foregroundStyle(theme.color(.textStrong))
        Spacer()
        if selection == value { Image(systemName: "checkmark").foregroundStyle(theme.color(.primary)) }
      }.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(name)
    .accessibilityAddTraits(selection == value ? .isSelected : [])
    .accessibilityIdentifier("snippet-scope-" + name)
  }
}
