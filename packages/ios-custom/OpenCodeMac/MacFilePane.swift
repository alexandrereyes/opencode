import AppKit
import OpenCodeKit
import SwiftUI

/// The selected file below the list: `ARQUIVO · N LINHAS` with the links Abrir no Xcode · Finder · Ver diff
/// (only when the path exists on this Mac), then the text in SF Mono with line numbers, or Quick Look.
struct MacFilePane: View {
  @Environment(\.appTheme) private var theme
  let files: MacFilesStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let path = files.selected {
        ContextHairline()
        header(path).padding(.vertical, 9)
        ContextHairline()
        content
      } else {
        ContextHairline()
        Text("Escolha um arquivo para ver o conteúdo.").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func header(_ path: String) -> some View {
    let url = URL(fileURLWithPath: path)
    let local = FileManager.default.fileExists(atPath: path)
    let status = files.context.statuses[path]
    let merge = local && MacTools.fileMerge != nil
      ? ContextColumn.fileMerge(path, root: files.context.root, status: status) : nil
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      HStack(spacing: 0) {
        Text(url.lastPathComponent.uppercased()).lineLimit(1).truncationMode(.middle)
        if let lines = lines(url) { Text(lines).lineLimit(1).fixedSize() }
      }
      .font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
      .foregroundStyle(theme.color(.text))
      .help(folder(url) + url.lastPathComponent)
      Spacer(minLength: 6)
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
          link("Ver diff") {
            Task {
              if let error = await MacTools.openFileMerge(merge, file: url) {
                files.context.sessions.toast.show(error, kind: .error)
              }
            }
          }
          .disabled(status == nil)
          .help(status != nil ? "Comparar com o último commit (HEAD) no FileMerge" : "Arquivo sem alterações")
        }
      }
      .fixedSize()
    }
  }

  private var dot: some View { Text("·").foregroundStyle(theme.color(.textWeak)).font(.system(size: 10)) }

  private func link(_ title: String, perform: @escaping () -> Void) -> some View {
    Button(title, action: perform).buttonStyle(.plain).font(.system(size: 10))
      .foregroundStyle(theme.color(.textSecondary))
  }

  /// ` · 193 LINHAS`, after the file's name in capitals.
  private func lines(_ url: URL) -> String? {
    guard let text = files.file?.text, files.file?.path == url.path else { return nil }
    let lines = text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
      - (text.hasSuffix("\n") ? 1 : 0)
    return " · \(lines) " + (lines == 1 ? "LINHA" : "LINHAS")
  }

  @ViewBuilder private var content: some View {
    Group {
      if let file = files.file {
        if let error = file.error {
          Label(error, systemImage: "exclamationmark.triangle").appFont(.caption)
            .foregroundStyle(theme.color(.textSecondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
  }

  private func folder(_ url: URL) -> String {
    let folder = url.deletingLastPathComponent().path
    let root = files.context.root
    if folder == root { return URL(fileURLWithPath: root).lastPathComponent + "/" }
    return folder.hasPrefix(root + "/") ? String(folder.dropFirst(root.count + 1)) + "/" : folder + "/"
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
