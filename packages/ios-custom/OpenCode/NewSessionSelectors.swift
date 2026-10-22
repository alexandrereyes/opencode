import OpenCodeKit
import SwiftUI

struct AddProjectPicker: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: SessionStore
  var selected: ((Project) async -> Void)?
  var body: some View {
    NavigationStack {
      List {
        let selectedIDs = Set(store.selectedProjects.map { $0.project.id })
        ForEach(
          store.projects.filter { !selectedIDs.contains($0.id) && $0.canonical != store.chatRoot }
        ) { project in
          Button {
            Task {
              await store.mutate(.open(directory: project.canonical))
              if store.selectedProjects.contains(where: { $0.project.id == project.id }) {
                await selected?(project)
                dismiss()
              }
            }
          } label: {
            Label(project.displayName, systemImage: "folder.badge.plus").foregroundStyle(
              theme.color(.textStrong))
          }.listRowBackground(theme.color(.surface))
        }
        if store.projects.allSatisfy({
          selectedIDs.contains($0.id) || $0.canonical == store.chatRoot
        }) {
          Text("Todos os repositórios já estão nos filtros.").foregroundStyle(
            theme.color(.textSecondary)
          )
          .listRowBackground(theme.color(.surface))
        }
      }.scrollContentBackground(.hidden).background(theme.color(.background))
        .navigationTitle("Adicionar repositório").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Concluir") { dismiss() } }
        }
    }.tint(theme.color(.primary))
  }
}

struct NewSessionProjectSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: NewSessionStore
  let add: () -> Void
  @State private var search = ""
  var body: some View {
    NavigationStack {
      List {
        SelectorSearch(text: $search, prompt: "Buscar projetos")
        Section {
          ForEach(
            store.projects.filter {
              search.isEmpty || $0.displayName.localizedStandardContains(search)
            }
          ) { project in
            Button {
              Task {
                await store.selectProject(project)
                dismiss()
              }
            } label: {
              HStack(spacing: 14) {
                ProjectAvatar(project: project, size: 38)
                Text(project.displayName).foregroundStyle(theme.color(.text))
                Spacer()
                if store.project?.id == project.id { Image(systemName: "checkmark") }
              }.padding(.vertical, 3)
            }.accessibilityIdentifier("new-project-" + project.displayName)
              .listRowBackground(theme.color(.surface))
          }
        }
        Section {
          Button("Adicionar projeto", systemImage: "plus", action: add).listRowBackground(
            theme.color(.surface))
        }
      }.scrollContentBackground(.hidden).background(theme.color(.background))
        .navigationTitle("Projeto").navigationBarTitleDisplayMode(.inline)
        .listSectionSpacing(12).contentMargins(.top, 12, for: .scrollContent)
    }.presentationDetents([.height(520), .large]).presentationDragIndicator(.visible).tint(
      theme.color(.primary))
  }
}

struct NewSessionDirectorySheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: NewSessionStore
  @State private var search = ""
  var body: some View {
    NavigationStack {
      List {
        if store.worktrees.count >= 10 { SelectorSearch(text: $search, prompt: "Buscar worktrees") }
        if !store.git {
          Text("Este projeto não usa Git. A sessão será criada no diretório principal.")
            .foregroundStyle(theme.color(.textSecondary)).listRowBackground(theme.color(.surface))
        }
        Section("Diretório principal") {
          choice(store.rootBranch ?? "Diretório principal", destination: .root)
        }
        if store.git {
          Section("Worktrees") {
            let matches = store.worktrees.filter {
              search.isEmpty || $0.label.localizedStandardContains(search)
            }
            ForEach(matches) { worktree in
              choice(worktree.label, destination: .worktree(worktree.directory))
            }
            if matches.isEmpty && !search.isEmpty {
              Text("Nenhuma worktree encontrada").foregroundStyle(theme.color(.textSecondary))
                .listRowBackground(theme.color(.surface))
            }
            choice("Nova worktree", destination: .create)
          }
        }
      }.scrollContentBackground(.hidden).background(theme.color(.background))
        .navigationTitle("Diretório").navigationBarTitleDisplayMode(.inline)
        .listSectionSpacing(12).contentMargins(.top, 12, for: .scrollContent)
    }.presentationDetents([
      .height(min(700, max(360, CGFloat(store.worktrees.count) * 54 + 320))), .large,
    ])
    .presentationDragIndicator(.visible).tint(theme.color(.primary))
  }
  private func choice(_ title: String, destination: SessionDestination) -> some View {
    Button {
      store.selectDestination(destination)
      dismiss()
    } label: {
      HStack(spacing: 14) {
        Group {
          if destination == .create { Image(systemName: "plus") } else { GitBranchIcon() }
        }.frame(width: 20).foregroundStyle(theme.color(destination == .create ? .primary : .icon))
        Text(title).foregroundStyle(theme.color(destination == .create ? .primary : .text))
          .lineLimit(1)
        Spacer()
        if store.destination == destination { Image(systemName: "checkmark") }
      }.padding(.vertical, 5)
    }.listRowBackground(theme.color(.surface))
      .accessibilityIdentifier(
        destination == .root
          ? "new-root" : destination == .create ? "new-create" : "new-worktree-" + title)
  }
}

struct NewSessionBaseSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: NewSessionStore
  @State private var search = ""
  @State private var branches: [String] = []
  @State private var loading = true
  @State private var failed = false
  @State private var retry = 0
  var body: some View {
    NavigationStack {
      List {
        SelectorSearch(text: $search, prompt: "Buscar branches", autoFocus: true)
        Section {
          if loading { ProgressView("Buscando branches…").listRowBackground(theme.color(.surface)) }
          if failed {
            Button("Não foi possível carregar · Tentar novamente") { retry += 1 }.listRowBackground(
              theme.color(.surface))
          }
          ForEach(branches, id: \.self) { branch in
            Button {
              store.selectBase(branch)
              dismiss()
            } label: {
              HStack {
                GitBranchIcon().foregroundStyle(theme.color(.icon))
                Text(branch).foregroundStyle(theme.color(.text))
                Spacer()
                if branch == store.baseBranch { Image(systemName: "checkmark") }
              }
            }.listRowBackground(theme.color(.surface)).accessibilityIdentifier("base-" + branch)
          }
          if !loading && !failed && branches.isEmpty {
            Text("Nenhuma branch encontrada").foregroundStyle(theme.color(.textSecondary))
              .listRowBackground(theme.color(.surface))
          }
        }
      }.scrollContentBackground(.hidden).background(theme.color(.background))
        .navigationTitle("Branch base").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(search):\(retry)") {
          loading = true
          failed = false
          do {
            try await Task.sleep(for: .milliseconds(100))
            guard let root = store.project?.canonical else { return }
            let values = try await store.sessions.client.baseBranches(
              directory: root, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
            try Task.checkCancellation()
            branches = NewSessionProjection.branches(
              values, current: store.rootBranch, search: search)
            loading = false
          } catch {
            if !Task.isCancelled {
              failed = true
              loading = false
              branches = []
            }
          }
        }
    }.presentationDetents([.large]).presentationDragIndicator(.visible).tint(
      theme.color(.primary))
  }
}

private struct SelectorSearch: View {
  @Environment(\.appTheme) private var theme
  @Binding var text: String
  let prompt: String
  var autoFocus = false
  @FocusState private var focused: Bool
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textSecondary))
      TextField(prompt, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
        .focused($focused)
        .foregroundStyle(theme.color(.text)).accessibilityIdentifier("selector-search")
    }.padding(.vertical, 7).listRowBackground(theme.color(.surface))
      .onAppear { if autoFocus { focused = true } }
  }
}
