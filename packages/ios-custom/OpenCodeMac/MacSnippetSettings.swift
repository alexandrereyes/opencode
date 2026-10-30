import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// Ajustes ▸ Snippets (rev. 2026-10-30, option A of `.agent-artifacts/snippets-cadastro/mac/mac-opcao-a.png`): the
/// list grouped by scope on the left (search, Todos / Globais / Projetos), the editor on the right. The `#` panel
/// (Novo snippet… ⌘N, Gerenciar snippets…), a selection in the composer and a sent message's right-click menu
/// (Salvar como snippet…) open it through `MacSnippets`. Rules and contract: `plugin-app-custom/docs/snippets.md`.
struct MacSnippetSettings: View {
  @Environment(\.appTheme) private var theme
  let runtime: MacRuntime

  var body: some View {
    Group {
      if let store = runtime.store {
        MacSnippetManager(board: runtime.snippetBoard, catalog: store.snippets)
      } else {
        Text("Conecte a um servidor para gerenciar os snippets.").foregroundStyle(theme.color(.textSecondary))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(theme.color(.background))
  }
}

/// Opens Ajustes ▸ Snippets from the conversation.
@MainActor enum MacSnippets {
  static let tab = "snippets"
  /// The scene's action, from the main window: transcript rows are hosted outside the scene and have none.
  static var opener: OpenSettingsAction?

  /// "Gerenciar snippets…": the list on the conversation's project.
  static func manage(project: String?) {
    MacRuntime.shared.snippetBoard.manage(project: project)
    show()
  }

  /// "Novo snippet…" and "Salvar como snippet…": the editor with `snippet` (not saved yet).
  static func new(_ snippet: Snippet) {
    MacRuntime.shared.snippetBoard.startNew(snippet)
    show()
  }

  /// A new snippet with `content` in the conversation's project, named from its first words.
  static func draft(content: String, store: ConversationStore) -> Snippet {
    SnippetLibrary.draft(content: content, project: project(of: store),
      in: MacRuntime.shared.store?.snippets.items ?? [])
  }

  /// The conversation's Core project; sessions outside one (chats) create global snippets.
  static func project(of store: ConversationStore) -> String? {
    let id = store.composerProjectID ?? store.session?.projectID
    return id == "global" ? nil : id
  }

  private static func show() {
    UserDefaults.standard.set(tab, forKey: "OpenCodeMacSettingsTab")
    opener?()
  }
}

/// The tab's state, kept by `MacRuntime` so the conversation can open it on a snippet and the offline checks drive
/// the same flow as the window.
@MainActor @Observable final class MacSnippetBoard {
  enum Pending: Equatable {
    case select(String)
    case new(Snippet)
  }

  var query = ""
  var filter: SnippetFilter = .all
  /// The stored snippet open in the editor; nil while a new one is edited or nothing is open.
  private(set) var selectedID: String?
  /// The editor's content; nil shows no editor.
  var draft: Snippet?
  /// What Reverter goes back to: the stored snippet, or the new one as it was opened.
  private(set) var baseline: Snippet?
  /// Empty name or content only show once touched or after Salvar was tried.
  var touched: Set<SnippetIssue.Field> = []
  private(set) var attempted = false
  private(set) var saving = false
  /// The plugin refused the last save.
  private(set) var refusal: SnippetIssue?
  private(set) var error: String?
  /// Apagar asks first.
  var deleting: Snippet?
  /// Leaving unsaved changes asks first.
  var pending: Pending?
  /// The project "Gerenciar snippets…" came from: its section is marked and new snippets start in it.
  private(set) var focusProject: String?
  /// Bumped to scroll the list to a section or row.
  private(set) var scrollTarget: (id: String, revision: Int)?

  private var catalog: SnippetCatalog? { MacRuntime.shared.store?.snippets }
  var projects: [Project] { MacRuntime.shared.store?.projects ?? [] }
  var items: [Snippet] { catalog?.items ?? [] }
  var isNew: Bool { draft != nil && selectedID == nil }
  var dirty: Bool { draft != nil && draft != baseline }
  var sections: [SnippetSection] { SnippetLibrary.sections(items, projects: projects, filter: filter, query: query) }

  /// Every problem of the draft; empty fields only once touched or after Salvar.
  var issues: [SnippetIssue] {
    guard let draft else { return [] }
    let all = SnippetRules.issues(draft, in: items, projects: projects).filter { issue in
      guard issue.field == .name ? draft.name.isEmpty : issue.field == .content else { return true }
      return attempted || touched.contains(issue.field)
    }
    guard let refusal, !all.contains(where: { $0.field == refusal.field }) else { return all }
    return all + [refusal]
  }
  var canSave: Bool {
    guard let draft, dirty || isNew, !saving else { return false }
    return SnippetRules.issues(draft, in: items, projects: projects).isEmpty
  }

  func select(_ id: String) {
    guard id != selectedID else { return }
    if dirty { return pending = .select(id) }
    open(items.first { $0.id == id })
  }

  func startNew(_ snippet: Snippet? = nil) {
    let snippet = snippet ?? Snippet(project: focusProject)
    if dirty { return pending = .new(snippet) }
    selectedID = nil
    draft = snippet
    baseline = snippet
    reset()
  }

  func manage(project: String?) {
    focusProject = project
    filter = .all
    query = ""
    if let project { scroll(to: "project:" + project) }
    // Opens the project's first snippet unless something is being edited.
    if !dirty, draft == nil || selectedID != nil,
      let first = sections.first(where: { $0.scope.project == project })?.items.first {
      open(first)
    }
  }

  /// `next` is read when the alert opens: SwiftUI clears `pending` before it runs the button's action.
  func discardPending(_ next: Pending?) {
    pending = nil
    baseline = draft
    switch next {
    case .select(let id): select(id)
    case .new(let snippet): startNew(snippet)
    case nil: break
    }
  }

  func revert() {
    guard isNew || dirty else { return }
    if isNew && !dirty {
      draft = nil
      baseline = nil
    } else {
      draft = baseline
    }
    reset()
  }

  func save() async {
    attempted = true
    guard let catalog, let draft, canSave else { return }
    saving = true
    defer { saving = false }
    do {
      let saved = try await catalog.save(draft, projects: projects)
      open(saved)
      scroll(to: saved.id)
    } catch let refused as SnippetSaveError {
      refusal = refused.issue
    } catch {
      self.error = "Não foi possível salvar: \(error.localizedDescription)"
    }
  }

  /// A copy with a free name in the same scope, saved at once and opened.
  func duplicate() async {
    guard let catalog, let source = selectedID.flatMap({ id in items.first { $0.id == id } }), !dirty else { return }
    do {
      let saved = try await catalog.save(SnippetLibrary.duplicate(source, in: items), projects: projects)
      open(saved)
      scroll(to: saved.id)
    } catch {
      self.error = "Não foi possível duplicar: \(error.localizedDescription)"
    }
  }

  func askDelete() {
    deleting = selectedID.flatMap { id in items.first { $0.id == id } }
  }

  /// `target` is read when the alert opens: SwiftUI clears `deleting` before it runs the button's action.
  func confirmDelete(_ target: Snippet?) async {
    guard let catalog, let target else { return }
    deleting = nil
    do {
      try await catalog.remove(target.id)
      if selectedID == target.id {
        selectedID = nil
        draft = nil
        baseline = nil
        reset()
      }
    } catch {
      self.error = "Não foi possível apagar: \(error.localizedDescription)"
    }
  }

  /// Another server: nothing of the previous one stays open.
  func clear() {
    selectedID = nil
    draft = nil
    baseline = nil
    focusProject = nil
    deleting = nil
    pending = nil
    reset()
  }

  private func open(_ snippet: Snippet?) {
    selectedID = snippet?.id
    draft = snippet
    baseline = snippet
    reset()
  }

  private func reset() {
    touched = []
    attempted = false
    refusal = nil
    error = nil
  }

  private func scroll(to id: String) { scrollTarget = (id, (scrollTarget?.revision ?? 0) + 1) }

  /// A field changed (nil: one without its own message, like the scope): a refusal for it no longer applies.
  func edited(_ field: SnippetIssue.Field?) {
    if let field { touched.insert(field) }
    if field == nil || refusal?.field == field { refusal = nil }
    error = nil
  }
}

private extension SnippetSection.Scope {
  var project: String? {
    switch self {
    case .global: nil
    case .project(let project): project.id
    case .removed(let id): id
    }
  }
}

// MARK: - Manager

private struct MacSnippetManager: View {
  @Environment(\.appTheme) private var theme
  @Bindable var board: MacSnippetBoard
  let catalog: SnippetCatalog

  var body: some View {
    HStack(spacing: 0) {
      MacSnippetList(board: board, catalog: catalog).frame(width: 320)
      Rectangle().fill(theme.color(.border)).frame(width: 1)
      Group {
        if board.draft != nil {
          MacSnippetEditor(board: board)
        } else if catalog.loaded && catalog.items.isEmpty {
          MacSnippetEmpty { board.startNew() }
        } else {
          Text(catalog.failed && !catalog.loaded ? "Não foi possível carregar os snippets."
            : "Escolha um snippet à esquerda ou crie um novo.")
            .appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task { await catalog.loadIfNeeded() }
    .alert(
      "Apagar #\(board.deleting?.name ?? "")?",
      isPresented: Binding(get: { board.deleting != nil }, set: { if !$0 { board.deleting = nil } })
    ) {
      let target = board.deleting
      Button("Apagar", role: .destructive) { Task { await board.confirmDelete(target) } }
      Button("Cancelar", role: .cancel) {}
    } message: {
      Text("Ele some do # em todos os apps e dispositivos. Mensagens já enviadas não mudam. Não dá para desfazer.")
    }
    .alert(
      "Descartar as alterações?",
      isPresented: Binding(get: { board.pending != nil }, set: { if !$0 { board.pending = nil } })
    ) {
      let next = board.pending
      Button("Descartar", role: .destructive) { board.discardPending(next) }
      Button("Continuar editando", role: .cancel) {}
    } message: {
      Text("As alterações em #\(board.baseline?.name.isEmpty == false ? board.baseline!.name : "novo snippet") não foram salvas.")
    }
  }
}

private struct MacSnippetList: View {
  @Environment(\.appTheme) private var theme
  @Bindable var board: MacSnippetBoard
  let catalog: SnippetCatalog

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textSecondary))
        TextField("Buscar snippets", text: $board.query).textFieldStyle(.plain)
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border), lineWidth: 0.7) }
      Picker("Escopo", selection: $board.filter) {
        ForEach(SnippetFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented).labelsHidden()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(board.sections) { section in
              header(section).id(section.id)
              ForEach(section.items) { snippet in row(snippet).id(snippet.id) }
            }
            if board.sections.isEmpty, catalog.loaded, !catalog.items.isEmpty {
              Text("Nenhum snippet encontrado.").appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
                .padding(.top, 20).frame(maxWidth: .infinity)
            }
          }
          .padding(.bottom, 8)
        }
        .onChange(of: board.scrollTarget?.revision) { _, _ in
          guard let id = board.scrollTarget?.id else { return }
          withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
      }
      HStack(spacing: 4) {
        Button { board.startNew() } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
          .help("Novo snippet").accessibilityIdentifier("snippets-new")
        Menu {
          Button("Duplicar") { Task { await board.duplicate() } }.disabled(board.selectedID == nil || board.dirty)
          Button("Apagar…", role: .destructive) { board.askDelete() }.disabled(board.selectedID == nil)
        } label: { Image(systemName: "ellipsis") }
          .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).frame(width: 30)
        Spacer()
        Text(count).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      }
      .buttonStyle(.borderless)
    }
    .padding(14)
  }

  private var count: String {
    let total = catalog.items.count
    return total == 1 ? "1 snippet" : "\(total) snippets"
  }

  private func header(_ section: SnippetSection) -> some View {
    HStack(spacing: 7) {
      switch section.scope {
      case .global: Image(systemName: "globe").foregroundStyle(theme.color(.textSecondary))
      case .project(let project): ProjectAvatar(project: project, size: 18, style: .micro)
      case .removed: Image(systemName: "questionmark.folder").foregroundStyle(theme.color(.warning))
      }
      Text(section.title.uppercased()).appFont(.caption, weight: .semibold).kerning(0.6)
        .foregroundStyle(theme.color(focused(section) ? .textStrong : .textSecondary))
      Text("\(section.items.count)").appFont(.caption).foregroundStyle(theme.color(.textWeak))
      Spacer()
    }
    .padding(.top, 12).padding(.bottom, 4).padding(.horizontal, 6)
  }

  private func focused(_ section: SnippetSection) -> Bool {
    if case .project(let project) = section.scope { return project.id == board.focusProject }
    return false
  }

  private func row(_ snippet: Snippet) -> some View {
    let selected = snippet.id == board.selectedID
    return Button { board.select(snippet.id) } label: {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text("#" + snippet.name).appFont(.secondary, weight: .semibold).foregroundStyle(theme.color(.composerSnippet))
            .lineLimit(1)
          Spacer(minLength: 4)
          if SnippetRules.overridden(snippet, in: board.items) != nil {
            Text("substitui o global").appFont(.micro).foregroundStyle(theme.color(.textSecondary))
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(theme.color(.surfaceRaised), in: Capsule())
          } else if !snippet.aliases.isEmpty {
            Text(snippet.aliases.joined(separator: ", ")).appFont(.caption).foregroundStyle(theme.color(.textWeak))
              .lineLimit(1)
          }
        }
        if !snippet.description.isEmpty {
          Text(snippet.description).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selected ? theme.color(.surfaceRaised) : .clear, in: RoundedRectangle(cornerRadius: 7))
      .overlay(alignment: .leading) {
        if selected { Capsule().fill(theme.color(.primary)).frame(width: 3).padding(.vertical, 6) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("snippet-row-" + snippet.id)
  }
}

// MARK: - Editor

private struct MacSnippetEditor: View {
  @Environment(\.appTheme) private var theme
  @Bindable var board: MacSnippetBoard
  @State private var alias = ""

  private var draft: Snippet { board.draft ?? Snippet() }
  private func issue(_ field: SnippetIssue.Field) -> SnippetIssue? { board.issues.first { $0.field == field } }
  private func binding<Value>(_ path: WritableKeyPath<Snippet, Value>, _ field: SnippetIssue.Field?) -> Binding<Value> {
    Binding(get: { draft[keyPath: path] }, set: { value in
      board.draft?[keyPath: path] = value
      board.edited(field)
    })
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
          GridRow {
            label("Nome")
            VStack(alignment: .leading, spacing: 5) {
              HStack(spacing: 6) {
                Text("#").foregroundStyle(theme.color(.textSecondary))
                TextField("nome", text: binding(\.name, .name)).textFieldStyle(.plain)
                  .accessibilityIdentifier("snippet-name")
              }
              .field(theme, invalid: issue(.name) != nil)
              nameHint
            }
          }
          GridRow {
            label("Descrição")
            TextField("Opcional", text: binding(\.description, nil)).textFieldStyle(.plain).field(theme)
          }
          GridRow {
            label("Atalhos")
            aliases
          }
          GridRow {
            label("Escopo")
            scope
          }
          GridRow {
            label("Conteúdo")
            VStack(alignment: .leading, spacing: 5) {
              TextEditor(text: binding(\.content, .content))
                .font(.system(size: 12.5, design: .monospaced)).scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(6)
                .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                  RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.color(issue(.content) != nil ? .error : .border), lineWidth: issue(.content) != nil ? 1 : 0.7)
                }
              if let issue = issue(.content) {
                message(issue.message, role: .error)
              } else {
                message("Texto puro: @, & e $ no conteúdo não viram menções; # insere o texto todo.", role: .textSecondary)
              }
            }
          }
          GridRow {
            label("Prévia")
            preview
          }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
      }
      Rectangle().fill(theme.color(.border)).frame(height: 1)
      footer.padding(.horizontal, 20).padding(.vertical, 12)
    }
  }

  private func label(_ text: String) -> some View {
    Text(text).appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
      .frame(width: 78, alignment: .leading).padding(.top, 6)
  }

  private func message(_ text: String, role: ThemeRole) -> some View {
    Text(text).appFont(.caption).foregroundStyle(theme.color(role)).fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var nameHint: some View {
    if let issue = issue(.name) {
      message(issue.message, role: .error)
    } else if !draft.name.isEmpty {
      let place = SnippetRules.place(draft.project, projects: board.projects)
      let replaces = SnippetRules.overridden(draft, in: board.items).map { " · substitui #\($0.name) global" } ?? ""
      Label("Disponível \(place)\(replaces)", systemImage: "checkmark.circle.fill").appFont(.caption)
        .foregroundStyle(theme.color(.success))
    }
  }

  private var aliases: some View {
    VStack(alignment: .leading, spacing: 5) {
      MCPFlowLayout(spacing: 6, centered: false) {
        ForEach(draft.aliases, id: \.self) { value in
          HStack(spacing: 4) {
            Text(value)
            Button {
              board.draft?.aliases.removeAll { $0 == value }
              board.edited(.alias(value))
            } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
              .buttonStyle(.plain).help("Remover atalho")
          }
          .appFont(.caption).padding(.horizontal, 9).padding(.vertical, 4)
          .background(theme.color(.surfaceRaised), in: Capsule())
          .overlay {
            Capsule().strokeBorder(theme.color(issue(.alias(value)) != nil ? .error : .border), lineWidth: 0.7)
          }
        }
        TextField("+ atalho", text: $alias).textFieldStyle(.plain).appFont(.caption).frame(width: 110)
          .padding(.horizontal, 9).padding(.vertical, 4)
          .overlay { Capsule().strokeBorder(theme.color(.border), style: StrokeStyle(lineWidth: 0.7, dash: [3])) }
          .onSubmit(addAlias)
          .accessibilityIdentifier("snippet-alias")
      }
      ForEach(board.issues.filter { if case .alias = $0.field { true } else { false } }, id: \.message) {
        message($0.message, role: .error)
      }
    }
  }

  /// Return adds what was typed; commas and spaces separate several.
  private func addAlias() {
    let values = alias.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    alias = ""
    guard !values.isEmpty else { return }
    board.draft?.aliases.append(contentsOf: values)
    values.forEach { board.edited(.alias($0)) }
  }

  private var scope: some View {
    let projects = board.projects.filter { $0.id != "global" }
    let removed = draft.project.map { id in !projects.contains { $0.id == id } } ?? false
    return Menu {
      Button { setScope(nil) } label: { Label("Global", systemImage: "globe") }
      if !projects.isEmpty { Divider() }
      ForEach(projects) { project in Button(project.displayName) { setScope(project.id) } }
      if removed, let id = draft.project { Divider(); Button("Projeto removido") { setScope(id) } }
    } label: {
      HStack(spacing: 7) {
        if let id = draft.project, let project = projects.first(where: { $0.id == id }) {
          ProjectAvatar(project: project, size: 18, style: .micro)
          Text(project.displayName)
        } else if draft.project != nil {
          Image(systemName: "questionmark.folder")
          Text("Projeto removido")
        } else {
          Image(systemName: "globe")
          Text("Global")
        }
      }
    }
    .menuStyle(.button).buttonStyle(.plain).fixedSize()
    .padding(.horizontal, 9).padding(.vertical, 5)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border), lineWidth: 0.7) }
    .accessibilityIdentifier("snippet-scope")
  }

  private func setScope(_ project: String?) {
    board.draft?.project = project
    board.edited(nil)
  }

  private var preview: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text("Antes do PR,").foregroundStyle(theme.color(.text))
        Text("#" + (draft.name.isEmpty ? "nome" : draft.name)).foregroundStyle(theme.color(.composerSnippet))
          .padding(.horizontal, 4).background(theme.color(.composerSnippet).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        Text("→ envia").foregroundStyle(theme.color(.textSecondary))
      }
      .appFont(.secondary)
      Text(draft.content.isEmpty ? "O texto do conteúdo." : ComposerDocument.normalize(draft.content))
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.color(.textSecondary))
        .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(12)
    .background(theme.color(.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border), lineWidth: 0.7) }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button("Duplicar") { Task { await board.duplicate() } }
        .disabled(board.isNew || board.dirty).accessibilityIdentifier("snippet-duplicate")
      Button("Apagar…") { board.askDelete() }
        .buttonStyle(.plain).foregroundStyle(theme.color(board.isNew ? .textWeak : .error)).disabled(board.isNew)
        .accessibilityIdentifier("snippet-delete")
      if let error = board.error {
        Text(error).appFont(.caption).foregroundStyle(theme.color(.error)).lineLimit(2)
      }
      Spacer()
      Button(board.isNew && !board.dirty ? "Cancelar" : "Reverter") { board.revert() }
        .disabled(!board.isNew && !board.dirty).accessibilityIdentifier("snippet-revert")
      Button { Task { await board.save() } } label: {
        Text(board.saving ? "Salvando…" : "Salvar").frame(minWidth: 64)
      }
      .buttonStyle(.borderedProminent).tint(theme.color(.primary))
      .keyboardShortcut("s", modifiers: .command)
      .disabled(!board.canSave).accessibilityIdentifier("snippet-save")
    }
  }
}

private extension View {
  func field(_ theme: AppTheme, invalid: Bool = false) -> some View {
    padding(.horizontal, 10).padding(.vertical, 7)
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(invalid ? .error : .border), lineWidth: invalid ? 1 : 0.7)
      }
  }
}

private struct MacSnippetEmpty: View {
  @Environment(\.appTheme) private var theme
  let create: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Text("#").font(.system(size: 40, weight: .semibold)).foregroundStyle(theme.color(.composerSnippet))
        .frame(width: 72, height: 72)
        .background(theme.color(.composerSnippet).opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
      Text("Nenhum snippet ainda").appFont(.title, weight: .semibold).foregroundStyle(theme.color(.textStrong))
      Text("Snippets são textos que você reutiliza. Digite # no composer para inserir; no envio, o token vira o texto.")
        .appFont(.secondary).foregroundStyle(theme.color(.textSecondary)).multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      Button("Novo snippet", action: create).buttonStyle(.borderedProminent).tint(theme.color(.primary))
        .accessibilityIdentifier("snippets-empty-new")
      Text("Ou selecione um texto no composer e escolha Salvar como snippet…").appFont(.caption)
        .foregroundStyle(theme.color(.textSecondary))
    }
    .padding(30)
  }
}
