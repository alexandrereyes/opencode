import OpenCodeKit
import SwiftUI

/// Port of the web's project explorer (`workspaces/selection/explorer.tsx`) with single selection.
struct AddProjectPicker: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: SessionStore
  var selected: ((Project) async -> Void)?
  @State private var query = ""
  @State private var home = ""
  @State private var started = false
  @State private var hidden = false
  @State private var listings: [String: Listing] = [:]
  @State private var submitting = false
  @State private var failure: String?

  private struct Listing {
    let readable: Bool
    let entries: [ProjectExplorer.Entry]
  }

  var body: some View {
    let current = ProjectExplorer.query(query, home: home)
    let listing = listings[current.browsed]
    let added = Set(
      (store.preferences?.data.projects["local"]?.projects ?? []).map {
        ProjectExplorer.trim($0.worktree)
      })
    let rows = ProjectExplorer.rows(
      entries: listing?.entries ?? [], filter: current.filter, hidden: hidden, added: added,
      home: home)
    let submission = ProjectExplorer.submission(
      query: query, home: home, added: added, readable: listing?.readable ?? false, rows: rows)
    NavigationStack {
      List {
        Section {
          HStack(spacing: 10) {
            Image(systemName: "folder.badge.plus").foregroundStyle(theme.color(.icon))
            TextField("Digite o caminho de uma pasta", text: $query)
              .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
              .foregroundStyle(theme.color(.text)).accessibilityIdentifier("add-project-path")
          }.listRowBackground(theme.color(.surface))
          // The web keeps this action beside the path field; it adds the typed folder, or creates it first.
          let enabled = !submitting && submission != nil && submission?.isAdded != true
          Button {
            if let submission { submit(submission) }
          } label: {
            Label(title(submission), systemImage: submission?.isAdded == true ? "checkmark" : "plus")
              .foregroundStyle(theme.color(enabled ? .primary : .textSecondary))
          }.disabled(!enabled)
            .accessibilityIdentifier("add-project-submit").listRowBackground(theme.color(.surface))
          Toggle("Mostrar ocultas", isOn: $hidden).foregroundStyle(theme.color(.text))
            .listRowBackground(theme.color(.surface))
          if let failure {
            Text(failure).font(.footnote).foregroundStyle(theme.color(.error))
              .listRowBackground(theme.color(.surface))
          }
        }
        Section("Diretórios") {
          if let parent = ProjectExplorer.parent(query, home: home) {
            Button {
              query = parent
            } label: {
              HStack(spacing: 14) {
                Image(systemName: "chevron.left").frame(width: 22).foregroundStyle(theme.color(.icon))
                Text("..").foregroundStyle(theme.color(.text))
                Spacer()
              }.contentShape(Rectangle())
            }.accessibilityLabel("Pasta acima").accessibilityIdentifier("add-project-up")
              .listRowBackground(theme.color(.surface))
          }
          if !started || (listing == nil && !current.browsed.isEmpty) {
            ProgressView("Carregando…").listRowBackground(theme.color(.surface))
          } else if listing?.readable == false {
            message("Não foi possível ler esta pasta")
          } else if rows.isEmpty {
            message("Nenhuma pasta encontrada")
          }
          ForEach(rows) { row in
            HStack(spacing: 14) {
              Button {
                query = current.directory + row.name + "/"
              } label: {
                HStack(spacing: 14) {
                  Image(systemName: "folder").frame(width: 22).foregroundStyle(theme.color(.icon))
                  Text(row.name).foregroundStyle(theme.color(.text)).lineLimit(1)
                  Spacer()
                }.contentShape(Rectangle())
              }.buttonStyle(.borderless).accessibilityIdentifier("add-project-folder-" + row.name)
              if row.added {
                Text("Adicionado").font(.caption).foregroundStyle(theme.color(.textSecondary))
              } else if !row.blocked {
                Button {
                  submit(.existing(row.absolute))
                } label: {
                  Image(systemName: "plus").font(.body.weight(.medium)).frame(width: 32, height: 32)
                }.buttonStyle(.borderless).foregroundStyle(theme.color(.primary))
                  .accessibilityLabel("Adicionar esta pasta")
                  .accessibilityIdentifier("add-project-quick-" + row.name)
                  .disabled(submitting)
              }
            }.listRowBackground(theme.color(.surface))
          }
        }
      }.scrollContentBackground(.hidden).background(theme.color(.background))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Adicionar repositório").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
        }
    }.tint(theme.color(.primary))
      .task { await start() }
      .task(id: started ? current.browsed : nil) { await list(current.browsed) }
      .onChange(of: query) { failure = nil }
  }

  private func message(_ text: String) -> some View {
    Text(text).foregroundStyle(theme.color(.textSecondary)).listRowBackground(theme.color(.surface))
  }

  private func title(_ submission: ProjectExplorer.Submission?) -> String {
    if submitting { return "Adicionando…" }
    switch submission {
    case .added: return "Já adicionado"
    case .create: return "Criar e adicionar"
    default: return "Adicionar projeto"
    }
  }

  private func start() async {
    guard !started else { return }
    let client = store.client
    // Without the custom plugin's home, the web starts at the server's default Location.
    home = (try? await client.homeDirectory()) ?? ""
    let fallback = home.isEmpty ? ((try? await client.defaultDirectory()) ?? "/") : ""
    query = ProjectExplorer.start(home: home, fallback: fallback)
    started = true
  }

  private func list(_ directory: String) async {
    guard !directory.isEmpty, listings[directory]?.readable != true else { return }
    let listing: Listing
    do {
      listing = Listing(readable: true, entries: try await store.client.directories(at: directory))
    } catch {
      if Task.isCancelled { return }
      listing = Listing(readable: false, entries: [])
    }
    listings[directory] = listing
  }

  private func submit(_ submission: ProjectExplorer.Submission) {
    guard !submitting else { return }
    submitting = true
    failure = nil
    Task {
      defer { submitting = false }
      let directory: String
      switch submission {
      case .existing(let path): directory = path
      case .added: return
      case .create(let path):
        guard let created = try? await store.client.createDirectory(path) else {
          failure = "Não foi possível criar a pasta."
          return
        }
        directory = created
      }
      do {
        if let project = try await store.addProject(directory: directory) {
          await selected?(project)
        }
        dismiss()
      } catch {
        failure = "Não foi possível adicionar esta pasta. \(error.localizedDescription)"
      }
    }
  }
}

extension ProjectExplorer.Submission {
  fileprivate var isAdded: Bool {
    if case .added = self { return true }
    return false
  }
}
