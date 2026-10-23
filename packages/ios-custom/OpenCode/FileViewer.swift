import AVKit
import OpenCodeKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FileOpenAction {
  let open: (String) -> Void
}
extension EnvironmentValues {
  @Entry var openFile: FileOpenAction? = nil
}

struct FileViewerHost: ViewModifier {
  @Environment(\.conversationImages) private var context
  @State private var selection: Selection?
  private struct Selection: Identifiable { let id: String }
  func body(content: Content) -> some View {
    content.environment(\.openFile, FileOpenAction(open: { selection = Selection(id: $0) }))
      .fullScreenCover(item: $selection) { selection in
        if let context {
          FileViewer(source: selection.id, context: context).floatingVoiceInset()
            .modifier(FloatingVoiceScope())
        }
      }
  }
}

@MainActor @Observable final class FileViewerStore {
  let source: String
  let context: ConversationImageContext
  let suggestedName: String?
  var path: String?
  var metadata: FileMetadata?
  var file: URL?
  var preview: URL?
  var completed: Int64 = 0
  var expected: Int64 = 0
  var loading = true
  var confirmation = false
  var error: String?
  var cancelled = false
  var kind: FileViewerKind = .unknown
  var choices: [String] = []
  private var task: Task<Void, Never>?
  private let transfer = FileTransfer()
  init(source: String, context: ConversationImageContext, name: String? = nil) {
    self.source = source
    self.context = context
    suggestedName = name
  }
  var name: String { suggestedName ?? URL(fileURLWithPath: path ?? source).lastPathComponent }
  func start(confirmed: Bool = false) {
    task?.cancel()
    error = nil
    cancelled = false
    confirmation = false
    loading = true
    completed = 0
    expected = 0
    task = Task { [self] in
      do {
        if case .data(let value) = FeedImageReference(source) {
          guard let comma = value.firstIndex(of: ","), value[..<comma].contains(";base64"),
            let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else { throw FileTransferFailure.failed }
          let mime = String(value.dropFirst(5).prefix { $0 != ";" })
          let filename = suggestedName?.contains(".") == true ? suggestedName! : "imagem.\(UTType(mimeType: mime)?.preferredFilenameExtension ?? "png")"
          file = try FilePreviewStorage.store(data, name: URL(fileURLWithPath: filename).lastPathComponent)
          metadata = FileMetadata(size: Int64(data.count), mime: mime)
          kind = .image
          loading = false
          return
        }
        if case .remote(let url) = FeedImageReference(source) { path = url.path }
        if path == nil {
          choices = try await context.client.fileLinkMatches(source, directory: context.directory)
          try Task.checkCancellation()
          if choices.count > 1 { loading = false; return }
          let reference = FeedImageReference(source)
          let home = source.hasPrefix("~") ? try await context.client.serverHome() : nil
          path = try choices.first ?? reference.path(directory: context.directory, home: home)
        }
        guard let path else { throw FileTransferFailure.failed }
        var request = context.client.fileRequest(path: path)
        if case .remote(let url) = FeedImageReference(source) {
          request = try context.client.imageRemoteRequest(url)
          request.setValue(nil, forHTTPHeaderField: "Range")
          request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        if metadata == nil {
          var probe = request
          probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
          metadata = try await transfer.metadata(probe)
        }
        try Task.checkCancellation()
        kind = FileViewerKind(path: path, mime: metadata?.mime)
        if !confirmed && FileViewerKind.requiresConfirmation(metadata?.size) {
          confirmation = true
          loading = false
          return
        }
        let downloaded = try await transfer.download(request) { [weak self] bytes, total in
          Task { @MainActor in
            self?.completed = bytes
            self?.expected = total
          }
        }
        if Task.isCancelled { try? FileManager.default.removeItem(at: downloaded); return }
        let stored = try FilePreviewStorage.store(downloaded, name: URL(fileURLWithPath: path).lastPathComponent)
        file = stored
        // Some source extensions (notably .ts) have a registered media UTI, not a code preview.
        if kind == .preview, stored.pathExtension.isEmpty
          || ["md", "markdown", "json", "csv", "tsv", "swift", "ts", "tsx", "js", "jsx", "py", "rb", "rs", "go", "sh", "yaml", "yml", "toml", "log", "sql", "html", "css", "xml", "c", "h", "cpp"].contains(stored.pathExtension.lowercased())
          || metadata?.mime == "text/plain" && stored.pathExtension.lowercased() != "txt" {
          let text = stored.deletingLastPathComponent().appendingPathComponent("prévia.txt")
          try FileManager.default.copyItem(at: stored, to: text)
          preview = text
        } else { preview = stored }
        loading = false
      } catch {
        guard !Task.isCancelled else { return }
        self.error = FileTransferFailure.map(error).localizedDescription
        loading = false
      }
    }
  }
  func cancel() {
    task?.cancel()
    cancelled = true
    loading = false
  }
  func close() {
    task?.cancel()
    if let file { FilePreviewStorage.remove(file) }
    file = nil
    preview = nil
  }
}

struct FeedImageFileActions: View {
  @Environment(\.conversationImages) private var context
  let source: String
  let name: String
  @State private var sharing = false
  @State private var copied = false
  var body: some View {
    Button(copied ? "Caminho copiado" : "Copiar caminho", systemImage: "doc.on.doc") {
      Task {
        if case .local = FeedImageReference(source), let context {
          let home = source.hasPrefix("~") ? try? await context.client.serverHome() : nil
          UIPasteboard.general.string = (try? FeedImageReference(source).path(directory: context.directory, home: home)) ?? source
        } else { UIPasteboard.general.string = FeedImageReference.display(source) }
        copied = true
        Haptics.play(.selection)
      }
    }
    Button("Compartilhar", systemImage: "square.and.arrow.up") { sharing = true }
      .sheet(isPresented: $sharing) {
        if let context { FeedImageShareDownload(source: source, name: name, context: context) }
      }
  }
}

private struct FeedImageShareDownload: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  @State private var store: FileViewerStore
  @State private var shareReady = false
  init(source: String, name: String, context: ConversationImageContext) {
    _store = State(initialValue: FileViewerStore(source: source, context: context, name: name))
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 18) {
        Text(store.name).font(.headline)
        if let error = store.error {
          Text(error)
          Button("Tentar novamente") { store.start() }
        } else if store.confirmation {
          Text((store.metadata?.size ?? 0).formatted(.byteCount(style: .file)))
          Text("Este arquivo tem mais de 50 MB. Deseja baixá-lo?")
          Button("Baixar arquivo") { store.start(confirmed: true) }
        } else {
          ProgressView("Preparando arquivo para compartilhar…")
        }
        Button("Cancelar") { store.cancel(); dismiss() }
      }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color(.background)).foregroundStyle(theme.color(.text))
        .navigationTitle("Compartilhar imagem").navigationBarTitleDisplayMode(.inline)
    }
    .task { store.start() }
    .onChange(of: store.file) { _, file in if file != nil { shareReady = true } }
    .sheet(isPresented: $shareReady, onDismiss: { dismiss() }) {
      if let file = store.file { FileShareSheet(file: file) }
    }
    .onDisappear { store.close() }
  }
}

struct FileViewer: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var store: FileViewerStore
  @State private var sharing = false
  @State private var copied = false
  init(source: String, context: ConversationImageContext) {
    _store = State(initialValue: FileViewerStore(source: source, context: context))
  }
  var body: some View {
    NavigationStack {
      Group {
        if let file = store.file {
          loaded(file)
        } else if store.choices.count > 1, store.path == nil {
          List(store.choices, id: \.self) { path in
            Button(path) { store.path = path; store.start() }
          }.navigationTitle("Escolher arquivo")
        } else {
          VStack(spacing: 18) {
            Image(systemName: "doc").font(.largeTitle)
            Text(store.name).font(.headline)
            if let size = store.metadata?.size { Text(size.formatted(.byteCount(style: .file))) }
            if let error = store.error {
              Text(error).accessibilityIdentifier("file-error")
              Button("Tentar novamente") { store.start() }
            } else if store.confirmation {
              Text("Este arquivo tem mais de 50 MB. Deseja baixá-lo?")
              Button("Baixar arquivo") { store.start(confirmed: true) }
              Button("Cancelar", role: .cancel) { dismiss() }
            } else if store.cancelled {
              Text("Download cancelado")
              Button("Tentar novamente") { store.start() }
            } else {
              ProgressView(value: store.expected > 0 ? Double(store.completed) / Double(store.expected) : nil)
                .accessibilityLabel("Baixando arquivo")
              Text(store.completed.formatted(.byteCount(style: .file)))
              Button("Cancelar download") { store.cancel() }
            }
            Text(store.path ?? store.source).font(.caption).textSelection(.enabled)
          }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(theme.color(.background)).foregroundStyle(theme.color(.text))
      .navigationTitle(store.name).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("Fechar") { dismiss() } }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button(copied ? "Caminho copiado" : "Copiar caminho", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = store.path ?? store.source
            copied = true
            Haptics.play(.selection)
          }
          Button("Compartilhar", systemImage: "square.and.arrow.up") { sharing = true }
            .disabled(store.file == nil)
        }
      }
    }
    .tint(theme.color(.primary))
    .sheet(isPresented: $sharing) { if let file = store.file { FileShareSheet(file: file) } }
    .task { store.start() }
    .onDisappear { store.close() }
  }
  @ViewBuilder private func loaded(_ file: URL) -> some View {
    switch store.kind {
    case .image:
      FileImagePreview(file: file, name: store.name, dismiss: { dismiss() }, retry: { store.close(); store.start() })
        .accessibilityIdentifier("file-image")
    case .audiovisual:
      FileAVPlayer(file: file).accessibilityIdentifier("file-player")
    case .preview:
      FileQuickLook(file: store.preview ?? file, name: store.name).accessibilityIdentifier("file-preview")
    case .unknown:
      if UTType(filenameExtension: file.pathExtension)?.isDeclared == true,
        QLPreviewController.canPreview(file as NSURL) {
        FileQuickLook(file: file, name: store.name).accessibilityIdentifier("file-preview")
      } else {
        VStack(spacing: 16) {
          Image(systemName: "doc").font(.largeTitle)
          Text(store.name).font(.headline)
          if let size = store.metadata?.size { Text(size.formatted(.byteCount(style: .file))) }
          Text(store.path ?? store.source).font(.caption).textSelection(.enabled)
          Button("Compartilhar arquivo", systemImage: "square.and.arrow.up") { sharing = true }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

private struct FileImagePreview: View {
  let file: URL
  let name: String
  let dismiss: () -> Void
  let retry: () -> Void
  @State private var image: CGImage?
  @State private var failed = false
  var body: some View {
    Group {
      if let image { ZoomableImageView(image: image, name: name, dismiss: dismiss) }
      else if failed {
        VStack(spacing: 12) {
          Text("Não foi possível exibir a imagem")
          Button("Tentar novamente", action: retry)
        }
      }
      else { ProgressView("Carregando imagem…") }
    }
    .task(id: file) {
      let image = await Task.detached(priority: .userInitiated) {
        (try? Data(contentsOf: file, options: .mappedIfSafe)).flatMap { AttachmentImage.thumbnail($0, maxPixelSize: nil) }
      }.value
      guard !Task.isCancelled else { return }
      self.image = image
      failed = image == nil
    }
  }
}

private struct FileAVPlayer: UIViewControllerRepresentable {
  let file: URL
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    let player = AVPlayer(url: file)
    controller.player = player
    context.coordinator.observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak controller] player, _ in
      let value = player.timeControlStatus == .playing ? "Reproduzindo" : player.timeControlStatus == .paused ? "Pausado" : "Carregando"
      Task { @MainActor in controller?.view.accessibilityValue = value }
    }
    player.play()
    return controller
  }
  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
  static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
    coordinator.observation = nil
    controller.player?.pause()
    controller.player = nil
  }
  final class Coordinator { var observation: NSKeyValueObservation? }
}

private struct FileQuickLook: UIViewControllerRepresentable {
  let file: URL
  let name: String
  func makeCoordinator() -> Coordinator { Coordinator(file: file, name: name) }
  func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    return controller
  }
  func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
  final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(file: URL, name: String) { previewItemURL = file; previewItemTitle = name }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { self }
  }
}

struct FileShareSheet: UIViewControllerRepresentable {
  let file: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [file], applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
