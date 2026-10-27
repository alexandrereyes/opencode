import AppKit
import OpenCodeKit
import SwiftUI

/// The selected file below the list: name and folder, Abrir no Xcode, Mostrar no Finder and Ver diff no
/// FileMerge (only when the path exists on this Mac), then the text or a Quick Look preview.
struct MacFilePane: View {
  @Environment(\.appTheme) private var theme
  let files: MacFilesStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let path = files.selected {
        header(path)
        content
      } else {
        Text("Escolha um arquivo para ver o conteúdo.")
          .foregroundStyle(theme.color(.textSecondary))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 14))
    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.color(.border), lineWidth: 1) }
    .padding(.top, 10)
  }

  private func header(_ path: String) -> some View {
    let url = URL(fileURLWithPath: path)
    let local = FileManager.default.fileExists(atPath: path)
    let status = files.context.statuses[path]
    let merge = local && MacTools.fileMerge != nil
      ? ContextColumn.fileMerge(path, root: files.context.root, status: status) : nil
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 10) {
        title(url)
        Spacer(minLength: 8)
        actions(url, local: local, merge: merge, changed: status != nil)
      }
      VStack(alignment: .leading, spacing: 8) {
        title(url)
        actions(url, local: local, merge: merge, changed: status != nil)
      }
    }
  }

  private func title(_ url: URL) -> some View {
    HStack(spacing: 10) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(url.lastPathComponent).appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
          .lineLimit(1)
        Text(folder(url)).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
          .lineLimit(1).truncationMode(.head)
      }
    }
  }

  @ViewBuilder private func actions(_ url: URL, local: Bool, merge: ContextColumn.FileMergePlan?, changed: Bool) -> some View {
    HStack(spacing: 8) {
      if local, let xcode = MacTools.xcode {
        action("Abrir no Xcode", icon: "hammer") {
          NSWorkspace.shared.open([url], withApplicationAt: xcode, configuration: .init())
        }
      }
      if local {
        action("Mostrar no Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
      if let merge {
        action("Ver diff no FileMerge", icon: "arrow.triangle.branch") {
          Task {
            if let error = await MacTools.openFileMerge(merge, file: url) {
              files.context.sessions.toast.show(error, kind: .error)
            }
          }
        }
        .disabled(!changed)
        .help(changed ? "Comparar com a versão do último commit (HEAD)" : "Arquivo sem alterações")
      }
    }
  }

  private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
    Button(action: perform) {
      Label(title, systemImage: icon).appFont(.caption, weight: .medium).fixedSize()
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
  }

  @ViewBuilder private var content: some View {
    Group {
      if let file = files.file {
        if let error = file.error {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(theme.color(.error))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text = file.text {
          MacCodeView(text: text, path: file.path)
        } else {
          MacQuickLook(url: file.url)
        }
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 10))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.codeBorder), lineWidth: 1) }
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
