import OpenCodeKit
import SwiftUI

struct FileExplorerRoute: Hashable {
  let path: String
}

/// The session's server directory, opened from "Diretório de trabalho". Ports the web's session file tree
/// (`app-custom/src/session/files`) as native folder navigation; files open in the shared `FileViewer`.
struct FileExplorerView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.conversationImages) private var context
  @Environment(\.openFile) private var openFile
  let path: String
  let changes: [String: FileExplorer.Change]
  @State private var entries: [DirectoryEntry]?
  @State private var failure: String?
  @State private var query = ""
  @State private var results: [String]?
  @State private var searchFailed = false

  var body: some View {
    let search = query.trimmingCharacters(in: .whitespaces)
    List {
      if search.isEmpty { listing } else { found }
    }
    .scrollContentBackground(.hidden).background(theme.color(.background))
    .foregroundStyle(theme.color(.textStrong))
    .navigationTitle(path == "/" ? "/" : URL(fileURLWithPath: path).lastPathComponent)
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar arquivos")
    .autocorrectionDisabled().textInputAutocapitalization(.never)
    .task { if entries == nil { await load() } }
    .task(id: search) { await find(search) }
    .refreshable { await load() }
  }

  private var listing: some View {
    Section {
      if let parent = FileExplorer.parent(path) {
        NavigationLink(value: FileExplorerRoute(path: parent)) {
          row("../", icon: "arrow.turn.left.up", role: .textSecondary)
        }
        .accessibilityLabel("Pasta acima").accessibilityIdentifier("file-explorer-up")
      }
      if let failure {
        VStack(alignment: .leading, spacing: 8) {
          Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(theme.color(.error))
          Button("Tentar novamente") { Task { await load() } }.buttonStyle(.borderless).fontWeight(.medium)
        }
        .font(.footnote).accessibilityIdentifier("file-explorer-error")
      } else if let entries {
        if entries.isEmpty { message("Pasta vazia") }
        ForEach(entries) { entry in
          if entry.kind == .directory {
            NavigationLink(value: FileExplorerRoute(path: entry.absolute)) {
              row(entry.name, icon: "folder", role: .icon)
            }.accessibilityIdentifier("file-explorer-folder-" + entry.name)
          } else {
            file(entry.absolute, title: entry.name)
          }
        }
      } else {
        ProgressView("Carregando…")
      }
    } header: {
      Text(path).font(.caption.monospaced()).textCase(nil).foregroundStyle(theme.color(.textSecondary))
        .accessibilityIdentifier("file-explorer-path")
    }
    .listRowBackground(theme.color(.toolSurface))
  }

  /// Like the web, search ranks files across the whole session directory rather than the open folder.
  private var found: some View {
    Section {
      if searchFailed {
        message("Não foi possível buscar arquivos.")
      } else if let results {
        if results.isEmpty { message("Nenhum arquivo encontrado") }
        ForEach(results, id: \.self) { file($0, title: relative($0)) }
      } else {
        ProgressView("Buscando…")
      }
    } header: {
      Text(context?.directory ?? "").font(.caption.monospaced()).textCase(nil)
        .foregroundStyle(theme.color(.textSecondary))
    }
    .listRowBackground(theme.color(.toolSurface))
  }

  private func file(_ absolute: String, title: String) -> some View {
    Button { openFile?.open(absolute) } label: {
      HStack {
        row(title, icon: "doc", role: .icon)
        if let change = changes[absolute] {
          Text(change.label).font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(theme.color(role(change)))
            .accessibilityLabel(label(change))
        }
      }.contentShape(Rectangle())
    }
    .accessibilityIdentifier("file-explorer-file-" + URL(fileURLWithPath: absolute).lastPathComponent)
  }

  private func row(_ title: String, icon: String, role: ThemeRole) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).frame(width: 22).foregroundStyle(theme.color(role))
      Text(title).foregroundStyle(theme.color(.text)).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 0)
    }
  }

  private func message(_ text: String) -> some View {
    Text(text).foregroundStyle(theme.color(.textSecondary))
  }

  private func relative(_ absolute: String) -> String {
    guard let root = context?.directory, absolute.hasPrefix(root + "/") else { return absolute }
    return String(absolute.dropFirst(root.count + 1))
  }

  private func role(_ change: FileExplorer.Change) -> ThemeRole {
    switch change {
    case .added: .success
    case .deleted: .error
    case .modified: .info
    }
  }

  private func label(_ change: FileExplorer.Change) -> String {
    switch change {
    case .added: "Adicionado"
    case .deleted: "Excluído"
    case .modified: "Modificado"
    }
  }

  private func load() async {
    guard let context else { return }
    do {
      entries = try await context.client.listDirectory(path, location: context.directory)
      failure = nil
    } catch {
      if Task.isCancelled { return }
      failure = switch error as? ClientError {
      case .http(404): "Esta pasta não existe no servidor."
      case .http(500): "Não foi possível ler esta pasta. Verifique as permissões dela no servidor."
      default: error.localizedDescription
      }
    }
  }

  private func find(_ search: String) async {
    results = nil
    searchFailed = false
    guard !search.isEmpty, let context else { return }
    do {
      try await Task.sleep(for: .milliseconds(180))
      results = try await context.client.findFiles(search, location: context.directory)
    } catch {
      if !Task.isCancelled { searchFailed = true }
    }
  }
}

/// The explorer opened from a folder link in the conversation, with the same navigation as from
/// Detalhes da sessão: `../`, search, and files opening in the viewer over it.
struct FileFolderBrowser: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let path: String
  let context: ConversationImageContext
  @State private var changes: [String: FileExplorer.Change] = [:]
  var body: some View {
    NavigationStack {
      FileExplorerView(path: path, changes: changes)
        .navigationDestination(for: FileExplorerRoute.self) { FileExplorerView(path: $0.path, changes: changes) }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
    }
    .tint(theme.color(.primary))
    .modifier(FileViewerHost())
    .environment(\.conversationImages, context)
    .task {
      async let located = try? context.client.locate([context.directory])
      async let working = try? context.client.workingChanges(directory: context.directory)
      let root = await located?.first?.worktree ?? context.directory
      changes = FileExplorer.changes(await working ?? [], root: root)
    }
  }
}
