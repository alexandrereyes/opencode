import AppKit
import OpenCodeKit
import SwiftUI

/// The open file beside the tree: ‹ › walk the history and ⌄ lists Recentes; the name, its folder and line count;
/// `Visualizar | Fonte` for Markdown and HTML; Abrir no Xcode · Finder · Ver diff (when the path exists on this
/// Mac), copy path and share. A narrow panel keeps the name and moves the rest into `•••`. Then the text (Markdown
/// rendered, code in SF Mono with line numbers) or Quick Look for images, PDF, audio and video.
struct MacFilePane: View {
  @Environment(\.appTheme) private var theme
  let files: MacFilesStore
  /// The panel is narrow: the actions go into `•••`.
  var compact = false
  /// Markdown and HTML open rendered; Fonte shows their source.
  @State private var source = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, 14).padding(.vertical, 9)
      ContextHairline()
      if files.selected != nil {
        content
      } else {
        Text("Escolha um arquivo para ver o conteúdo.").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background {
      // The sibling keys, without a visible control: ‹ › are the history now.
      Group {
        Button("") { files.step(-1) }.shortcut(.previousFile)
        Button("") { files.step(1) }.shortcut(.nextFile)
      }
      .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      navigation
      if let path = files.selected {
        title(path)
        Spacer(minLength: 6)
        if compact { more(path) } else { actions(path) }
      } else {
        Spacer()
      }
    }
  }

  /// ‹ › (⌃⌘← ⌃⌘→) and ⌄, Recentes.
  private var navigation: some View {
    HStack(spacing: 0) {
      icon("chevron.left", help: "Voltar (⌃⌘←)", identifier: "files-back", enabled: files.history.canGoBack) { files.back() }
        .shortcut(.fileBack)
      icon("chevron.right", help: "Avançar (⌃⌘→)", identifier: "files-forward", enabled: files.history.canGoForward) {
        files.forward()
      }
      .shortcut(.fileForward)
      Menu {
        Section("Recentes") {
          ForEach(files.recents.paths, id: \.self) { path in
            Button {
              files.select(path)
            } label: {
              Text(URL(fileURLWithPath: path).lastPathComponent) + Text("  " + folder(path)).foregroundStyle(.secondary)
            }
          }
        }
      } label: {
        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .frame(width: 22, height: 22)
      .foregroundStyle(theme.color(files.recents.paths.isEmpty ? .textWeak : .text))
      .disabled(files.recents.paths.isEmpty)
      .help("Recentes")
      .accessibilityLabel("Recentes")
      .accessibilityIdentifier("files-recents")
    }
    .padding(.top, 1)
  }

  private func icon(_ symbol: String, help: String, identifier: String, enabled: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(theme.color(enabled ? .text : .textWeak))
    .disabled(!enabled)
    .help(help)
    .accessibilityLabel(help)
    .accessibilityIdentifier(identifier)
  }

  /// The name, then its folder (relative to the session) and line count.
  private func title(_ path: String) -> some View {
    let url = URL(fileURLWithPath: path)
    return VStack(alignment: .leading, spacing: 2) {
      Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.color(.textStrong))
        .lineLimit(1).truncationMode(.middle)
        .accessibilityIdentifier("files-title")
      Text(folder(path) + (lines(url).map { " · " + $0 } ?? ""))
        .appFont(.footnote).foregroundStyle(theme.color(.textSecondary)).lineLimit(1).truncationMode(.head)
        .accessibilityIdentifier("files-subtitle")
    }
    .help(path)
  }

  private func actions(_ path: String) -> some View {
    let url = URL(fileURLWithPath: path)
    let local = FileManager.default.fileExists(atPath: path)
    let status = files.context.statuses[path]
    let merge = local && MacTools.fileMerge != nil
      ? ContextColumn.fileMerge(path, root: files.context.root, status: status) : nil
    return VStack(alignment: .trailing, spacing: 6) {
      if MacFileRendering(path: path) != nil {
        Picker("Modo", selection: $source) {
          Text("Visualizar").tag(false)
          Text("Fonte").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
        .help("Visualizar o arquivo renderizado ou o código-fonte")
        .accessibilityIdentifier("files-source")
      }
      HStack(spacing: 5) {
        if local, let xcode = MacTools.xcode {
          link("Abrir no Xcode") { NSWorkspace.shared.open([url], withApplicationAt: xcode, configuration: .init()) }
        }
        if local {
          if MacTools.xcode != nil { dot }
          link("Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .help("Mostrar no Finder")
        }
        if let merge {
          dot
          link("Ver diff") { diff(merge, url: url) }
            .disabled(status == nil)
            .help(status != nil ? "Comparar com o último commit (HEAD) no FileMerge" : "Arquivo sem alterações")
        }
        Button { copy(path) } label: {
          Image(systemName: "doc.on.doc").font(.system(size: 11)).frame(width: 20, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary))
        .help("Copiar caminho").accessibilityLabel("Copiar caminho do arquivo")
        ShareLink(item: files.file?.url ?? url) {
          Image(systemName: "square.and.arrow.up").font(.system(size: 11)).frame(width: 20, height: 18)
        }
        .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary))
        .help("Compartilhar").accessibilityLabel("Compartilhar")
      }
      .fixedSize()
    }
  }

  /// Everything but the name, in one menu.
  private func more(_ path: String) -> some View {
    let url = URL(fileURLWithPath: path)
    let local = FileManager.default.fileExists(atPath: path)
    let status = files.context.statuses[path]
    let merge = local && MacTools.fileMerge != nil
      ? ContextColumn.fileMerge(path, root: files.context.root, status: status) : nil
    return Menu {
      if MacFileRendering(path: path) != nil {
        Picker("Modo", selection: $source) {
          Text("Visualizar").tag(false)
          Text("Fonte").tag(true)
        }
        .pickerStyle(.inline)
        Divider()
      }
      if local, let xcode = MacTools.xcode {
        Button("Abrir no Xcode") { NSWorkspace.shared.open([url], withApplicationAt: xcode, configuration: .init()) }
      }
      if local { Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
      if let merge { Button("Ver diff") { diff(merge, url: url) }.disabled(status == nil) }
      Divider()
      Button("Copiar caminho") { copy(path) }
      ShareLink("Compartilhar…", item: files.file?.url ?? url)
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 22)
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .foregroundStyle(theme.color(.text))
    .help("Mais ações").accessibilityLabel("Mais ações").accessibilityIdentifier("files-more")
  }

  private var dot: some View { Text("·").foregroundStyle(theme.color(.textWeak)).font(.system(size: 10)) }

  private func link(_ title: String, perform: @escaping () -> Void) -> some View {
    Button(title, action: perform).buttonStyle(.plain).font(.system(size: 10))
      .foregroundStyle(theme.color(.textSecondary))
  }

  private func copy(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
    files.context.sessions.toast.show("Caminho copiado")
  }

  private func diff(_ merge: ContextColumn.FileMergePlan, url: URL) {
    Task {
      if let error = await MacTools.openFileMerge(merge, file: url) {
        files.context.sessions.toast.show(error, kind: .error)
      }
    }
  }

  /// `193 linhas`.
  private func lines(_ url: URL) -> String? {
    guard let text = files.file?.text, files.file?.path == url.path else { return nil }
    let lines = text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
      - (text.hasSuffix("\n") ? 1 : 0)
    return "\(lines) " + (lines == 1 ? "linha" : "linhas")
  }

  @ViewBuilder private var content: some View {
    Group {
      if let file = files.file {
        if let error = file.error {
          Label(error, systemImage: "exclamationmark.triangle").appFont(.caption)
            .foregroundStyle(theme.color(.textSecondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !source, MacFileRendering(path: file.path) == .markdown, let text = file.text {
          // The chat's Markdown renderer, piece by piece so a long README stays light.
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(Array(MarkdownSoftBreaks.sections(MarkdownSoftBreaks.unwrap(text)).enumerated()), id: \.offset) {
                MacMarkdownText(text: $0.element)
              }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .macThinScrollers()
          }
          .id(file.path)
        } else if !source, MacFileRendering(path: file.path) == .html {
          MacQuickLook(url: file.url)
        } else if let text = file.text {
          MacCodeView(text: text, path: file.path)
        } else {
          MacQuickLook(url: file.url)
        }
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .modifier(ReadAloudHost(text: files.file.flatMap { MacFileRendering(path: $0.path) == .markdown ? $0.text : nil },
      title: files.selected.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Arquivo",
      path: files.selected ?? "", client: files.context.sessions.client))
    .onChange(of: files.selected) { source = false }
  }

  /// The file's folder relative to the session (`reports`), or its absolute path outside it.
  private func folder(_ path: String) -> String {
    let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let root = files.context.directory ?? files.context.root
    if folder == root { return URL(fileURLWithPath: root).lastPathComponent }
    return folder.hasPrefix(root + "/") ? String(folder.dropFirst(root.count + 1)) : folder
  }
}

/// The files Arquivos draws rendered rather than as code: Markdown with the chat's renderer, HTML with Quick Look.
enum MacFileRendering {
  case markdown, html
  init?(path: String) {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "md", "markdown": self = .markdown
    case "html", "htm": self = .html
    default: return nil
    }
  }
}

/// Developer tools on this Mac, looked up once.
@MainActor enum MacTools {
  static let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
  /// FileMerge ships inside Xcode; `opendiff` hands it the two files.
  static let fileMerge: URL? = {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/opendiff") else { return nil }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FileMerge")
  }()

  /// Writes HEAD's version (`git show HEAD:<file>`, or an empty file for a new one) to a temporary file and
  /// opens it against the working copy in FileMerge. Returns an error message, or nil on success.
  static func openFileMerge(_ plan: ContextColumn.FileMergePlan, file: URL) async -> String? {
    await Task.detached {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-filemerge", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let base = folder.appendingPathComponent(plan.baseName)
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if plan.added {
          try Data().write(to: base)
        } else {
          let git = Process()
          git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
          git.arguments = plan.gitArguments
          FileManager.default.createFile(atPath: base.path, contents: nil)
          let output = try FileHandle(forWritingTo: base)
          git.standardOutput = output
          git.standardError = FileHandle.nullDevice
          try git.run()
          git.waitUntilExit()
          try output.close()
          guard git.terminationStatus == 0 else { return "O git não encontrou este arquivo no último commit." }
        }
        let diff = Process()
        diff.executableURL = URL(fileURLWithPath: "/usr/bin/opendiff")
        diff.arguments = [base.path, file.path]
        diff.standardOutput = FileHandle.nullDevice
        diff.standardError = FileHandle.nullDevice
        try diff.run()
        return nil
      } catch {
        return "Não foi possível abrir o FileMerge. \(error.localizedDescription)"
      }
    }.value
  }
}
