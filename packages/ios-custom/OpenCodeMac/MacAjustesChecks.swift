#if DEBUG
import AppKit
import OpenCodeKit
import SwiftUI

/// Offline checks of the adjustment round (A1–A20) on the production views, driven through AppKit events in the
/// closed fixture: `-OpenCodeMacAjustes composer|question|quote|image|archived|numbers|width|dictation`. Each
/// writes its pictures (`<name>-<step>.png`) and prints `MacAjustes <mode> ok`, or exits 1 with the failure.
/// The clipboard is restored after the image checks.
@MainActor enum MacAjustesChecks {
  nonisolated static let mode = MacFixture.value("-OpenCodeMacAjustes")

  struct Failure: Error, CustomStringConvertible { let description: String }

  /// The fake recorder of the dictation checks: no microphone, the fixture's transcript.
  static func prepare(_ draft: ConversationDraft) {
    guard mode == "dictation" else { return }
    let transcription = TranscriptionController(source: DictationFixtureSource(), engine: DictationFixtureEngine(),
      monitorsNetwork: false)
    draft.recordingFactory = {
      VoiceRecordingComposer(file: $0, capture: DictationFixtureCapture(), transcription: transcription)
    }
  }

  private static var started = false

  /// Once per launch: a second window (one SwiftUI restores and one the capture opens) would drive the same views.
  static func run(window: NSWindow, runtime: MacWindowRuntime, theme: AppTheme, folder: String) async {
    guard let mode, !started else { return }
    started = true
    func shot(_ step: String) { MacCapture.shot(window, theme: theme, to: folder + "/\(MacCapture.name)-\(step).png") }
    do {
      switch mode {
      case "composer": try await composer(window: window, runtime: runtime, shot: shot)
      case "question": try await question(window: window, runtime: runtime, shot: shot)
      case "quote": try await quote(window: window, runtime: runtime, shot: shot)
      case "image": try await image(window: window, shot: shot)
      case "archived": try await archived(window: window, shot: shot)
      case "numbers": try await numbers(window: window, runtime: runtime)
      case "width": try await width(window: window, runtime: runtime, shot: shot)
      case "dictation": try await dictation(window: window, runtime: runtime, shot: shot)
      case "jump": try await jump(window: window, runtime: runtime, shot: shot)
      case "master": try await master(window: window, runtime: runtime, shot: shot)
      default: throw Failure(description: "modo desconhecido")
      }
      print("MacAjustes \(mode) ok")
      fflush(stdout)
    } catch {
      shot("falha")
      print("MacAjustes \(mode) failed: \(error) · app ativo \(NSApp.isActive) · janela principal \(window.isKeyWindow)")
      fflush(stdout)
      exit(1)
    }
  }

  // MARK: A1 — the composer's lines

  private static func composer(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    let conversation = try require(runtime.store?.liveConversation(MacFixture.rootID), "conversa")
    let draft = runtime.input(conversation).draft
    let input = try await wait("editor") { draft.input?.window != nil ? draft.input : nil }
    func set(_ text: NSAttributedString) async throws {
      draft.text = text
      draft.selection = NSRange(location: text.length, length: 0)
      draft.focused = true
      try await Task.sleep(for: .milliseconds(900))
    }
    func check(lines: Int, _ step: String) throws {
      let line = input.lineHeight
      let expected = min(CGFloat(lines), ComposerInputView.maximumLines) * line
      guard abs(input.frame.height - expected) < 0.5 else {
        throw Failure(description: "\(step): altura \(input.frame.height), esperada \(expected)")
      }
      // The first line is whole: nothing scrolled while everything fits, and its fragment starts at the top.
      if CGFloat(lines) <= ComposerInputView.maximumLines, input.contentView.bounds.minY != 0 {
        throw Failure(description: "\(step): rolado \(input.contentView.bounds.minY)")
      }
      // The text wraps at the field's own width.
      if let container = input.textView.textContainer, abs(container.size.width - input.textView.frame.width) > 0.5 {
        throw Failure(description: "\(step): quebra em \(container.size.width) num campo de \(input.textView.frame.width)")
      }
      if let manager = input.textView.layoutManager, manager.numberOfGlyphs > 0 {
        let first = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        guard first.minY == 0, abs(first.height - line) < 0.5 else {
          throw Failure(description: "\(step): primeira linha \(first)")
        }
      }
      print("MacAjustes composer \(step): altura \(input.frame.height) · topo \(input.contentView.bounds.minY)")
      shot(step)
    }
    try await set(NSAttributedString())
    try check(lines: 1, "vazio")
    try await set(NSAttributedString(string: "Está funcionando bem. Uma linha só, sem cortar o topo das letras: ÁÉÍÓÚ Ç ã."))
    try check(lines: 1, "uma-linha")
    try await set(NSAttributedString(string: "Primeira linha com acento: Ação\nSegunda linha\nTerceira linha"))
    try check(lines: 3, "tres-linhas")
    // Tokens on the first line, then text.
    let text = "@build @README.md revisa o texto do topo"
    let document = ComposerDocument(text: text, tokens: [
      .init(start: 0, end: 6, token: ComposerToken(kind: .agent, id: "build", text: "@build", value: "build")),
      .init(start: 7, end: 17, token: ComposerToken(kind: .file, id: "README.md", text: "@README.md",
        value: "/tmp/README.md")),
    ])
    try await set(document.attributed)
    guard input.textStorage.containsAttachments else { throw Failure(description: "tokens ausentes") }
    try check(lines: 1, "tokens")
    try await set(NSAttributedString(string: (1...12).map { "Linha \($0) de um texto longo" }.joined(separator: "\n")))
    try check(lines: 12, "rolagem")
    try await set(NSAttributedString())
  }

  // MARK: A3 — the question's own answer

  private static func question(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    let conversation = try require(runtime.store?.liveConversation(MacFixture.rootID), "conversa")
    // The card is the transcript's last item: bring the end into view whatever reading place was restored.
    let transcript = try await wait("transcrição") {
      runtime.memory(MacFixture.rootID).active.flatMap { $0.revealed ? $0 : nil }
    }
    transcript.scrollToLatest(animated: false)
    let field = try await wait("campo da pergunta") {
      views(window).compactMap { $0 as? MacReplyTextView }.first { $0.window != nil && $0.visibleRect.height > 4 }
    }
    // A real click (down and up) on the field focuses it.
    click(field, in: window)
    try await Task.sleep(for: .milliseconds(300))
    guard window.firstResponder === field else { throw Failure(description: "clique não focou o campo") }
    field.insertText("Capturas do Mac", replacementRange: field.selectedRange())
    // Shift+Return breaks the line; Return sends.
    window.sendEvent(key("\r", code: 36, flags: .shift, window: window))
    field.insertText("segunda linha", replacementRange: field.selectedRange())
    guard field.string == "Capturas do Mac\nsegunda linha" else {
      throw Failure(description: "Shift+Return: \(field.string.debugDescription)")
    }
    shot("digitado")
    let before = conversation.submitted
    window.sendEvent(key("\r", code: 36, window: window))
    try await wait("Return enviou") { conversation.submitted > before ? true : nil }
    // Esc leaves the field.
    click(field, in: window)
    try await Task.sleep(for: .milliseconds(200))
    window.sendEvent(key("\u{1b}", code: 53, window: window))
    guard window.firstResponder !== field else { throw Failure(description: "Esc não saiu do campo") }
    shot("enviado")
  }

  // MARK: A10 — a pending quote opens editing

  private static func quote(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    let text = try await wait("citação") {
      views(window).compactMap { $0 as? MacResponseTextView }.first { $0.string.contains("Citações no Mac") }
    }
    func open() async throws -> NSWindow {
      guard let marker = text.accessibilityChildren()?.compactMap({ $0 as? NSAccessibilityElement }).first,
        marker.accessibilityPerformPress() else { throw Failure(description: "selo sem ação") }
      return try await wait("folha") { window.attachedSheet }
    }
    var sheet = try await open()
    let editor = try await wait("foco no comentário") { sheet.firstResponder as? ComposerTextNSView }
    shot("aberta")
    editor.insertText(" Ajustado.", replacementRange: editor.selectedRange())
    sheet.sendEvent(key("\r", code: 36, window: sheet))
    try await wait("Return concluiu") { window.attachedSheet == nil ? true : nil }
    let conversation = try require(runtime.store?.liveConversation(MacFixture.rootID), "conversa")
    let draft = runtime.input(conversation).draft
    try await wait("comentário salvo") { draft.quotes.contains { $0.comment.hasSuffix("Ajustado.") } ? true : nil }
    sheet = try await open()
    let again = try await wait("foco de novo") { sheet.firstResponder as? ComposerTextNSView }
    sheet.sendEvent(key("\u{1b}", code: 53, window: sheet))
    _ = again
    try await wait("Esc fechou") { window.attachedSheet == nil ? true : nil }
  }

  // MARK: A14 — copying and dragging images

  static var sample: CGImage? {
    guard let data = MacFixturePictures.make()["res_chrome"].flatMap({ Data(base64Encoded: $0) }) else { return nil }
    return NSBitmapImageRep(data: data)?.cgImage
  }

  private static func image(window: NSWindow, shot: (String) -> Void) async throws {
    let saved = NSPasteboard.general.pasteboardItems?.map { item in
      item.types.map { ($0, item.data(forType: $0)) }
    } ?? []
    defer {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects(saved.map { types in
        let item = NSPasteboardItem()
        for (type, data) in types { if let data { item.setData(data, forType: type) } }
        return item
      })
    }
    let sheet = try await wait("visualizador") { window.attachedSheet }
    shot("visualizador")
    NSPasteboard.general.clearContents()
    let event = key("c", code: 8, flags: .command, window: sheet)
    guard sheet.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true else {
      throw Failure(description: "⌘C não tratado")
    }
    try await wait("imagem copiada") { NSPasteboard.general.data(forType: .png) != nil ? true : nil }
    let copied = try require(NSPasteboard.general.data(forType: .png).flatMap(NSBitmapImageRep.init(data:)), "png")
    guard copied.pixelsWide > 100, NSPasteboard.general.data(forType: .tiff) != nil else {
      throw Failure(description: "cópia sem PNG/TIFF utilizáveis")
    }
    let provider = MacImageTransfer.provider(try require(sample, "amostra"), name: "Personagens.png")
    guard provider.suggestedName == "Personagens.png", provider.hasItemConformingToTypeIdentifier("public.file-url") else {
      throw Failure(description: "arrastar sem arquivo PNG")
    }
  }

  // MARK: A19 — searching Arquivadas

  private static func archived(window: NSWindow, shot: (String) -> Void) async throws {
    let sheet = try await wait("Arquivadas") { window.attachedSheet }
    let field = try await wait("campo com foco") { sheet.firstResponder as? NSTextView }
    shot("aberta")
    func rows() -> Int { views(sheet).compactMap { $0 as? NSTableView }.first?.numberOfRows ?? -1 }
    let all = rows()
    // Case and accents ignored: "PROTOTIPO" finds "protótipo".
    field.insertText("PROTOTIPO", replacementRange: field.selectedRange())
    try await wait("um resultado") { rows() == 1 ? true : nil }
    shot("busca")
    field.selectAll(nil)
    field.insertText("nada parecido", replacementRange: field.selectedRange())
    try await wait("nenhum resultado") { rows() == 0 ? true : nil }
    shot("sem-resultado")
    // ⌘F returns the focus to the field.
    sheet.makeFirstResponder(nil)
    let find = key("f", code: 3, flags: .command, window: sheet)
    _ = sheet.performKeyEquivalent(with: find)
    try await wait("⌘F focou") { sheet.firstResponder is NSTextView ? true : nil }
    print("MacAjustes archived: \(all) arquivada(s), 1 com PROTOTIPO, 0 sem resultado, ⌘F foca")
  }

  // MARK: A18 — ⌘1…⌘9

  private static func numbers(window: NSWindow, runtime: MacWindowRuntime) async throws {
    let store = try require(runtime.store, "sessões")
    let expected = SessionNavigation.numbered(
      SessionSections.group(store.filtered, chats: store.chatsSelected, now: .now),
      collapse: SessionSectionCollapse(rawValue: UserDefaults.standard.string(forKey: "OpenCodeSessionSections") ?? "")
        ?? SessionSectionCollapse())
    guard expected.count >= 2 else { throw Failure(description: "poucas sessões") }
    window.makeKeyAndOrderFront(nil)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    let menu = try await wait("menu Ir") {
      NSApp.mainMenu?.items.first { $0.title == "Ir" }?.submenu.flatMap { menu in
        // SwiftUI fills a command menu when it is about to open.
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.contains { $0.keyEquivalent == "1" } ? menu : nil
      }
    }
    let numbered = menu.items.filter { $0.keyEquivalentModifierMask == .command && Int($0.keyEquivalent) != nil }
    guard numbered.map(\.title) == expected.map(\.session.displayTitle),
      numbered.map(\.keyEquivalent) == (1...expected.count).map(String.init) else {
      throw Failure(description: "menu \(numbered.map { $0.keyEquivalent + " " + $0.title })")
    }
    let event = key("2", code: 19, flags: .command, window: window)
    _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
    try await wait("⌘2 abriu a segunda") { runtime.selection.sessionID == expected[1].id ? true : nil }
    print("MacAjustes numbers: " + numbered.map { "⌘" + $0.keyEquivalent + " " + $0.title }.joined(separator: " · "))
  }

  // MARK: A2 — Contexto's width

  private static func width(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    for requested in [1_500.0, 700.0] {
      runtime.contextWidth = requested
      try await Task.sleep(for: .seconds(1.5))
      let windowWidth = window.frame.width
      let context = runtime.measuredContextWidth
      let chat = runtime.measuredChatWidth
      print("MacAjustes width: pedido \(Int(requested)) · janela \(Int(windowWidth)) · Contexto \(Int(context)) · chat \(Int(chat))")
      guard context <= windowWidth * DesktopWindowState.maximumContextShare + 1, chat >= 459,
        context >= min(requested, windowWidth * DesktopWindowState.maximumContextShare) - 1 || chat < 461 else {
        throw Failure(description: "Contexto \(context) / chat \(chat) na janela \(windowWidth)")
      }
      shot("contexto-\(Int(requested))")
    }
  }

  // MARK: A8 — dictation in place and the right Option key

  private static func dictation(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    let conversation = try require(runtime.store?.liveConversation(MacFixture.rootID), "conversa")
    let draft = runtime.input(conversation).draft
    _ = try await wait("editor") { draft.input?.window != nil ? true : nil }
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    func option(_ down: Bool, left: Bool = false) {
      // NX_DEVICERALTKEYMASK (0x40) or NX_DEVICELALTKEYMASK (0x20) with the Option flag, like the hardware sends.
      let flags = down ? NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | (left ? 0x20 : 0x40)) : []
      if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: left ? 58 : 61) {
        NSApp.postEvent(event, atStart: false)
      }
    }
    // The left Option key does nothing.
    option(true, left: true); option(false, left: true)
    try await Task.sleep(for: .milliseconds(600))
    guard !draft.recording.visible else { throw Failure(description: "Option esquerda gravou") }
    // Right Option used as a modifier (⌥ + a letter) does not record.
    option(true)
    NSApp.postEvent(key("a", code: 0, flags: .option, window: window), atStart: false)
    option(false)
    try await Task.sleep(for: .milliseconds(600))
    guard !draft.recording.visible else { throw Failure(description: "⌥ como modificador gravou") }
    // A tap records hands-free; the next tap stops and the text lands in the composer, with no review sheet.
    option(true); option(false)
    try await wait("toque gravou") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.2))
    shot("gravando")
    option(true); option(false)
    try await wait("transcrito no compositor", timeout: 20) {
      draft.text.string.contains("Confira as sessões") ? true : nil
    }
    try await Task.sleep(for: .milliseconds(600))
    guard window.attachedSheet == nil, !draft.expanded else { throw Failure(description: "abriu a folha de revisão") }
    // The transcript is whole in the field: it grew to every line it needs.
    let input = try require(draft.input, "editor")
    let needed = min(input.contentHeight(width: input.contentView.bounds.width), input.lineHeight * ComposerInputView.maximumLines)
    let wrap = input.textView.textContainer?.size.width ?? 0
    print("MacAjustes dictation: campo \(input.frame.height) · texto \(needed) · quebra \(wrap)/\(input.textView.frame.width)")
    guard abs(input.frame.height - needed) < 0.5, input.contentView.bounds.minY == 0,
      abs(wrap - input.textView.frame.width) < 0.5 else {
      throw Failure(description: "campo \(input.frame.height) para \(needed), rolado \(input.contentView.bounds.minY)")
    }
    shot("transcrito")
    // Held: records while down and stops on release.
    draft.text = NSAttributedString()
    option(true)
    try await wait("segurar gravou") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.4))
    option(false)
    try await wait("soltar transcreveu", timeout: 20) {
      draft.text.string.contains("Confira as sessões") ? true : nil
    }
    guard !draft.recording.capturing else { throw Failure(description: "continuou gravando após soltar") }
  }

  // MARK: A13 — ↓ beside the text

  private static func jump(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    let memory = runtime.memory(MacFixture.rootID)
    let transcript = try await wait("transcrição") { memory.active?.revealed == true ? memory.active : nil }
    transcript.reveal(messageID: "msg_root_1")
    try await wait("↓ visível") { memory.state.jumpToLatest ? true : nil }
    // A narrow chat (Contexto open): on the composer's top right corner.
    try await Task.sleep(for: .seconds(1))
    let corner = accessible("jump-to-latest", in: window)
    shot("canto-do-compositor")
    // Contexto hidden: the margin right of the reading column.
    runtime.contextVisible = false
    try await Task.sleep(for: .seconds(1.5))
    transcript.reveal(messageID: "msg_root_1")
    try await wait("↓ visível na margem") { memory.state.jumpToLatest ? true : nil }
    try await Task.sleep(for: .seconds(1))
    let margin = accessible("jump-to-latest", in: window)
    shot("margem")
    print("MacAjustes jump: compositor \(corner.map { NSStringFromRect($0.accessibilityFrame()) } ?? "?") · margem \(margin.map { NSStringFromRect($0.accessibilityFrame()) } ?? "?")")
  }

  // MARK: A17 — the master's trash

  private static func master(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    runtime.selection = MacSelection(sessionID: MacFixture.rootID, master: true)
    try await Task.sleep(for: .seconds(1.5))
    print("MacAjustes master: lixeira acessível \(accessible("master-trash", in: window) != nil)")
    shot("lixeira")
  }

  /// A SwiftUI control by its accessibility identifier, anywhere in the window (title bar included).
  private static func accessible(_ identifier: String, in window: NSWindow) -> NSAccessibilityElementProtocol? {
    func search(_ element: Any, depth: Int) -> NSAccessibilityElementProtocol? {
      guard depth < 40, let element = element as? NSAccessibilityElementProtocol & NSObjectProtocol else { return nil }
      if (element as? NSAccessibilityProtocol)?.accessibilityIdentifier() == identifier { return element }
      let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
      return children.lazy.compactMap { search($0, depth: depth + 1) }.first
    }
    return search(window, depth: 0)
  }

  // MARK: Helpers

  private static func views(_ window: NSWindow) -> [NSView] {
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    return (window.contentView?.superview ?? window.contentView).map(all) ?? []
  }

  private static func click(_ view: NSView, in window: NSWindow) {
    let point = view.convert(CGPoint(x: min(30, view.bounds.midX), y: view.bounds.midY), to: nil)
    func mouse(_ type: NSEvent.EventType) -> NSEvent? {
      NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
    // The text view tracks the mouse until the release, which is already waiting in the queue.
    if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
    if let down = mouse(.leftMouseDown) { window.sendEvent(down) }
  }

  private static func key(_ character: String, code: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow)
    -> NSEvent
  {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
  }

  private static func require<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw Failure(description: "sem \(what)") }
    return value
  }

  @discardableResult
  private static func wait<T>(_ what: String, timeout: Double = 8, _ value: () -> T?) async throws -> T {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if let value = value() { return value }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure(description: "tempo esgotado: \(what)")
  }
}
#endif
