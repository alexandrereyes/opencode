import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ResponseDiagram: View {
  @Environment(\.appTheme) private var theme
  @Environment(ToastCenter.self) private var toast
  @Environment(\.responseSelectionChanged) private var selection
  @State private var svg: String?
  @State private var failed = false
  @State private var showSource = false
  @State private var showText = false
  @State private var ascii: String?
  @State private var fullscreen = false
  @State private var exporting = false
  @State private var requested = false
  @State private var viewer = ResponseDiagramViewer()
  let block: MarkdownBlock
  let messageID: String
  let partID: String

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if showSource || failed && !showText {
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              if failed { Text("Não foi possível desenhar este diagrama. O código permanece disponível.").font(.system(size: 13)).foregroundStyle(theme.color(.textSecondary)) }
              SelectableResponseText(block: block, messageID: messageID, partID: partID, theme: theme,
                selectionChanged: selection?.selected, gutter: true)
            }.padding(10)
          }
        } else if showText {
          if let ascii {
            ScrollView([.horizontal, .vertical]) {
              SelectableResponseText(block: textBlock(ascii), messageID: messageID, partID: partID, theme: theme,
                selectionChanged: selection?.selected, wrap: false)
                .frame(width: textWidth(ascii)).padding(10)
            }
          } else { ProgressView("Preparando diagrama em texto…").font(.system(size: 14)) }
        } else if let svg {
          ResponseSVG(svg: svg, theme: theme, viewer: viewer)
        } else {
          ProgressView("Preparando diagrama…").font(.system(size: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(height: 384)
      HStack(spacing: 0) {
        Menu {
          Button("Mostrar diagrama") { showSource = false; showText = false }
          Button("Mostrar código Mermaid") { showSource = true; showText = false }
          Button("Mostrar diagrama em texto") { showSource = false; showText = true }
        } label: { Image(systemName: showSource ? "chevron.left.forwardslash.chevron.right" : showText ? "text.alignleft" : "flowchart") }
        .accessibilityLabel("Formato do diagrama")
        Spacer(minLength: 0)
        if svg != nil && !showSource && !showText {
          Button { viewer.zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Ampliar diagrama")
          Button { viewer.zoom(0.8) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Reduzir diagrama")
          Button { viewer.reset() } label: { Image(systemName: "arrow.counterclockwise") }.accessibilityLabel("Redefinir diagrama")
          Button { fullscreen = true; selection?.selected() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Abrir diagrama em tela cheia")
          Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Exportar SVG")
        }
        Button {
          UIPasteboard.general.string = showText ? ascii ?? block.text : block.text
          Haptics.play(.selection)
          toast.show(showText ? "Diagrama em texto copiado" : "Código Mermaid copiado")
        } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel(showText ? "Copiar diagrama em texto" : "Copiar Mermaid")
      }
      .buttonStyle(MarkdownToolbarButton())
      .foregroundStyle(theme.color(.codeHeaderText))
    }
    .padding(8)
    .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 12))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color(.codeBorder).opacity(0.8), lineWidth: 1) }
    .overlay(alignment: .top) {
      ResponseDiagramVisibility { requested = true }.frame(height: 1).allowsHitTesting(false)
    }
    .task(id: requested ? block.text : nil) {
      guard requested else { return }
      let value = await ResponseEngines.shared.diagram(block.text.trimmingCharacters(in: .newlines))
      guard !Task.isCancelled else { return }
      svg = value
      failed = value == nil
    }
    .task(id: requested && showText ? block.text : nil) {
      guard requested, showText else { return }
      let value = await ResponseEngines.shared.diagramText(block.text.trimmingCharacters(in: .newlines))
      guard !Task.isCancelled else { return }
      ascii = value ?? block.text
    }
    .sheet(isPresented: $fullscreen) {
      if let svg { ResponseDiagramFullscreen(svg: svg) }
    }
    .fileExporter(isPresented: $exporting, document: ResponseTextDocument(text: svg.map { ResponseDiagramTheme.export($0, theme: theme) } ?? ""), contentType: .svg, defaultFilename: "diagrama.svg") {
      if case .success = $0 { toast.show("Diagrama exportado") }
    }
  }
  private func textBlock(_ text: String) -> MarkdownBlock {
    var result = block
    if var run = block.runs.first {
      run.text = text
      run.offsets = Array(repeating: nil, count: text.utf16.count)
      run.syntax = nil
      result.runs = [run]
    }
    return result
  }
  private func textWidth(_ text: String) -> CGFloat {
    max(120, text.components(separatedBy: "\n").map {
      ($0 as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)]).width
    }.max() ?? 120)
  }
}

@MainActor private final class ResponseDiagramViewer {
  weak var webView: WKWebView?
  func zoom(_ factor: CGFloat) {
    guard let scroll = webView?.scrollView else { return }
    scroll.setZoomScale(min(4, max(0.25, scroll.zoomScale * factor)), animated: false)
  }
  func reset() {
    webView?.scrollView.setZoomScale(1, animated: false)
    webView?.scrollView.setContentOffset(.zero, animated: false)
  }
}

private struct ResponseDiagramFullscreen: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var viewer = ResponseDiagramViewer()
  let svg: String
  var body: some View {
    NavigationStack {
      ResponseSVG(svg: svg, theme: theme, viewer: viewer)
        .background(theme.color(.diagramBackground))
        .navigationTitle("Diagrama").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
    }
  }
}

private struct ResponseSVG: UIViewRepresentable {
  let svg: String
  let theme: AppTheme
  let viewer: ResponseDiagramViewer
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = ResponseDiagramRuntime.dataStore
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.isOpaque = false
    view.backgroundColor = theme.uiColor(.diagramBackground).withAlphaComponent(0)
    view.scrollView.backgroundColor = theme.uiColor(.diagramBackground).withAlphaComponent(0)
    view.navigationDelegate = context.coordinator
    view.accessibilityLabel = "Diagrama Mermaid. Use dois dedos para ampliar."
    viewer.webView = view
    return view
  }
  func updateUIView(_ view: WKWebView, context: Context) {
    viewer.webView = view
    let identity = theme.id + svg
    guard context.coordinator.identity != identity else { return }
    context.coordinator.identity = identity
    let colors = ResponseDiagramTheme.css(theme)
    view.loadHTMLString("""
      <!doctype html><html lang="pt-BR"><head><meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=0.25, maximum-scale=4, user-scalable=yes"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;"><style>:root{\(colors)}html,body{margin:0;width:100%;height:100%;background:transparent}svg{display:block;width:100%;height:100%;}</style></head><body>\(svg)</body></html>
      """, baseURL: nil)
  }
  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.navigationDelegate = nil
  }
  final class Coordinator: NSObject, WKNavigationDelegate {
    var identity = ""
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      webView.scrollView.minimumZoomScale = 0.25
      webView.scrollView.maximumZoomScale = 4
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
      navigationAction.request.url?.scheme == "about" ? .allow : .cancel
    }
  }
}

enum ResponseDiagramTheme {
  private static let roles: [(String, ThemeRole)] = [
    ("background", .diagramBackground), ("text", .diagramText), ("line", .diagramLine),
    ("accent", .diagramAccent), ("muted", .diagramMuted), ("surface", .diagramSurface), ("border", .diagramBorder),
  ]
  static func css(_ theme: AppTheme) -> String {
    roles.map { "--diagram-\($0.0):\(color(theme.value($0.1)));" }.joined()
  }
  static func export(_ svg: String, theme: AppTheme) -> String {
    roles.reduce(svg) { result, entry in
      result.replacingOccurrences(of: "var(--diagram-\(entry.0))", with: color(theme.value(entry.1)))
    }
  }
  private static func color(_ value: ThemeColor) -> String {
    "rgba(\(Int(value.red * 255)),\(Int(value.green * 255)),\(Int(value.blue * 255)),\(value.opacity))"
  }
}

@MainActor private enum ResponseDiagramRuntime {
  static let dataStore = WKWebsiteDataStore.nonPersistent()
}

private struct ResponseDiagramVisibility: UIViewRepresentable {
  let visible: () -> Void
  func makeUIView(context: Context) -> Probe { Probe() }
  func updateUIView(_ view: Probe, context: Context) { view.visible = visible }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: Probe, context: Context) -> CGSize? {
    CGSize(width: max(1, proposal.width ?? 1), height: 1)
  }
  static func dismantleUIView(_ view: Probe, coordinator: Void) { view.observation = nil }
  final class Probe: UIView {
    var visible: (() -> Void)?
    var observation: NSKeyValueObservation?
    private var reported = false
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { observation = nil }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      guard !reported, window != nil else { return }
      if observation == nil, let scroll = scrollView {
        observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
          // UIKit's scroll offset is mutated on the main actor; no delegate is replaced.
          MainActor.assumeIsolated { self?.check() }
        }
      }
      check()
    }
    private var scrollView: UIScrollView? {
      var parent = superview
      while let view = parent {
        if let scroll = view as? UIScrollView { return scroll }
        parent = view.superview
      }
      return nil
    }
    private func check() {
      guard !reported, bounds.width > 0, let window, let scroll = scrollView else { return }
      let top = convert(bounds, to: window)
      let card = CGRect(x: top.minX, y: top.minY, width: top.width, height: 384)
      guard card.intersection(scroll.convert(scroll.bounds, to: window)).height >= 96 else { return }
      reported = true
      observation = nil
      Task { @MainActor [weak self] in self?.visible?() }
    }
  }
}
