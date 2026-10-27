import AppKit
import Observation
import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

/// Arquivos, over the Contexto column: the session's checkout as a Finder-like list (`/api/fs/list`, like the
/// iPhone explorer) with working-copy changes, and the selected file below it.
struct MacFilesView: View {
  @Environment(\.appTheme) private var theme
  let context: ContextColumnStore
  @Bindable var runtime: MacRuntime
  @State private var files: MacFilesStore?

  var body: some View {
    Group {
      if let files { MacFilesContent(files: files, runtime: runtime) } else { Color.clear }
    }
    // Opened at launch, Arquivos can appear before the session (and its directory) has loaded.
    .task(id: context.directory) {
      guard context.directory != nil else { return }
      let store = MacFilesStore(context: context)
      files = store
      await store.open(folder: runtime.selection.files?.folder, file: runtime.selection.files?.file)
    }
    .onChange(of: runtime.selection.files) { _, next in
      guard let files, let next, next.folder != nil || next.file != nil,
        next.folder != files.folder || next.file != files.selected else { return }
      Task { await files.open(folder: next.folder, file: next.file) }
    }
  }
}

private struct MacFilesContent: View {
  @Environment(\.appTheme) private var theme
  @Bindable var files: MacFilesStore
  @Bindable var runtime: MacRuntime
  @State private var searching = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 10) {
      ContextCard {
        HStack(spacing: 12) {
          Button {
            runtime.selection.files = nil
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "chevron.left").appSymbol(.inline, weight: .semibold)
              Text("Contexto")
            }
            .fixedSize()
            .appFont(.heading).foregroundStyle(theme.color(.primary))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(theme.color(.surfaceRaised), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.color(.border), lineWidth: 1) }
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          Divider().frame(height: 22)
          Image(systemName: "doc.text").appSymbol(.action).foregroundStyle(theme.color(.text))
          Text("Arquivos").appFont(.title, weight: .semibold).foregroundStyle(theme.color(.textStrong))
          Spacer(minLength: 8)
          Toggle("Só alterados", isOn: $files.onlyChanged)
            .toggleStyle(.checkbox).appFont(.secondary)
            .help("Mostrar só os arquivos alterados e as pastas que os contêm")
          Button {
            searching.toggle()
            if searching { searchFocused = true } else { files.query = "" }
          } label: {
            Image(systemName: "magnifyingglass").appSymbol(.action).foregroundStyle(theme.color(.text))
              .frame(width: 32, height: 32)
              .background(theme.color(.surfaceRaised), in: RoundedRectangle(cornerRadius: 9))
              .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.color(.border), lineWidth: 1) }
          }
          .buttonStyle(.plain).help("Buscar arquivos").accessibilityLabel("Buscar arquivos")
        }
        if searching {
          TextField("Buscar arquivos na sessão", text: $files.query)
            .textFieldStyle(.roundedBorder).focused($searchFocused).padding(.top, 10)
        } else {
          breadcrumb.padding(.top, 10)
        }
      }
      VSplitView {
        listCard.frame(minHeight: 150, idealHeight: 330)
        MacFilePane(files: files).frame(minHeight: 180, idealHeight: 420)
      }
    }
    .padding(12)
    .task(id: files.query) { await files.find() }
    .onChange(of: files.folder) { _, folder in runtime.selection.files?.folder = folder }
    .onChange(of: files.selected) { _, file in runtime.selection.files?.file = file }
  }

  private var breadcrumb: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        Image(systemName: "folder").foregroundStyle(theme.color(.text))
        let crumbs = ContextColumn.breadcrumb(files.folder, root: files.context.root)
        ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
          if index > 0 {
            Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.textWeak))
          }
          Button(crumb.name) { Task { await files.open(folder: crumb.path, file: nil) } }
            .buttonStyle(.plain)
            .foregroundStyle(theme.color(index == crumbs.count - 1 ? .textStrong : .text))
        }
      }
      .appFont(.secondary)
      .padding(.horizontal, 10).padding(.vertical, 7)
    }
    .scrollIndicators(.never)
    // The current folder is the end of the path: keep it in view.
    .defaultScrollAnchor(.trailing)
    .background(theme.color(.surfaceRaised).opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.color(.border), lineWidth: 1) }
  }

  private var listCard: some View {
    Group {
      if let failure = files.failure {
        VStack(spacing: 10) {
          Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(theme.color(.error))
          Button("Tentar novamente") { Task { await files.load() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Table(files.rows, selection: $files.tableSelection, sortOrder: $files.sortOrder) {
          TableColumn("Nome", value: \MacFileRow.name) { row in
            HStack(spacing: 8) {
              Image(nsImage: row.icon).resizable().frame(width: 18, height: 18)
              Text(row.title).lineLimit(1).truncationMode(.middle).foregroundStyle(theme.color(.textStrong))
            }
          }
          .width(min: 120, ideal: 200)
          TableColumn("Modificado") { row in
            Text(row.modified.map { $0.formatted(.dateTime.day().month(.twoDigits).hour().minute()) } ?? "—")
              .foregroundStyle(theme.color(.textSecondary)).monospacedDigit()
          }
          .width(min: 80, ideal: 96)
          TableColumn("Tamanho") { row in
            Text(row.size.map { $0.formatted(.byteCount(style: .file)) } ?? "—")
              .foregroundStyle(theme.color(.textSecondary)).monospacedDigit()
          }
          .width(min: 50, ideal: 58)
          TableColumn("Status") { row in
            MacFileStatus(row: row)
          }
          .width(min: 64, ideal: 84)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .appFont(.secondary)
        .contextMenu(forSelectionType: String.self) { ids in
          if let id = ids.first, FileManager.default.fileExists(atPath: id) {
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)]) }
          }
          if let id = ids.first {
            Button("Copiar caminho") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(id, forType: .string)
            }
          }
        } primaryAction: { ids in
          if let id = ids.first { files.activate(id) }
        }
        .overlay {
          if files.rows.isEmpty {
            Text(files.entries == nil && files.results == nil ? "Carregando…"
              : files.onlyChanged ? "Nenhum arquivo alterado aqui." : "Pasta vazia")
              .foregroundStyle(theme.color(.textSecondary))
          }
        }
      }
    }
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 14))
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.color(.border), lineWidth: 1) }
  }
}

/// The amber dot and `+N −M` of a changed file; folders holding changes keep only the dot.
private struct MacFileStatus: View {
  @Environment(\.appTheme) private var theme
  let row: MacFileRow
  var body: some View {
    HStack(spacing: 6) {
      if let status = row.status {
        Circle().fill(theme.color(status.change == .deleted ? .error : status.change == .added ? .success : .warning))
          .frame(width: 8, height: 8)
        if status.additions > 0 { Text("+\(status.additions)").foregroundStyle(theme.color(.text)) }
        if status.deletions > 0 { Text("−\(status.deletions)").foregroundStyle(theme.color(.error)) }
      } else if row.containsChanges {
        Circle().fill(theme.color(.warning).opacity(0.6)).frame(width: 6, height: 6)
      }
      Spacer(minLength: 0)
      if row.directory {
        Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.icon))
      }
    }
    .monospacedDigit()
  }
}

struct MacFileRow: Identifiable {
  let id: String
  let name: String
  /// The name, or the path relative to the session for search results.
  let title: String
  let directory: Bool
  let modified: Date?
  let size: Int64?
  let status: ContextColumn.FileStatus?
  let containsChanges: Bool
  var icon: NSImage {
    if directory { return NSWorkspace.shared.icon(for: .folder) }
    return NSWorkspace.shared.icon(for: UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) ?? .data)
  }
}

@MainActor @Observable final class MacFilesStore {
  let context: ContextColumnStore
  private(set) var folder = "/"
  private(set) var entries: [DirectoryEntry]?
  private(set) var failure: String?
  private(set) var results: [String]?
  var query = ""
  var onlyChanged = false
  var sortOrder = [KeyPathComparator(\MacFileRow.name)]
  var selected: String?
  private(set) var file: MacLoadedFile?

  init(context: ContextColumnStore) { self.context = context }

  var tableSelection: String? {
    get { selected }
    set {
      guard let newValue, newValue != selected else { return }
      if rows.first(where: { $0.id == newValue })?.directory == true {
        Task { await open(folder: newValue, file: nil) }
      } else {
        select(newValue)
      }
    }
  }

  var rows: [MacFileRow] {
    let statuses = context.statuses
    let folders = ContextColumn.changedFolders(statuses)
    if let results, !query.trimmingCharacters(in: .whitespaces).isEmpty {
      return results.filter { !onlyChanged || statuses[$0] != nil }.map { path in
        row(DirectoryEntry(name: URL(fileURLWithPath: path).lastPathComponent, absolute: path, kind: .file),
          title: relative(path), statuses: statuses, folders: folders)
      }
    }
    let order: ContextColumn.SortOrder = sortOrder.first?.order == .reverse ? .descending : .ascending
    return ContextColumn.entries(entries ?? [], statuses: statuses, onlyChanged: onlyChanged, order: order)
      .map { row($0, title: $0.name, statuses: statuses, folders: folders) }
  }

  func open(folder: String?, file: String?) async {
    let target = folder ?? file.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
      ?? context.directory ?? context.root
    if target != self.folder || entries == nil {
      self.folder = target
      entries = nil
      await load()
    }
    if let file { select(file) }
  }

  func load() async {
    guard let directory = context.directory else { return }
    do {
      entries = try await context.client.listDirectory(folder, location: directory)
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

  func find() async {
    let search = query.trimmingCharacters(in: .whitespaces)
    results = nil
    guard !search.isEmpty, let directory = context.directory else { return }
    try? await Task.sleep(for: .milliseconds(180))
    guard !Task.isCancelled else { return }
    results = (try? await context.client.findFiles(search, location: directory)) ?? []
  }

  func activate(_ id: String) {
    if rows.first(where: { $0.id == id })?.directory == true {
      Task { await open(folder: id, file: nil) }
    } else {
      select(id)
    }
  }

  func select(_ path: String) {
    guard path != selected || file == nil else { return }
    selected = path
    file = nil
    Task {
      let loaded = await MacLoadedFile.load(path, client: context.client)
      if selected == path { file = loaded }
    }
  }

  private func relative(_ path: String) -> String {
    guard let directory = context.directory, path.hasPrefix(directory + "/") else { return path }
    return String(path.dropFirst(directory.count + 1))
  }

  private func row(
    _ entry: DirectoryEntry, title: String, statuses: [String: ContextColumn.FileStatus], folders: Set<String>
  ) -> MacFileRow {
    // The server lists names only; dates and sizes come from this Mac when the checkout is local.
    let attributes = try? FileManager.default.attributesOfItem(atPath: entry.absolute)
    return MacFileRow(
      id: entry.absolute, name: entry.name, title: title, directory: entry.kind == .directory,
      modified: attributes?[.modificationDate] as? Date,
      size: entry.kind == .directory ? nil : (attributes?[.size] as? NSNumber)?.int64Value,
      status: statuses[entry.absolute], containsChanges: folders.contains(entry.absolute))
  }
}

/// A file ready to show: read from this Mac when the path exists here, otherwise downloaded from the server
/// (`FileTransfer`, like the iPhone viewer).
struct MacLoadedFile: Equatable {
  let path: String
  let url: URL
  let text: String?
  let local: Bool
  var error: String?

  static let textLimit = 2 * 1024 * 1024

  static func load(_ path: String, client: OpenCodeClient) async -> MacLoadedFile {
    if FileManager.default.isReadableFile(atPath: path) {
      let url = URL(fileURLWithPath: path)
      return MacLoadedFile(path: path, url: url, text: await text(url), local: true)
    }
    do {
      let downloaded = try await FileTransfer().download(client.fileRequest(path: path)) { _, _ in }
      let stored = try FilePreviewStorage.store(downloaded, name: URL(fileURLWithPath: path).lastPathComponent)
      return MacLoadedFile(path: path, url: stored, text: await text(stored), local: false)
    } catch {
      return MacLoadedFile(path: path, url: URL(fileURLWithPath: path), text: nil, local: false,
        error: FileTransferFailure.map(error).localizedDescription)
    }
  }

  /// Text is drawn in-process up to 2 MB; images, PDFs and binaries go to Quick Look.
  private static func text(_ url: URL) async -> String? {
    await Task.detached {
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
      guard size <= textLimit, let data = try? Data(contentsOf: url),
        !data.prefix(4096).contains(0), let text = String(data: data, encoding: .utf8)
      else { return nil }
      return text
    }.value
  }
}
