import Foundation
import JavaScriptCore
import OpenCodeKit

actor ResponseEngines {
  static let shared = ResponseEngines()
  private var context: JSContext?
  private let diagrams = NSCache<NSString, NSString>()

  init() {
    diagrams.countLimit = 32
    diagrams.totalCostLimit = 8 * 1024 * 1024
  }

  func highlight(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
    blocks.map { block in
      var result = block
      result.children = highlight(block.children)
      guard case .code(let name) = block.kind,
        let language = MarkdownCodeProjection.language(name),
        block.text.utf16.count <= 200_000, block.text.split(separator: "\n").count <= 1200,
        let engine = engine(),
        let json = engine.objectForKeyedSubscript("openCodeHighlight")?.call(withArguments: [block.text, language])?.toString(),
        let data = json.data(using: .utf8), let tokens = try? JSONDecoder().decode([Token].self, from: data),
        tokens.map(\.text).joined() == block.text
      else { return result }
      let offsets = block.runs.flatMap(\.offsets)
      var cursor = 0
      result.runs = tokens.map { token in
        defer { cursor += token.text.utf16.count }
        var run = block.runs[0]
        run.text = token.text
        run.offsets = Array(offsets[cursor..<cursor + token.text.utf16.count])
        run.syntax = MarkdownCodeProjection.syntax(token.style)
        run.strong = token.style.contains("hljs-strong")
        run.emphasis = token.style.contains("hljs-emphasis")
        return run
      }
      return result
    }
  }

  func diagram(_ source: String) -> String? {
    if let svg = diagrams.object(forKey: source as NSString) { return svg as String }
    guard source.utf16.count <= 20_000, source.split(separator: "\n").count <= 400,
      let context = engine() else { return nil }
    context.exception = nil
    guard let svg = context.objectForKeyedSubscript("openCodeMermaid")?.call(withArguments: [source])?.toString(),
      context.exception == nil, svg.hasPrefix("<svg") else { return nil }
    diagrams.setObject(svg as NSString, forKey: source as NSString, cost: svg.utf16.count * 2)
    return svg
  }

  func diagramText(_ source: String) -> String? {
    let key = "ascii:" + source
    if let text = diagrams.object(forKey: key as NSString) { return text as String }
    guard source.utf16.count <= 20_000, source.split(separator: "\n").count <= 400,
      let context = engine() else { return nil }
    context.exception = nil
    guard let text = context.objectForKeyedSubscript("openCodeMermaidASCII")?.call(withArguments: [source])?.toString(),
      context.exception == nil, !text.isEmpty, text.utf16.count <= 200_000 else { return nil }
    diagrams.setObject(text as NSString, forKey: key as NSString, cost: text.utf16.count * 2)
    return text
  }

  private func engine() -> JSContext? {
    if let context { return context }
    guard let url = Bundle.main.url(forResource: "markdown-engines", withExtension: "js", subdirectory: "Markdown/dist")
      ?? Bundle.main.url(forResource: "markdown-engines", withExtension: "js", subdirectory: "Markdown")
      ?? Bundle.main.url(forResource: "markdown-engines", withExtension: "js"),
      let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return nil }
    // ELK's synchronous adapter needs the Node-style global and its zero-delay
    // bootstrap callbacks. This context never runs application or model code.
    context.evaluateScript("globalThis.global = globalThis; globalThis.setTimeout = (fn) => { fn(); return 0; }; globalThis.clearTimeout = () => {};")
    let decode: @convention(block) (String) -> String = {
      Data(base64Encoded: $0).flatMap { String(data: $0, encoding: .isoLatin1) } ?? ""
    }
    context.setObject(decode, forKeyedSubscript: "atob" as NSString)
    context.evaluateScript(script)
    guard context.exception == nil else { return nil }
    self.context = context
    return context
  }

  private struct Token: Decodable {
    let text: String
    let style: String
  }
}
