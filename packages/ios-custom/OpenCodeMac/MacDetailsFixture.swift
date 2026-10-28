#if DEBUG
import Foundation
import AppKit
import OpenCodeKit

enum MacDetailsFixture {
  static let mode = MacFixture.value("-OpenCodeMacDetailCase")
  static let source = """
    ## Citações no Mac

    O comentário acompanha o trecho escolhido, com **seleção nativa** e um número sobrescrito. O texto continua usando toda a largura da resposta.

    Cada janela tem sua própria sessão, seus arquivos e sua posição de leitura. Abrir outra janela não interrompe o trabalho que já está em andamento.

    ```swift
    let janela = "independente"
    ```
    """
  static var quotes: [ChatQuote] {
    ["seleção nativa", "Cada janela tem sua própria sessão"].enumerated().map { number, text in
      let range = (source as NSString).range(of: text)
      return ChatQuote(id: "mac-details-\(number)", messageID: "msg_details_answer", partID: "msg_details_answer:text:0",
        text: text, comment: number == 0 ? "Manter a seleção e a cópia sem os números da decoração." : "Restaurar o estado de cada janela.",
        anchor: .init(start: range.location, end: NSMaxRange(range), exact: text, coordinate: "source"))
    }
  }
  static func messages(now: Double) -> [String] {
    func encoded(_ text: String) -> String { String(decoding: try! JSONEncoder().encode(text), as: UTF8.self) }
    let prompt = mode == "bubble"
      ? (1...34).map { "\($0). Esta é uma mensagem longa: quero ler todos os detalhes sem perder os anexos nem a hora de envio." }.joined(separator: "\n")
      : "Confira as citações e o estado independente das janelas."
    let tool = mode == "shell" ? #",{"type":"tool","id":"part_details_shell","name":"shell","state":{"status":"running","input":{"command":"swift test"},"metadata":{"shellID":"shl_test"}},"time":{"created":\#(now),"ran":\#(now)}}"# : ""
    return [
      #"{"id":"msg_details_prompt","type":"user","text":\#(encoded(prompt)),"time":{"created":\#(now - 1000)},"files":[{"type":"file","name":"requisitos.txt","mime":"text/plain","url":"file:///requisitos.txt"}]}"#,
      #"{"id":"msg_details_answer","type":"assistant","agent":"build","time":{"created":\#(now)},"content":[{"type":"text","id":"part_details_answer","text":\#(encoded(source))}\#(tool)]}"#,
    ]
  }

  /// Exercises production views even on a locked desktop: native selection, nested scrolling and row-local output.
  @MainActor static func verify(window: NSWindow, runtime: MacWindowRuntime, theme: AppTheme, folder: String) async {
    guard let mode else { return }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let all = window.contentView.map(views) ?? []
    if mode == "quotes" || mode == "details" {
      let text = all.compactMap { $0 as? MacResponseTextView }.first { $0.string.contains("Citações no Mac") }
      guard let text, quotes.allSatisfy({ text.string.contains($0.text + String(($0.id == "mac-details-0" ? 1 : 2))) }) else {
        print("MacDetails failed: números ausentes"); exit(1)
      }
      text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
      text.copy(nil)
      guard NSPasteboard.general.string(forType: .string)?.contains("seleção nativa1") == false else {
        print("MacDetails failed: número copiado"); exit(1)
      }
      text.setSelectedRange(NSRange(location: 0, length: 0))
      if mode == "details" {
        guard let marker = text.accessibilityChildren()?.compactMap({ $0 as? NSAccessibilityElement }).first,
          marker.accessibilityPerformPress() else { print("MacDetails failed: selo sem ação"); exit(1) }
        try? await Task.sleep(for: .milliseconds(600))
        guard window.attachedSheet != nil else { print("MacDetails failed: folha não abriu"); exit(1) }
      }
    }
    if mode == "bubble" {
      guard let scroll = all.compactMap({ $0 as? NSScrollView }).first(where: { $0.accessibilityIdentifier() == "user-bubble-scroll" }),
        let document = scroll.documentView, document.frame.height > scroll.contentSize.height + 100 else {
        print("MacDetails failed: bolha sem rolagem interna"); exit(1)
      }
      MacCapture.shot(window, theme: theme, to: folder + "/bubble-inicio.png")
      scroll.contentView.scroll(to: CGPoint(x: 0, y: document.frame.height - scroll.contentSize.height))
      scroll.reflectScrolledClipView(scroll.contentView)
      guard scroll.contentView.bounds.minY > 100 else { print("MacDetails failed: bolha não rolou"); exit(1) }
    }
    if mode == "shell" {
      let memory = runtime.memory(MacFixture.rootID)
      let before = memory.output("activity:detail:part_details_shell")
      let revision = runtime.store?.liveConversation(MacFixture.rootID)?.revision
      MacCapture.shot(window, theme: theme, to: folder + "/shell-antes.png")
      try? await Task.sleep(for: .seconds(3))
      let after = memory.output("activity:detail:part_details_shell")
      guard before != nil, after != before, revision == runtime.store?.liveConversation(MacFixture.rootID)?.revision else {
        print("MacDetails failed: saída não atualizou isoladamente"); exit(1)
      }
    }
    print("MacDetails \(mode) ok")
    fflush(stdout)
  }
}
#endif
