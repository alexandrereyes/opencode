import AVKit
import ImageIO
import OpenCodeKit
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct FileOpenAction {
  let open: (String) -> Void
  /// A folder link opens the file explorer; without it a folder falls back to `open`.
  var folder: ((String) -> Void)? = nil
}
/// The handler only presents the host's viewer state, so any two copies are interchangeable.
extension FileOpenAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
}
extension EnvironmentValues {
  @Entry var openFile: FileOpenAction? = nil
}

/// Opens a chat image (Markdown, tool output or attachment) in the conversation-level viewer.
struct ImageOpenAction {
  let open: (_ source: String, _ name: String, _ context: ConversationImageContext) -> Void
}
extension ImageOpenAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
}
extension EnvironmentValues {
  @Entry var openImage: ImageOpenAction? = nil
}

/// Presents the file and image viewers from a view that outlives transcript rows. A presentation owned by a
/// recycled List row is rebuilt from scratch, with a new viewer state, once that row has scrolled away.
struct FileViewerHost: ViewModifier {
  @Environment(\.conversationImages) private var context
  @State private var selection: Selection?
  private enum Selection: Identifiable {
    case file(String)
    case folder(String)
    case image(source: String, name: String, context: ConversationImageContext)
    var id: String {
      switch self {
      case .file(let path): "file:" + path
      case .folder(let path): "folder:" + path
      case .image(let source, _, _): "image:" + source
      }
    }
  }
  func body(content: Content) -> some View {
    content.environment(\.openFile, FileOpenAction(open: { selection = .file($0) }, folder: { selection = .folder($0) }))
      .environment(\.openImage, ImageOpenAction(open: { selection = .image(source: $0, name: $1, context: $2) }))
      .fullScreenCover(item: $selection) { selection in
        Group {
          switch selection {
          case .file(let path):
            if let context { FileViewer(source: path, context: context) }
          case .folder(let path):
            if let context { FileFolderBrowser(path: path, context: context) }
          case .image(let source, let name, let context):
            // Server files open in the file viewer, which can page through their directory.
            if case .local = FeedImageReference(source) {
              FileViewer(source: source, context: context, name: ["", "Imagem"].contains(name) ? nil : name, exact: true)
            } else {
              FeedImageFullscreen(source: source, name: name).environment(\.conversationImages, context)
            }
          }
        }
        .floatingVoiceInset()
        .modifier(FloatingVoiceScope())
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
  var text: String?
  var markdown = false
  static let textLimit: Int64 = 2 * 1024 * 1024
  /// Feed images and siblings name one exact path; chat links may still need a workspace search.
  let exact: Bool
  private var task: Task<Void, Never>?
  private let transfer = FileTransfer()
  init(source: String, context: ConversationImageContext, name: String? = nil, exact: Bool = false) {
    self.source = source
    self.context = context
    suggestedName = name
    self.exact = exact
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
        #if DEBUG
        if ScrollFixtures.mode == "catalog" {
          guard let fixture = ScreenCatalogFixture.file(source) else { throw FileTransferFailure.notFound }
          path = source
          metadata = FileMetadata(size: Int64(fixture.data.count), mime: fixture.mime)
          file = try FilePreviewStorage.store(fixture.data, name: name)
          preview = file
          text = fixture.text
          markdown = fixture.text != nil
          kind = fixture.text == nil ? .image : .preview
          loading = false
          return
        }
        #endif
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
        if path == nil, exact {
          let home = source.hasPrefix("~") ? try await context.client.serverHome() : nil
          path = try FeedImageReference(source).path(directory: context.directory, home: home)
        }
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
        if !confirmed && kind.requiresConfirmation(metadata?.size) {
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
        let ext = stored.pathExtension.lowercased()
        // Some source extensions (notably .ts) have a registered media UTI, not a code preview.
        let textual = kind == .html || kind == .preview && (ext.isEmpty
          || ["md", "markdown", "json", "csv", "tsv", "swift", "ts", "tsx", "js", "jsx", "py", "rb", "rs", "go", "sh", "yaml", "yml", "toml", "log", "sql", "css", "xml", "c", "h", "cpp"].contains(ext)
          || metadata?.mime == "text/plain" && ext != "txt")
        if textual {
          let copy = stored.deletingLastPathComponent().appendingPathComponent("prévia.txt")
          try FileManager.default.copyItem(at: stored, to: copy)
          preview = copy
        } else { preview = stored }
        // Text is drawn in-process, so it can render Markdown and take part in horizontal paging;
        // large or non-UTF-8 files keep Quick Look.
        if textual || ext == "txt",
          Int64((try? stored.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max) <= FileViewerStore.textLimit {
          text = await Task.detached { try? String(contentsOf: stored, encoding: .utf8) }.value
          markdown = ["md", "markdown"].contains(ext)
        }
        file = stored
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
    text = nil
  }
  /// Starts the first load or resumes one interrupted by `suspend()`; a loaded, failed or waiting file stays as is.
  func begin() {
    guard file == nil, loading, task?.isCancelled != false else { return }
    start()
  }
  /// A disappearance is not always a dismissal (a scene deactivation can report one), so a loaded file survives it.
  func suspend() { task?.cancel() }
  isolated deinit {
    task?.cancel()
    if let file { FilePreviewStorage.remove(file) }
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
  @State private var siblings: [String]?
  /// Files opened from links inside the viewer, for Voltar.
  @State private var history: [String] = []
  @State private var showSource = false
  /// The HTML preview starts on local files for every opened file; the internet is allowed per file.
  @State private var htmlInternet = false
  init(source: String, context: ConversationImageContext, name: String? = nil, exact: Bool = false) {
    _store = State(initialValue: FileViewerStore(source: source, context: context, name: name, exact: exact))
  }
  private var position: Int? { store.path.flatMap { siblings?.firstIndex(of: $0) } }
  private func neighbor(_ step: Int) -> String? {
    guard let position, let siblings, siblings.indices.contains(position + step) else { return nil }
    return siblings[position + step]
  }
  private func page(_ step: Int) {
    guard let next = neighbor(step) else { return }
    store.close()
    store = FileViewerStore(source: next, context: store.context, exact: true)
    copied = false
    htmlInternet = false
    store.start()
  }
  /// A link inside a file opens here, relative to that file; its directory becomes the paging sequence.
  private func follow(_ link: String) {
    guard let path = MarkdownDocument.linkedFile(link, from: store.path ?? store.source) else { return }
    history.append(store.path ?? store.source)
    show(path)
  }
  private func back() {
    guard let previous = history.popLast() else { return }
    show(previous)
  }
  private func show(_ path: String) {
    store.close()
    siblings = nil
    store = FileViewerStore(source: path, context: store.context, exact: true)
    copied = false
    htmlInternet = false
    store.start()
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
              Text("Este arquivo tem mais de \(store.kind.confirmationBytes / 1024 / 1024) MB. Deseja baixá-lo?")
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
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .environment(\.openFile, FileOpenAction(open: follow))
      // Images inside a file resolve against it and present over this viewer, not the conversation.
      .environment(\.openImage, nil)
      // A new file always starts with fresh viewer state, including zoom.
      .id(store.source)
      .gesture(FilePageSwipe(previous: neighbor(-1) != nil, next: neighbor(1) != nil, page: page))
      .overlay {
        HStack {
          if neighbor(-1) != nil {
            pageButton(-1, symbol: "chevron.left", label: "Arquivo anterior", identifier: "file-previous")
          }
          Spacer(minLength: 0)
          if neighbor(1) != nil {
            pageButton(1, symbol: "chevron.right", label: "Próximo arquivo", identifier: "file-next")
          }
        }.padding(.horizontal, 10)
      }
      .background(theme.color(.background)).foregroundStyle(theme.color(.text))
      .navigationTitle(store.name).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .topBarLeading) {
          Button("Fechar") { dismiss() }
          if !history.isEmpty {
            Button("Voltar", systemImage: "chevron.backward", action: back).accessibilityIdentifier("file-back")
          }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          if store.markdown && store.text != nil || store.kind == .html && store.file != nil {
            let html = store.kind == .html
            Button(showSource ? (html ? "Ver prévia" : "Ver renderizado") : (html ? "Ver código" : "Ver fonte"),
              systemImage: showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right") {
              showSource.toggle()
            }
            .accessibilityIdentifier("file-markdown-source")
          }
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
    .task { store.begin() }
    .task(id: store.path) {
      // The opened file's directory defines the sequence; paging keeps it.
      guard siblings == nil, let path = store.path, case .local = FeedImageReference(store.source) else { return }
      let listed = try? await store.context.client.fileSiblings(of: path, location: store.context.directory)
      guard !Task.isCancelled, store.path == path else { return }
      siblings = listed
    }
    .onDisappear { store.suspend() }
  }
  private func pageButton(_ step: Int, symbol: String, label: String, identifier: String) -> some View {
    Button { page(step) } label: {
      Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 44, height: 44)
    }
    .buttonStyle(.glass).buttonBorderShape(.circle)
    .accessibilityLabel(label)
    .accessibilityValue(position.map { "\($0 + 1 + step) de \(siblings?.count ?? 0)" } ?? "")
    .accessibilityIdentifier(identifier)
  }
  @ViewBuilder private func loaded(_ file: URL) -> some View {
    switch store.kind {
    case .image:
      FileImagePreview(file: file, name: store.name, dismiss: { dismiss() }, retry: { store.close(); store.start() })
        .accessibilityIdentifier("file-image")
    case .audiovisual:
      FileAVPlayer(file: file).accessibilityIdentifier("file-player")
    case .preview:
      ZStack {
        if let text = store.text, store.markdown, !showSource {
          FileMarkdownPreview(text: text, path: store.path ?? store.source, context: store.context)
        }
        else if let text = store.text { FileTextPreview(text: text, code: file.pathExtension.lowercased() != "txt") }
        else if file.pathExtension.lowercased() == "pdf" { FilePDFPreview(file: file) }
        else if file.pathExtension.lowercased() == "svg" || store.metadata?.mime == "image/svg+xml",
          (store.metadata?.size ?? 0) <= FileViewerStore.textLimit { FileSVGPreview(file: file) }
        else { FileQuickLook(file: store.preview ?? file, name: store.name) }
      }
      .accessibilityElement(children: .contain).accessibilityIdentifier("file-preview")
      .modifier(ReadAloudHost(text: store.markdown ? store.text : nil, title: store.name, path: store.path ?? store.source,
        client: store.context.client))
    case .html:
      ZStack {
        if !showSource {
          FileHTMLPreview(file: file, path: store.path ?? store.source, context: store.context, internet: $htmlInternet)
        }
        else if let text = store.text { FileTextPreview(text: text, code: true) }
        // Source over the in-process text limit, as for other code files.
        else { FileQuickLook(file: store.preview ?? file, name: store.name) }
      }
      .accessibilityElement(children: .contain).accessibilityIdentifier("file-preview")
    case .unknown:
      if UTType(filenameExtension: file.pathExtension)?.isDeclared == true,
        QLPreviewController.canPreview(file as NSURL) {
        FileQuickLook(file: file, name: store.name).accessibilityIdentifier("file-preview")
      } else {
        VStack(spacing: 16) {
          Image(systemName: "doc").font(.largeTitle)
          Text(store.name).font(.headline)
          Text("Pré-visualização indisponível").accessibilityIdentifier("file-unsupported")
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
  @State private var decoded: URL?
  @State private var animated = false
  @State private var failed = false
  var body: some View {
    Group {
      if let image { ZoomableImageView(image: image, name: name, animation: animated ? file : nil, dismiss: dismiss).id(decoded) }
      else if failed {
        VStack(spacing: 12) {
          Text("Não foi possível exibir a imagem")
          Button("Tentar novamente", action: retry)
        }
      }
      else { ProgressView("Carregando imagem…") }
    }
    .task(id: file) {
      // `.task` also reruns when the view reappears; the decoded image and its zoom stay.
      guard decoded != file else { return }
      let result = await Task.detached(priority: .userInitiated) {
        let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        let frames = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.map(CGImageSourceGetCount) ?? 0
        return (data.flatMap { AttachmentImage.thumbnail($0, maxPixelSize: nil) }, frames > 1)
      }.value
      guard !Task.isCancelled else { return }
      animated = result.1
      image = result.0
      decoded = file
      failed = result.0 == nil
    }
  }
}

private struct FileTextPreview: UIViewRepresentable {
  @Environment(\.appTheme) private var theme
  let text: String
  let code: Bool
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isEditable = false
    view.backgroundColor = .clear
    view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
    view.adjustsFontForContentSizeCategory = true
    view.font = AppTypography.font(code ? .caption : .body, monospaced: code)
    view.text = text
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    view.textColor = UIColor(theme.color(.text))
    view.tintColor = UIColor(theme.color(.primary))
  }
}

/// A Markdown file through the response engine. Unlike a conversation row, a document can be thousands of points
/// tall, and a text view draws its whole height: slices mount lazily so only the visible ones hold bitmaps.
struct FileMarkdownPreview: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var scale
  let text: String
  let path: String
  let context: ConversationImageContext
  @State private var toast = ToastCenter()
  @State private var blocks: [MarkdownBlock]?
  @State private var rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:]
  @State private var note: Note?
  private struct Note: Identifiable { let id: String }
  private var source: String { MarkdownDocument.renderable(text) }
  var body: some View {
    Group {
      if let blocks, MarkdownDocument.oversized(blocks) {
        // One block taller than many screens (a huge code listing) is read in the scrolling source view.
        FileTextPreview(text: text, code: true)
      } else if let blocks, blocks.isEmpty {
        Text("Documento vazio").foregroundStyle(theme.color(.textSecondary))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let blocks {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(MarkdownDocument.chunks(blocks)) { chunk in
              ResponseBlocks(blocks: chunk.blocks, source: source, messageID: "file-preview", partID: path,
                rasters: rasters, openNote: { note = Note(id: $0) })
                .padding(.top, chunk.spacing)
            }
          }
          .padding(16)
        }
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .sheet(item: $note) { note in
      if let block = blocks?.first(where: { if case .footnote(let id, _) = $0.kind { id == note.id } else { false } }) {
        NavigationStack {
          ScrollView {
            ResponseBlocks(blocks: block.children, source: source, messageID: "file-preview", partID: path,
              rasters: rasters, openNote: { self.note = Note(id: $0) }).padding(20)
          }
          .background(theme.color(.background))
          .navigationTitle("Nota de rodapé").navigationBarTitleDisplayMode(.inline)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { self.note = nil } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
      }
    }
    .toastOverlay(toast)
    .environment(toast)
    // Prose joins inside each slice, so a selection spans its paragraphs, headings and lists.
    .environment(\.responseProse, true)
    .environment(\.responseFilesStable, true)
    // Relative images and links belong to the file's directory, not the Session's.
    .environment(\.conversationImages, ConversationImageContext(client: context.client,
      directory: URL(fileURLWithPath: path).deletingLastPathComponent().path, sessionID: context.sessionID))
    // A file is not a chat message: no quote, comment or side-question actions.
    .environment(\.responseSelection, nil)
    .environment(\.responseSelectionChanged, nil)
    .environment(\.conversationQuotes, ConversationQuoteContext())
    .environment(\.conversationSearch, ConversationSearchHighlight())
    .task(id: "\(theme.id)\n\(text)") {
      let parsed = await ResponseMarkdownCache.shared.parse(source)
      let images = await ResponseFormulas.shared.rasters(parsed, theme: theme.id, color: theme.value(.markdownBody), scale: scale)
      guard !Task.isCancelled else { return }
      rasters = images
      blocks = parsed
    }
  }
}

/// iOS has no native SVG view and Quick Look does not draw it. As an `<img>`, the SVG cannot run scripts or load
/// anything external; JavaScript is off and the CSP allows only the inline data URL.
private struct FileSVGPreview: UIViewRepresentable {
  let file: URL
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.isOpaque = false
    view.backgroundColor = .clear
    view.scrollView.backgroundColor = .clear
    view.navigationDelegate = context.coordinator
    let encoded = ((try? Data(contentsOf: file)) ?? Data()).base64EncodedString()
    view.loadHTMLString("""
      <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=5, user-scalable=yes"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;"><style>html,body{margin:0;height:100%;background:transparent}body{display:flex;align-items:center;justify-content:center}img{max-width:100%;max-height:100%;object-fit:contain}</style></head><body><img alt="" src="data:image/svg+xml;base64,\(encoded)"></body></html>
      """, baseURL: nil)
    return view
  }
  func updateUIView(_ view: WKWebView, context: Context) {}
  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.navigationDelegate = nil
  }
  final class Coordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
      navigationAction.request.url?.scheme == "about" ? .allow : .cancel
    }
  }
}

private struct FilePDFPreview: UIViewRepresentable {
  let file: URL
  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.backgroundColor = .clear
    view.document = PDFDocument(url: file)
    return view
  }
  func updateUIView(_ view: PDFView, context: Context) {}
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

/// Horizontal swipe between sibling files. It never starts on a control, inside a zoomed image or on any other
/// content that can still scroll horizontally, so panning keeps priority over paging.
private struct FilePageSwipe: UIGestureRecognizerRepresentable {
  let previous: Bool
  let next: Bool
  let page: (Int) -> Void
  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.maximumNumberOfTouches = 1
    pan.delegate = context.coordinator
    return pan
  }
  func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
    context.coordinator.previous = previous
    context.coordinator.next = next
  }
  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    guard recognizer.state == .ended, let view = recognizer.view else { return }
    let distance = recognizer.translation(in: view).x
    let speed = recognizer.velocity(in: view).x
    guard abs(distance) > 60 || abs(speed) > 600 && abs(distance) > 20 else { return }
    let step = distance < 0 ? 1 : -1
    if step == 1 ? next : previous { page(step) }
  }
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var previous = false
    var next = false
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
      let velocity = pan.velocity(in: view)
      guard abs(velocity.x) > abs(velocity.y) * 1.5, velocity.x < 0 ? next : previous else { return false }
      var current = view.hitTest(pan.location(in: view), with: nil)
      while let candidate = current, candidate !== view {
        if candidate is UIControl { return false }
        if let zoom = candidate as? ImageZoomScrollView, !zoom.pageable { return false }
        // Dragging a selection handle is not a page swipe.
        if let text = candidate as? UITextView, text.selectedRange.length > 0 { return false }
        if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled,
          scroll.contentSize.width + scroll.adjustedContentInset.left + scroll.adjustedContentInset.right > scroll.bounds.width + 1 {
          return false
        }
        current = candidate.superview
      }
      return true
    }
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
  }
}

struct FileShareSheet: UIViewControllerRepresentable {
  let file: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [file], applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
