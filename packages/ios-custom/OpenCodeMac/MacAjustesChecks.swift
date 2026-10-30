#if DEBUG
import AppKit
import OpenCodeKit
import SwiftUI

/// Offline checks of the adjustment round (A1–A20) on the production views, driven through AppKit events in the
/// closed fixture: `-OpenCodeMacAjustes composer|question|quote|image|viewer|archived|numbers|width|dictation|divider|edge|markdown|arquivos|ampliar|progresso|contexto`. Each
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
  /// Modes that need the app in front: the Ir menu that SwiftUI fills only for the active app (`numbers`), the
  /// image viewer's context menu, which an inactive app may not open (`viewer`), and the dictation sheets'
  /// composers taking the recorded text (`dictation`). A background copy (`MacLaunch.background`) comes forward
  /// only for these, once its pictures are taken, and quits right after; its window stays off-screen.
  static let foreground: Set<String> = ["numbers", "viewer", "dictation"]
  /// `progresso`: the fixture server answers that the root's run ended (read off the main actor by the server).
  nonisolated(unsafe) static var progressEnded = false

  /// Once per launch: a second window (one SwiftUI restores and one the capture opens) would drive the same views.
  static func run(window: NSWindow, runtime: MacWindowRuntime, theme: AppTheme, folder: String) async {
    guard let mode, !started else { return }
    started = true
    func shot(_ step: String) { MacCapture.shot(window, theme: theme, to: folder + "/\(MacCapture.name)-\(step).png") }
    if MacLaunch.background, foreground.contains(mode) {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      try? await Task.sleep(for: .milliseconds(600))
    }
    do {
      switch mode {
      case "composer": try await composer(window: window, runtime: runtime, shot: shot)
      case "question": try await question(window: window, runtime: runtime, shot: shot)
      case "quote": try await quote(window: window, runtime: runtime, shot: shot)
      case "image": try await image(window: window, shot: shot)
      case "viewer": try await viewer(window: window, theme: theme, folder: folder)
      case "archived": try await archived(window: window, shot: shot)
      case "numbers": try await numbers(window: window, runtime: runtime)
      case "width": try await width(window: window, runtime: runtime, shot: shot)
      case "dictation": try await dictation(window: window, runtime: runtime, shot: shot)
      case "jump": try await jump(window: window, runtime: runtime, shot: shot)
      case "master": try await master(window: window, runtime: runtime, shot: shot)
      case "divider": try await divider(window: window, runtime: runtime)
      case "edge": try await edge(window: window, shot: shot)
      case "markdown": try await markdown(window: window, runtime: runtime, shot: shot)
      case "arquivos": try await arquivos(window: window, runtime: runtime, shot: shot)
      case "ampliar": try await ampliar(window: window, runtime: runtime, shot: shot)
      case "progresso": try await progresso(window: window, runtime: runtime, theme: theme, folder: folder, shot: shot)
      case "contexto": try await contexto(window: window, runtime: runtime, shot: shot)
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
    // The two questions' answer fields, top to bottom.
    let fields = try await wait("campos das perguntas") {
      let fields = views(window).compactMap { $0 as? ComposerTextNSView }.filter {
        $0.accessibilityIdentifier() == "question-reply" && $0.window != nil && $0.visibleRect.height > 4
      }.sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
      return fields.count == 2 ? fields : nil
    }
    let field = fields[0]
    // A real click (down and up) on the field focuses it.
    click(field, in: window)
    try await Task.sleep(for: .milliseconds(300))
    guard window.firstResponder === field else { throw Failure(description: "clique não focou o campo") }
    field.insertText("Capturas do Mac", replacementRange: field.selectedRange())
    // Shift+Return breaks the line.
    window.sendEvent(key("\r", code: 36, flags: .shift, window: window))
    field.insertText("segunda linha", replacementRange: field.selectedRange())
    guard field.string == "Capturas do Mac\nsegunda linha" else {
      throw Failure(description: "Shift+Return: \(field.string.debugDescription)")
    }
    // With text the field keeps only its microphone: the form sends through Enviar.
    try await Task.sleep(for: .milliseconds(300))
    guard accessible("composer-send", in: window) == nil else { throw Failure(description: "o campo mostrou ↑") }
    shot("digitado")
    // Return with a question unanswered goes to it, without sending.
    let before = conversation.submitted
    window.sendEvent(key("\r", code: 36, window: window))
    try await wait("Return foi à próxima pergunta") { window.firstResponder === fields[1] ? true : nil }
    guard conversation.submitted == before else { throw Failure(description: "Return enviou com pergunta sem resposta") }
    // The second answer is dictated (right Option, tap and tap) and lands revised by the fixtures' reviewer.
    let draft = try require(fields[1].input?.representedDraft, "rascunho da segunda resposta")
    func tapOption() {
      for down in [true, false] {
        let flags = down ? NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40) : []
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 61) {
          NSApp.postEvent(event, atStart: false)
        }
      }
    }
    tapOption()
    try await wait("ditado na resposta") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.2))
    shot("ditando")
    tapOption()
    try await wait("ditado revisado na resposta", timeout: 20) {
      fields[1].string == DictationFixtures.text ? true : nil
    }
    guard accessible("composer-send", in: window) == nil else { throw Failure(description: "o campo ditado mostrou ↑") }
    // Everything answered: Return is Enviar.
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
    let sheet = try await wait("visualizador") { NSApp.windows.first { $0.isVisible && $0.title == "Personagens" } }
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

  // MARK: The image viewer: zoom, pan, keys and its menu

  /// A 4800×3600 board in the viewer, off the screens: the wheel zooms around the pointer, dragging pans, ⌘1 ⌘= ⌘−
  /// ⌘0 and the arrows, a resize keeps the middle (or the fit), the double click, the right-click menu (captured,
  /// `<name>-menu.png`) leaves the window open, the title bar's PNG and Esc.
  private static func viewer(window: NSWindow, theme: AppTheme, folder: String) async throws {
    let board = try require(board(), "prancha")
    MacImageWindow.show(MacViewedImage(image: board, name: "Prancha de teste"), theme: theme, over: window)
    let viewer = try await wait("visualizador") { NSApp.windows.first { $0.isVisible && $0.title == "Prancha de teste" } }
    // Off the screens, like the main window of the captures.
    viewer.setFrame(NSRect(x: -5200, y: 80, width: 1200, height: 860), display: true)
    try await Task.sleep(for: .milliseconds(800))
    func shot(_ step: String) { MacCapture.shot(viewer, theme: theme, to: folder + "/\(MacCapture.name)-\(step).png") }
    let scroll = try await wait("tela da imagem") { views(viewer).compactMap { $0 as? MacImageScrollView }.first }
    let clip = scroll.contentView
    let document = try require(scroll.documentView, "imagem")
    func state() -> String {
      "\(Int((scroll.magnification * 100).rounded()))% · origem \(Int(clip.bounds.minX)),\(Int(clip.bounds.minY))"
    }
    func expect(_ condition: Bool, _ what: String) throws {
      guard condition else { throw Failure(description: "\(what) (\(state()))") }
    }
    // Fitted at 100% = one pixel per screen pixel: the whole board, centered.
    let fit = min(1, scroll.bounds.width / document.frame.width, scroll.bounds.height / document.frame.height)
    try expect(abs(scroll.magnification - fit) < 0.002, "abriu fora do ajuste \(fit)")
    try expect(viewer.firstResponder === document, "a tela não tem o foco do teclado: \(viewer.firstResponder.map { String(describing: type(of: $0)) } ?? "nada")")
    shot("ajustada")
    print("MacAjustes viewer: abriu em \(state()), ajuste \(fit)")

    // The wheel zooms around the pointer.
    let pointer = scroll.convert(NSPoint(x: scroll.bounds.width * 0.3, y: scroll.bounds.height * 0.7), to: nil)
    let under = clip.convert(pointer, from: nil)
    let event = try require(wheel(3, at: pointer), "evento da roda")
    viewer.sendEvent(event)
    try await Task.sleep(for: .milliseconds(300))
    let still = clip.convert(pointer, from: nil)
    try expect(scroll.magnification > fit * 1.5,
      "a roda não deu zoom (Δ \(event.scrollingDeltaY), em \(event.locationInWindow) para \(pointer))")
    try expect(hypot(still.x - under.x, still.y - under.y) < 1, "o ponto sob o ponteiro saiu do lugar: \(under) → \(still)")
    shot("roda")
    print("MacAjustes viewer: roda → \(state()), ponto sob o ponteiro \(Int(under.x)),\(Int(under.y)) mantido")

    // Dragging pans by the same distance on screen.
    let before = clip.bounds.origin
    let start = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
    viewer.sendEvent(mouse(.leftMouseDown, at: start, in: viewer))
    for step in 1...6 {
      viewer.sendEvent(mouse(.leftMouseDragged, at: NSPoint(x: start.x - CGFloat(step) * 20, y: start.y - CGFloat(step) * 10),
        in: viewer))
    }
    viewer.sendEvent(mouse(.leftMouseUp, at: NSPoint(x: start.x - 120, y: start.y - 60), in: viewer))
    let moved = NSPoint(x: (clip.bounds.minX - before.x) * scroll.magnification,
      y: (clip.bounds.minY - before.y) * scroll.magnification)
    try expect(abs(moved.x - 120) < 1 && abs(moved.y + 60) < 1, "arrastar moveu \(moved), esperado 120,-60")
    shot("arrastada")
    print("MacAjustes viewer: arrastar 120,60 pt → \(state())")

    // ⌘1, ⌘0, ⌘+ and ⌘− in the window, ahead of the menus (⌘1 there opens the first session).
    // Zooms and arrows animate on a screen: each step waits for it.
    func command(_ character: String, code: UInt16) async throws {
      guard viewer.performKeyEquivalent(with: key(character, code: code, flags: .command, window: viewer)) else {
        throw Failure(description: "⌘\(character) não tratado pela janela")
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    try await command("1", code: 18)
    try expect(abs(scroll.magnification - 1) < 0.001, "⌘1 não mostrou o tamanho real")
    shot("tamanho-real")
    try await command("=", code: 24)
    try expect(abs(scroll.magnification - 1.25) < 0.001, "⌘= não ampliou um passo")
    try await command("-", code: 27)
    try expect(abs(scroll.magnification - 1) < 0.001, "⌘− não reduziu um passo")
    // The arrows pan.
    let arrow = clip.bounds.origin
    viewer.sendEvent(key("\u{F703}", code: 124, window: viewer))
    viewer.sendEvent(key("\u{F701}", code: 125, window: viewer))
    try await Task.sleep(for: .milliseconds(400))
    try expect(abs(clip.bounds.minX - arrow.x - 60) < 0.5 && abs(clip.bounds.minY - arrow.y - 60) < 0.5,
      "as setas moveram para \(clip.bounds.origin) a partir de \(arrow)")
    // A manual zoom keeps the middle through a resize.
    let middle = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
    viewer.setFrame(NSRect(x: -5200, y: 80, width: 1500, height: 900), display: true)
    try await Task.sleep(for: .milliseconds(200))
    try expect(hypot(clip.bounds.midX - middle.x, clip.bounds.midY - middle.y) < 1 && abs(scroll.magnification - 1) < 0.001,
      "redimensionar com zoom tirou o meio \(middle) do lugar")
    try await command("0", code: 29)
    let refit = min(1, scroll.bounds.width / document.frame.width, scroll.bounds.height / document.frame.height)
    try expect(abs(scroll.magnification - refit) < 0.002, "⌘0 não ajustou à janela (\(refit))")
    // Fitting follows the window.
    viewer.setFrame(NSRect(x: -5200, y: 80, width: 900, height: 700), display: true)
    try await Task.sleep(for: .milliseconds(200))
    let small = min(1, scroll.bounds.width / document.frame.width, scroll.bounds.height / document.frame.height)
    try expect(abs(scroll.magnification - small) < 0.002, "o ajuste não acompanhou a janela (\(small))")
    try expect(abs(clip.bounds.midX - document.frame.midX) < 1 && abs(clip.bounds.midY - document.frame.midY) < 1,
      "a imagem ajustada não está no meio")
    print("MacAjustes viewer: ⌘1 ⌘= ⌘− ⌘0, setas e redimensionar ok → \(state())")

    // A double click: 100% under the pointer, then the fit again.
    let spot = scroll.convert(NSPoint(x: scroll.bounds.width * 0.75, y: scroll.bounds.height * 0.25), to: nil)
    let target = clip.convert(spot, from: nil)
    viewer.sendEvent(mouse(.leftMouseDown, at: spot, in: viewer))
    viewer.sendEvent(mouse(.leftMouseUp, at: spot, in: viewer))
    viewer.sendEvent(mouse(.leftMouseDown, at: spot, in: viewer, clicks: 2))
    viewer.sendEvent(mouse(.leftMouseUp, at: spot, in: viewer, clicks: 2))
    // The zoom animates; how long depends on the load, not on a fixed pause.
    _ = try? await wait("100% no duplo clique", timeout: 3) { abs(scroll.magnification - 1) < 0.001 ? true : nil }
    let after = clip.convert(spot, from: nil)
    try expect(abs(scroll.magnification - 1) < 0.001 && hypot(after.x - target.x, after.y - target.y) < 1,
      "o duplo clique não foi a 100% no ponto \(target) → \(after)")
    viewer.sendEvent(mouse(.leftMouseDown, at: spot, in: viewer, clicks: 2))
    viewer.sendEvent(mouse(.leftMouseUp, at: spot, in: viewer, clicks: 2))
    _ = try? await wait("ajuste no segundo duplo clique", timeout: 3) { abs(scroll.magnification - small) < 0.002 ? true : nil }
    try expect(abs(scroll.magnification - small) < 0.002,
      "o segundo duplo clique não voltou ao ajuste (\(Int(scroll.magnification * 100))%)")

    // The menu has the zoom too, and the window stays open while it is up.
    let menu = contextMenu(viewer, at: start, to: folder + "/\(MacCapture.name)-menu.png")
    try expect(menu.titles == ["Copiar imagem", "—", "Ampliar", "Reduzir", "Ajustar à janela", "Tamanho real"],
      "menu \(menu.titles)")
    try expect(viewer.isVisible, "o menu fechou a janela")
    // The title bar's icon is the PNG at full size.
    let file = try await wait("arquivo da barra de título") { viewer.representedURL }
    let written = try require(NSBitmapImageRep(data: try Data(contentsOf: file)), "png")
    try expect(written.pixelsWide == 4800 && written.pixelsHigh == 3600, "arquivo \(written.pixelsWide)×\(written.pixelsHigh)")
    shot("final")
    print("MacAjustes viewer: menu \(menu.titles) · ícone do título \(file.lastPathComponent)")
    // Esc closes.
    viewer.sendEvent(key("\u{1b}", code: 53, window: viewer))
    try await wait("Esc fechou") { viewer.isVisible ? nil : true }
  }

  /// A mouse's wheel turned `lines` notches away from the user over `point` of the window it is sent to: built from a
  /// CGEvent that is never posted. Such an event has no window, so its location in the window is its location on
  /// the screen, set to `point`.
  private static func wheel(_ lines: Int32, at point: NSPoint) -> NSEvent? {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
      wheel3: 0) else { return nil }
    event.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(lines))
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(lines))
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(lines) * 10)
    return NSEvent(cgEvent: event)
  }

  /// A right click in `window` at `point`; while its menu tracks, the menu's own window is captured and the menu
  /// closed. Returns the items and whether `window` stayed key.
  private static func contextMenu(_ window: NSWindow, at point: NSPoint, to path: String) -> (titles: [String], key: Bool) {
    menuProbe = ([], false)
    probe = (window, path)
    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
      queue: .main) { note in
      nonisolated(unsafe) let object = note.object
      MainActor.assumeIsolated {
        guard let menu = object as? NSMenu, menu.supermenu == nil else { return }
        probeMenu = menu
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
          MainActor.assumeIsolated {
            guard let menu = probeMenu else { return }
            menuProbe = (menu.items.map { $0.isSeparatorItem ? "—" : $0.title }, probe?.window.isKeyWindow == true)
            if let path = probe?.path { captureMenus(to: path) }
            menu.cancelTracking()
          }
        }
        RunLoop.main.add(timer, forMode: .common)
      }
    }
    defer {
      NotificationCenter.default.removeObserver(observer)
      probe = nil
      probeMenu = nil
    }
    window.sendEvent(mouse(.rightMouseDown, at: point, in: window))
    window.sendEvent(mouse(.rightMouseUp, at: point, in: window))
    return menuProbe
  }

  private static var menuProbe: (titles: [String], key: Bool) = ([], false)
  private static var probe: (window: NSWindow, path: String)?
  private static var probeMenu: NSMenu?

  /// This app's open menu windows, through the window server (no permission needed for its own windows).
  private static func captureMenus(to path: String) {
    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let menu = windows.first(where: {
      ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) >= 101
    }), let number = menu[kCGWindowNumber as String] as? UInt32,
      let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
    let capture = unsafeBitCast(symbol, to: Capture.self)
    guard let image = capture(.null, 1 << 3, number, 1 << 0 | 1 << 3)?.takeRetainedValue(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
  }

  /// A 4800×3600 sheet of colored cards with one-pixel lines, like a large board of mocks.
  private static func board() -> CGImage? {
    let width = 4800, height = 3600
    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: width,
      height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(gray: 0.95, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for row in 0..<9 {
      for column in 0..<12 {
        context.setFillColor(NSColor(hue: CGFloat((row * 5 + column) % 24) / 24, saturation: 0.5, brightness: 0.85,
          alpha: 1).cgColor)
        context.fill(CGRect(x: 40 + column * 396, y: 40 + row * 396, width: 356, height: 356))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for line in 0..<12 { context.fill(CGRect(x: 60 + column * 396, y: 70 + row * 396 + line * 24, width: 300, height: 1)) }
      }
    }
    return context.makeImage()
  }

  private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1,
    flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
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
      SessionSections.group(store.filtered, now: .now, held: store.attentionHold),
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

  /// The chat | Contexto divider: the pointer 7 pt either side of the hairline reaches its grip at every height,
  /// over the transcript, the composer and Contexto, and dragging it 80 pt left widens Contexto by 80 pt.
  private static func divider(window: NSWindow, runtime: MacWindowRuntime) async throws {
    let grip = try await wait("a alça do divisor") {
      views(window).first { String(describing: type(of: $0)) == "Grip" && $0.window != nil && $0.bounds.width > 0 }
    }
    let root = try require(window.contentView?.superview, "a raiz da janela")
    let frame = grip.convert(grip.bounds, to: nil)
    let center = CGPoint(x: frame.midX, y: frame.midY)
    for y in stride(from: frame.minY + 4, to: frame.maxY - 4, by: 30) {
      for offset in [-7.0, -3, 0, 3, 7] {
        let hit = root.hitTest(root.convert(CGPoint(x: center.x + offset, y: y), from: nil))
        guard hit === grip else {
          throw Failure(description: "a \(Int(offset)) pt da linha, na altura \(Int(y)), o clique vai para \(hit.map { type(of: $0) }.map(String.init(describing:)) ?? "nada")")
        }
      }
    }
    let before = runtime.contextWidth
    func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: center.y), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    window.sendEvent(mouse(.leftMouseDown, center.x + 4))
    for step in 1...8 { window.sendEvent(mouse(.leftMouseDragged, center.x + 4 - CGFloat(step) * 10)) }
    window.sendEvent(mouse(.leftMouseUp, center.x - 76))
    try await Task.sleep(for: .milliseconds(300))
    print("MacAjustes divider: Contexto \(Int(before)) → \(Int(runtime.contextWidth))")
    guard abs(runtime.contextWidth - before - 80) < 1 else {
      throw Failure(description: "arrastar 80 pt mudou Contexto de \(before) para \(runtime.contextWidth)")
    }
  }

  /// The columns' scroll views scrolled down: each one's content is cut at the title bar's bottom edge, like the
  /// chat's, so nothing scrolls under the bar's items.
  private static func edge(window: NSWindow, shot: (String) -> Void) async throws {
    let bar = window.contentLayoutRect.maxY
    let scrolls = views(window).compactMap { $0 as? NSScrollView }.filter {
      $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.height > 200 && $0.hasVerticalScroller
        && ($0.documentView?.frame.height ?? 0) + $0.contentInsets.top + $0.contentInsets.bottom
          > $0.contentView.bounds.height + 60
    }
    guard !scrolls.isEmpty else { throw Failure(description: "nenhuma lista rolável") }
    for scroll in scrolls {
      let clip = scroll.contentView
      clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: clip.isFlipped ? 300 : -300)).origin)
      scroll.reflectScrolledClipView(clip)
    }
    try await Task.sleep(for: .milliseconds(600))
    shot("rolado")
    var failures: [String] = []
    for scroll in scrolls {
      // What the window shows of the scroll view: its frame cut by every ancestor that clips.
      var shown = scroll.convert(scroll.bounds, to: nil)
      var view = scroll.superview
      while let ancestor = view {
        if ancestor.clipsToBounds || ancestor.layer?.masksToBounds == true || ancestor.layer?.mask != nil {
          shown = shown.intersection(ancestor.convert(ancestor.bounds, to: nil))
        }
        view = ancestor.superview
      }
      let name = "\(type(of: scroll)) x \(Int(shown.minX))–\(Int(shown.maxX))"
      print("MacAjustes edge: \(name) · topo visível \(Int(window.frame.height - shown.maxY)) · barra \(Int(window.frame.height - bar)) · inset \(Int(scroll.contentInsets.top))")
      if shown.maxY > bar + 0.5 { failures.append("\(name) passa \(Int(shown.maxY - bar)) pt sob a barra") }
    }
    if !failures.isEmpty { throw Failure(description: failures.joined(separator: "; ")) }
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
    try await escape(window: window, runtime: runtime, draft: draft, option: option, shot: shot)
    try await revision(window: window, runtime: runtime, draft: draft, option: option, shot: shot)
  }

  /// The AI review (the fixtures' reviewer, 2.5 s): on at every recording, ⌥⌘E toggles it, also with the right
  /// Option key held and without ending the hold; "Ajustando texto…"; the context is what each composer shows; undo
  /// brings back the raw text, then removes it; Esc during the review inserts nothing.
  private static func revision(window: NSWindow, runtime: MacWindowRuntime, draft: ConversationDraft,
    option: (Bool, Bool) -> Void, shot: (String) -> Void) async throws
  {
    func toggle(_ target: NSWindow) {
      NSApp.postEvent(key("e", code: 14, flags: [.command, .option], window: target), atStart: false)
    }
    /// ⌘ (left, 0x08) going down or up while the right Option key (0x40) is held.
    func command(_ down: Bool) {
      let flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40
        | (down ? NSEvent.ModifierFlags.command.rawValue | 0x08 : 0))
      if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55) {
        NSApp.postEvent(event, atStart: false)
      }
    }
    func tap() { option(true, false); option(false, false) }
    let editor = try require(draft.input?.textView, "editor")
    let before = "Antes do ditado"
    func reset() {
      draft.text = NSAttributedString(string: before)
      draft.selection = NSRange(location: (before as NSString).length, length: 0)
      draft.focused = true
    }
    reset()
    try await wait("foco para a revisão") { window.firstResponder === editor ? true : nil }
    tap()
    try await wait("gravou para a revisão") { draft.recording.capturing ? true : nil }
    guard draft.recording.revision.enabled else { throw Failure(description: "a gravação começou com a revisão desligada") }
    try await Task.sleep(for: .seconds(1.2))
    shot("revisao-ligada")
    toggle(window)
    try await wait("⌥⌘E desligou") { draft.recording.revision.enabled ? nil : true }
    shot("revisao-desligada")
    toggle(window)
    try await wait("⌥⌘E ligou") { draft.recording.revision.enabled ? true : nil }
    tap()
    try await wait("ajustando texto") { draft.recording.revision.reviewing != nil ? true : nil }
    try await Task.sleep(for: .milliseconds(400))
    shot("revisao-ajustando")
    let revised = before + " " + DictationFixtures.text
    try await wait("revisado", timeout: 15) { draft.text.string == revised ? true : nil }
    let context = DictationReviewFixture.contexts.last.flatMap { $0 } ?? ""
    print("MacAjustes dictation: contexto da conversa com \(context.count) caracteres")
    guard context.hasSuffix("Draft:\n" + before), context.contains("User: ") || context.contains("Assistant: ") else {
      throw Failure(description: "contexto da conversa: \(context.prefix(300).debugDescription)")
    }
    shot("revisao-revisado")
    editor.undoManager?.undo()
    try await wait("primeiro desfazer voltou ao texto cru") {
      draft.text.string == before + " " + DictationFixtures.raw ? true : nil
    }
    editor.undoManager?.undo()
    try await wait("segundo desfazer removeu o ditado") { draft.text.string == before ? true : nil }
    // Held: ⌘ and E toggle the review without ending the hold; the release transcribes, unrevised.
    reset()
    option(true, false)
    try await wait("segurar gravou para o ⌥⌘E") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.4))
    command(true); toggle(window); command(false)
    try await wait("⌥⌘E segurando desligou") { draft.recording.revision.enabled ? nil : true }
    try await Task.sleep(for: .milliseconds(400))
    guard draft.recording.capturing else { throw Failure(description: "⌥⌘E encerrou a gravação segurada") }
    option(false, false)
    try await wait("soltar inseriu o texto cru", timeout: 15) {
      draft.text.string == before + " " + DictationFixtures.raw ? true : nil
    }
    // Esc during "Ajustando texto…": nothing lands, not even after the reply.
    reset()
    tap()
    try await wait("gravou para o Esc na revisão") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.2))
    tap()
    try await wait("ajustando para o Esc") { draft.recording.revision.reviewing != nil ? true : nil }
    NSApp.postEvent(key("\u{1b}", code: 53, window: window), atStart: false)
    try await wait("Esc cancelou a revisão") { draft.recording.visible ? nil : true }
    try await Task.sleep(for: .seconds(3))
    guard draft.text.string == before, window.firstResponder === editor else {
      throw Failure(description: "Esc na revisão: texto \(draft.text.string.debugDescription)")
    }
    draft.text = NSAttributedString()
    // Each sheet's composer reviews with what it shows.
    try await sheetReview("nova-sessao", window: window, option: option, shot: shot) {
      runtime.newSession(from: MacFixture.rootID)
    } context: { !$0.contains("User: ") && !$0.contains("Assistant: ") }
    try await sheetReview("pergunta-paralela", window: window, option: option, shot: shot) {
      runtime.askSideQuestion()
    } context: { !$0.contains("User: ") && !$0.contains("Assistant: ") }
    try await sheetReview("comentario", window: window, option: option, shot: shot) {
      draft.commenting = ChatQuote(messageID: "msg_check", partID: "prt_check", text: "Trecho citado")
    } context: { $0.hasPrefix("Quoted passage:\nTrecho citado") }
    print("MacAjustes dictation: revisão ligada a cada gravação, ⌥⌘E (também segurando), desfazer em dois passos, Esc")
  }

  private static func sheetReview(_ name: String, window: NSWindow, option: (Bool, Bool) -> Void,
    shot: (String) -> Void, open: () -> Void, context expected: (String) -> Bool) async throws
  {
    open()
    let sheet = try await wait("folha \(name) (revisão)") { window.attachedSheet }
    let field = try await wait("campo da folha \(name) (revisão)") {
      MacSyntheticKey.composer(in: sheet.contentView).flatMap { sheet.firstResponder === $0 ? $0 : nil }
    }
    let draft = try require(field.input?.representedDraft, "rascunho da folha \(name)")
    await draft.load()
    field.insertText("Texto da folha", replacementRange: field.selectedRange())
    try await Task.sleep(for: .milliseconds(400))
    option(true, false); option(false, false)
    try await wait("gravou na folha \(name) (revisão)") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.2))
    option(true, false); option(false, false)
    try await wait("revisado na folha \(name)", timeout: 15) {
      field.string.contains(DictationFixtures.text) ? true : nil
    }
    let context = DictationReviewFixture.contexts.last.flatMap { $0 } ?? ""
    guard context.hasSuffix("Draft:\nTexto da folha"), expected(context) else {
      throw Failure(description: "contexto da folha \(name): \(context.prefix(300).debugDescription)")
    }
    shot("revisao-\(name)")
    NSApp.postEvent(key("\u{1b}", code: 53, window: sheet), atStart: false)
    try await wait("Esc fechou a folha \(name)") { window.attachedSheet == nil ? true : nil }
    try await Task.sleep(for: .milliseconds(600))
    guard FileManager.default.fileExists(atPath: draft.persistence.directory.path) else { return }
    draft.text = NSAttributedString()
    await draft.persist()
  }

  /// Esc cancels a dictation (tap, hold, transcription) and does nothing else; a second Esc keeps its meaning.
  private static func escape(window: NSWindow, runtime: MacWindowRuntime, draft: ConversationDraft,
    option: (Bool, Bool) -> Void, shot: (String) -> Void) async throws
  {
    // Through the app's queue, where `MacDictationKey` watches keys, to the window it would go to.
    func esc(_ target: NSWindow) { NSApp.postEvent(key("\u{1b}", code: 53, window: target), atStart: false) }
    func tap() { option(true, false); option(false, false) }
    let editor = try require(draft.input?.textView, "editor")
    let before = "Rascunho antes do ditado"
    draft.text = NSAttributedString(string: before)
    draft.selection = NSRange(location: (before as NSString).length, length: 0)
    draft.focused = true
    try await wait("foco no editor") { window.firstResponder === editor ? true : nil }
    /// Esc ended the dictation, nothing landed afterwards and the editor kept the text and the focus.
    func untouched(_ what: String) async throws {
      try await wait("Esc cancelou (\(what))") { draft.recording.visible ? nil : true }
      try await Task.sleep(for: .seconds(2.5))
      guard draft.text.string == before, !draft.recording.visible, window.firstResponder === editor else {
        throw Failure(description: "Esc (\(what)): texto \(draft.text.string.debugDescription), painel "
          + "\(draft.recording.visible), foco \(window.firstResponder === editor)")
      }
    }
    // Tap-started recording: Esc stops it with nothing transcribed.
    tap()
    try await wait("toque gravou para o Esc") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.2))
    shot("esc-gravando")
    esc(window)
    try await untouched("toque")
    shot("esc-cancelou")
    // Held: Esc cancels while the key is down, and its release afterwards transcribes nothing.
    option(true, false)
    try await wait("segurar gravou para o Esc") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.4))
    esc(window)
    try await wait("Esc cancelou o segurar") { draft.recording.visible ? nil : true }
    option(false, false)
    try await untouched("segurar e soltar")
    // Stopped and transcribing: Esc throws the transcription away.
    tap()
    try await wait("gravou para transcrever") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.2))
    tap()
    esc(window)
    try await untouched("transcrevendo")
    // No dictation: Esc keeps its meaning (here it closes the open suggestions).
    draft.text = NSAttributedString(string: "@")
    draft.selection = NSRange(location: 1, length: 0)
    try await wait("sugestões abertas") { draft.trigger != nil ? true : nil }
    esc(window)
    try await wait("Esc sem ditado fechou as sugestões") { draft.trigger == nil ? true : nil }
    draft.text = NSAttributedString()
    // In a sheet, the first Esc only cancels the dictation; the second closes the sheet as before.
    try await sheet("nova-sessao", window: window, option: option, shot: shot) { runtime.newSession(from: MacFixture.rootID) }
    try await sheet("pergunta-paralela", window: window, option: option, shot: shot) { runtime.askSideQuestion() }
    try await sheet("comentario", window: window, option: option, shot: shot) {
      draft.commenting = ChatQuote(messageID: "msg_check", partID: "prt_check", text: "Trecho citado")
    }
    print("MacAjustes dictation: Esc cancelou toque, segurar e transcrição; folhas ficaram abertas no primeiro Esc")
  }

  private static func sheet(_ name: String, window: NSWindow, option: (Bool, Bool) -> Void, shot: (String) -> Void,
    open: () -> Void) async throws
  {
    open()
    let sheet = try await wait("folha \(name)") { window.attachedSheet }
    let field = try await wait("campo da folha \(name)") {
      MacSyntheticKey.composer(in: sheet.contentView).flatMap { sheet.firstResponder === $0 ? $0 : nil }
    }
    let draft = try require(field.input?.representedDraft, "rascunho da folha \(name)")
    // A saved draft (Nova sessão's, from an earlier run) loads after the field may already have the focus.
    await draft.load()
    field.insertText("Texto da folha", replacementRange: field.selectedRange())
    let before = field.string
    try await Task.sleep(for: .milliseconds(400))
    option(true, false); option(false, false)
    try await wait("gravou na folha \(name)") { draft.recording.capturing ? true : nil }
    try await Task.sleep(for: .seconds(1.2))
    NSApp.postEvent(key("\u{1b}", code: 53, window: sheet), atStart: false)
    try await wait("Esc cancelou na folha \(name)") { draft.recording.visible ? nil : true }
    try await Task.sleep(for: .seconds(1.5))
    guard window.attachedSheet === sheet, field.string == before, sheet.firstResponder === field,
      !draft.recording.visible else {
      throw Failure(description: "folha \(name): aberta \(window.attachedSheet === sheet), texto \(field.string.debugDescription), "
        + "foco \(sheet.firstResponder === field)")
    }
    shot("esc-\(name)")
    NSApp.postEvent(key("\u{1b}", code: 53, window: sheet), atStart: false)
    try await wait("segundo Esc fechou a folha \(name)") { window.attachedSheet == nil ? true : nil }
    try await Task.sleep(for: .milliseconds(600))
    // A draft that outlives its sheet (Nova sessão's) is left as the fixture had it.
    guard FileManager.default.fileExists(atPath: draft.persistence.directory.path) else { return }
    draft.text = NSAttributedString()
    await draft.persist()
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

  // MARK: Markdown files in Arquivos

  /// Arquivos drew nothing for every Markdown file (30/10): its lazy stack never built a piece still empty until its
  /// own task parsed it. A short file and a long report with wide tables and links (`script/fixtures/mac-markdown`),
  /// each opened the way a file link in the chat opens it, must show their text, tables included, with height.
  private static func markdown(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    let folder = try require(MacFixture.current?.root, "fixture") + "/packages/ios-custom/script/fixtures/mac-markdown"
    runtime.showFiles(at: folder, file: folder + "/simples.md")
    try await rendered("Título simples", visible: true, in: window)
    try await rendered("Um parágrafo curto com negrito", visible: true, in: window)
    shot("simples")
    runtime.showFiles(at: folder, file: folder + "/Relatório com tabela larga.md")
    try await rendered("A configuração existe, mas nenhuma oferta confirma o prazo", visible: true, in: window)
    try await rendered("Não vale pagar uma pré-venda", visible: false, in: window)
    // The wide table sits between two prose pieces: bring the one after it into view, the table above it.
    let after = try require(views(window).first { ($0 as? MacResponseTextView)?.string.contains("O prazo da Loja A") == true },
      "texto depois da tabela")
    after.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: 1))
    // SwiftUI builds no accessibility tree without a client; the table is its horizontal scroll view, wider than
    // the pane and as tall as its six rows.
    func table() -> Bool {
      views(window).contains { view in
        guard let scroll = view as? NSScrollView, let document = scroll.documentView, !scroll.visibleRect.isEmpty
        else { return false }
        return scroll.frame.height > 150 && document.frame.width > scroll.frame.width + 100
      }
    }
    try await wait("tabela larga") { table() ? true : nil }
    // Still in place once the highlighted parse has replaced the first one.
    try await Task.sleep(for: .seconds(1))
    guard table() else { throw Failure(description: "a tabela saiu da vista depois da segunda leitura") }
    shot("relatorio")
  }

  // MARK: Arquivos in two columns

  /// A link opens its file with every folder above it expanded and the file marked; ‹ › and ⌃⌘← ⌃⌘→ walk the
  /// history; Recentes keep the order; the filter and Alterados (the fixture's working changes) reshape the tree.
  private static func arquivos(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    let folder = try require(MacFixture.current?.root, "fixture") + "/packages/ios-custom/script/fixtures/mac-markdown"
    let report = folder + "/Relatório com tabela larga.md"
    let simple = folder + "/simples.md"
    runtime.contextWidth = 1000
    runtime.showFiles(at: folder, file: report)
    let files = try await wait("Arquivos") { MacFilesStore.shown }
    try await wait("arquivo do link marcado com as pastas abertas", timeout: 15) {
      let rows = files.rows
      let chain = ["packages", "ios-custom", "script", "fixtures", "mac-markdown"].allSatisfy { name in
        rows.contains { $0.directory && $0.name == name && $0.open }
      }
      return chain && files.selected == report && rows.contains { $0.id == report } ? true : nil
    }
    guard !files.folded else { throw Failure(description: "a árvore recolheu num painel largo") }
    try await rendered("A configuração existe, mas nenhuma oferta confirma o prazo", visible: true, in: window)
    try await Task.sleep(for: .milliseconds(600))
    shot("largo")
    files.activate(try require(files.rows.first { $0.id == simple }, "simples.md na árvore"))
    try await rendered("Título simples", visible: true, in: window)
    guard files.recents.paths.prefix(2) == [simple, report] else {
      throw Failure(description: "Recentes: \(files.recents.paths)")
    }
    let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
    let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
    func press(_ character: String, code: UInt16, flags: NSEvent.ModifierFlags) {
      let event = key(character, code: code, flags: flags, window: window)
      if !window.performKeyEquivalent(with: event) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
    }
    try await Task.sleep(for: .milliseconds(400))
    press(left, code: 123, flags: [.control, .command])
    try await wait("⌃⌘← voltou") { files.selected == report ? true : nil }
    guard files.history.canGoForward, files.recents.paths.first == simple else {
      throw Failure(description: "voltar no histórico mexeu nos Recentes ou perdeu o avanço")
    }
    // The › button's shortcut binds once it re-renders enabled.
    try await Task.sleep(for: .milliseconds(400))
    press(right, code: 124, flags: [.control, .command])
    try await wait("⌃⌘→ avançou") { files.selected == simple ? true : nil }
    files.back()
    try await wait("‹ voltou") { files.selected == report ? true : nil }
    files.filter = "SIMPLES"
    try await wait("filtro") {
      files.rows.filter { !$0.directory }.map(\.name) == ["simples.md"] ? true : nil
    }
    try await Task.sleep(for: .milliseconds(400))
    shot("filtro")
    files.filter = ""
    files.onlyChanged = true
    try await wait("Alterados") {
      let rows = files.rows
      return rows.contains { $0.name == "SessionRowView.swift" && $0.status != nil }
        && rows.allSatisfy { $0.directory ? $0.open && $0.containsChanges : $0.status != nil } ? true : nil
    }
    try await Task.sleep(for: .milliseconds(400))
    shot("alterados")
    files.onlyChanged = false
  }

  /// Ampliar (⇧⌘E) leaves the chat at its minimum without touching the width chosen with the divider, and the same
  /// key gives it back; closing Arquivos ends it. A narrow panel folds the tree into its rail.
  private static func ampliar(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    let folder = try require(MacFixture.current?.root, "fixture") + "/packages/ios-custom/script/fixtures/mac-markdown"
    let report = folder + "/Relatório com tabela larga.md"
    runtime.contextWidth = 560
    runtime.showFiles(at: folder, file: report)
    try await rendered("A configuração existe, mas nenhuma oferta confirma o prazo", visible: true, in: window)
    try await Task.sleep(for: .milliseconds(500))
    let chosen = runtime.contextWidth
    let before = runtime.measuredContextWidth
    let widen = key("e", code: 14, flags: [.shift, .command], window: window)
    func press() { if !window.performKeyEquivalent(with: widen) { _ = NSApp.mainMenu?.performKeyEquivalent(with: widen) } }
    press()
    try await wait("Ampliar") {
      runtime.filesWide && abs(runtime.measuredChatWidth - 460) < 2 && runtime.measuredContextWidth > before + 100 ? true : nil
    }
    guard runtime.contextWidth == chosen else { throw Failure(description: "Ampliar mudou a largura escolhida") }
    try await Task.sleep(for: .milliseconds(500))
    shot("ampliado")
    press()
    try await wait("Reduzir") { !runtime.filesWide && abs(runtime.measuredContextWidth - before) < 2 ? true : nil }
    runtime.toggleFilesWide()
    runtime.selection.files = nil
    guard !runtime.filesWide else { throw Failure(description: "fechar Arquivos manteve o painel ampliado") }
    runtime.contextWidth = 420
    runtime.showFiles(at: folder, file: report)
    try await wait("árvore recolhida no painel estreito") { MacFilesStore.shown?.folded == true ? true : nil }
    try await rendered("A configuração existe, mas nenhuma oferta confirma o prazo", visible: true, in: window)
    try await Task.sleep(for: .milliseconds(500))
    shot("estreito")
  }

  // MARK: Contexto — the metrics line, the shimmer and the open subagent

  /// The subagents' lines wide and narrow, their titles at the margin (the running ones shimmering on one phase), the
  /// waiting one's request, the shimmer's CPU, then the column following a subagent, its own subagent and the way
  /// back. The copy runs in the background without an accessibility tree: geometry comes from the AppKit views, the
  /// rest from the column's data and decisions, and the pictures show the result.
  private static func contexto(window: NSWindow, runtime: MacWindowRuntime, shot: (String) -> Void) async throws {
    let rootID = MacFixture.rootID
    let child = MacFixtureServer.parentOfGrandchildren
    func column(_ id: String, subagents: Int) async throws -> ContextColumnStore {
      try await wait("Contexto de \(id)", timeout: 12) {
        ContextColumnStore.shown.flatMap { $0.id == id && $0.loaded && $0.subagents.total == subagents ? $0 : nil }
      }
    }
    func shimmers(_ count: Int) async throws -> [MacShimmerText.ShimmerView] {
      try await wait("\(count) títulos com brilho") {
        let views = views(window).compactMap { $0 as? MacShimmerText.ShimmerView }.filter { $0.window != nil }
        return views.count == count && views.allSatisfy { $0.phase != nil && $0.bounds.width > 40 } ? views : nil
      }
    }
    /// Every running title starts at the column's margin, 18 pt inside Contexto's scroll view (else inside the
    /// column, which ends at the window's edge): nothing is drawn before it.
    func margins(_ views: [MacShimmerText.ShimmerView]) throws {
      let scroll = views.first.flatMap { view in
        sequence(first: view as NSView, next: { $0.superview }).lazy.compactMap { $0 as? NSScrollView }.first
      }
      let margin = (scroll.map { $0.convert($0.bounds, to: nil).minX }
        ?? (window.contentView?.bounds.width ?? 0) - runtime.measuredContextWidth) + 18
      let starts = views.map { $0.convert($0.bounds, to: nil).minX }
      guard starts.allSatisfy({ abs($0 - margin) < 1 }) else {
        throw Failure(description: "títulos recuados: margem \(margin), começos \(starts)")
      }
    }
    runtime.contextWidth = 1_000
    let root = try await column(rootID, subagents: MacFixtureServer.children.count)
    do {
      try await wait("Contexto largo") { runtime.measuredContextWidth > 990 ? true : nil }
    } catch {
      throw Failure(description: "Contexto \(runtime.measuredContextWidth) de \(runtime.contextWidth) pedidos · chat "
        + "\(runtime.measuredChatWidth) · janela \(window.frame.width)")
    }
    let states = Dictionary(root.subagents.shown.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
    guard ["ses_mac_c1", "ses_mac_c2", "ses_mac_c3"].allSatisfy({ states[$0] == .running }),
      states["ses_mac_c4"] == .permission, states["ses_mac_c5"] == .completed else {
      throw Failure(description: "estados da raiz: \(states)")
    }
    let running = try await shimmers(3)
    // One phase: every pass starts on a multiple of the period.
    guard running.allSatisfy({ min($0.phase ?? 1, MacShimmerText.period - ($0.phase ?? 1)) < 0.001 }) else {
      throw Failure(description: "fases do brilho: \(running.map { $0.phase ?? -1 })")
    }
    try margins(running)
    guard !MacContextProbe.narrow else { throw Failure(description: "1000 pt tratado como estreito") }
    guard root.subagents.shown.first(where: { $0.id == "ses_mac_c4" })?.permission?.preview
      == "Quer rodar: gh api repos/jean/referencias" else { throw Failure(description: "pedido do subagente esperando") }
    // A running subagent's `todowrite`, through the shared stream like a real one: its line gains `☑ 1/3`.
    for event in progressEvents("ses_mac_c2") { runtime.store?.hub.inject(event) }
    try await wait("Progresso do subagente") {
      root.subagents.shown.first { $0.id == "ses_mac_c2" }?.progress?.label == "1/3" ? true : nil
    }
    try await Task.sleep(for: .seconds(1.2))
    shot("largo")
    // Three moments of the pass, held still: the bright band over the start, the middle and the end.
    for (index, fraction) in [0.3, 0.5, 0.7].enumerated() {
      running.forEach { $0.hold(at: fraction) }
      try await Task.sleep(for: .milliseconds(500))
      shot("brilho-\(index + 1)")
    }
    running.forEach { $0.hold(at: nil) }
    try await shimmerCPU(runtime: runtime)

    runtime.contextWidth = 400
    try await wait("painel estreito") { MacContextProbe.narrow ? true : nil }
    print("MacAjustes contexto larguras: janela \(Int(window.frame.width)) · Contexto \(Int(runtime.measuredContextWidth))")
    try margins(try await shimmers(3))
    try await Task.sleep(for: .milliseconds(800))
    shot("estreito")

    // Opening a subagent: the column shows its context, costs and its own subagents, with the path back.
    runtime.contextWidth = 1_000
    runtime.selection.childID = child
    let opened = try await column(child, subagents: MacFixtureServer.grandchildren.count)
    guard opened.session?.id == child, abs((opened.usage?.fraction ?? 0) - 0.2851) < 0.001,
      opened.costs.session == 2_759.40, abs((opened.costs.subagents ?? 0) - 1.26) < 0.001,
      opened.subagents.shown.map(\.id) == ["ses_mac_g1", "ses_mac_g2"],
      opened.subagents.shown.map(\.status) == [.running, .completed]
    else {
      throw Failure(description: "coluna do subagente: \(opened.usage?.fraction ?? -1) · \(opened.costs) · "
        + "\(opened.subagents.shown.map { "\($0.id) \($0.status)" })")
    }
    try margins(try await shimmers(1))
    guard opened.sessions.subagentPath(root: rootID, child: child).map(\.id) == [child] else {
      throw Failure(description: "caminho do subagente")
    }
    try await Task.sleep(for: .milliseconds(800))
    shot("subagente-largo")
    // Live: a step of its running subagent reloads it; another session's does not.
    let loads = opened.loads
    runtime.store?.hub.inject(event("session.updated", "ses_mac_g1"))
    try await wait("recarregou com o evento do neto") { opened.loads > loads ? true : nil }
    try await Task.sleep(for: .seconds(1))
    let settled = opened.loads
    runtime.store?.hub.inject(event("session.updated", "ses_mac_live"))
    try await Task.sleep(for: .seconds(1.5))
    guard opened.loads == settled else { throw Failure(description: "recarregou com o evento de outra sessão") }
    runtime.contextWidth = 400
    try await wait("subagente estreito") { MacContextProbe.narrow ? true : nil }
    try await Task.sleep(for: .seconds(1))
    shot("subagente-estreito")

    // Its subagent: the path names both ancestors; the middle one goes back to it, then the root.
    runtime.contextWidth = 1_000
    runtime.selection.childID = "ses_mac_g1"
    let grandchild = try await column("ses_mac_g1", subagents: 0)
    try await wait("caminho pelo subagente do meio") {
      grandchild.sessions.subagentPath(root: rootID, child: "ses_mac_g1").map(\.id) == [child, "ses_mac_g1"] ? true : nil
    }
    try await Task.sleep(for: .milliseconds(800))
    shot("neto")
    runtime.open(ancestor: child)
    _ = try await column(child, subagents: MacFixtureServer.grandchildren.count)
    guard runtime.selection.childID == child else { throw Failure(description: "o caminho não voltou ao subagente") }
    runtime.open(ancestor: rootID)
    try await wait("Contexto voltou à raiz") {
      runtime.selection.childID == nil && ContextColumnStore.shown === root ? true : nil
    }
    // The root's column was kept: it shows at once while it reloads.
    guard root.loaded, root.subagents.total == MacFixtureServer.children.count else {
      throw Failure(description: "a coluna da raiz voltou vazia")
    }
    // ⌘[ and the banner's Voltar.
    runtime.selection.childID = child
    _ = try await column(child, subagents: MacFixtureServer.grandchildren.count)
    runtime.backToParent()
    try await wait("⌘[ voltou à raiz") {
      runtime.selection.childID == nil && ContextColumnStore.shown?.id == rootID ? true : nil
    }
    try await Task.sleep(for: .milliseconds(800))
    shot("voltou")
  }

  /// The shimmer's cost, with the three running titles on screen against Contexto hidden: the main thread, the
  /// whole process, the window server and how many times the subagent rows' bodies ran.
  private static func shimmerCPU(runtime: MacWindowRuntime) async throws {
    func measure(_ name: String) async -> (main: Double, process: Double, server: Double?, bodies: Int) {
      try? await Task.sleep(for: .seconds(1.5))
      MacPerf.resetCounts()
      MacPerf.counting = true
      let wall = CACurrentMediaTime()
      let main = MacPerf.mainCPU()
      let process = processCPU()
      let server = windowServerCPU()
      try? await Task.sleep(for: .seconds(8))
      let seconds = CACurrentMediaTime() - wall
      MacPerf.counting = false
      let result = (main: (MacPerf.mainCPU() - main) / seconds, process: (processCPU() - process) / seconds,
        server: server.flatMap { start in windowServerCPU().map { ($0 - start) / seconds } },
        bodies: (MacPerf.counts["SubagentLine"] ?? 0) + (MacPerf.counts["ContextSubagents"] ?? 0))
      print(String(format: "MacAjustes contexto cpu %@: principal %.2f%% · processo %.2f%% · WindowServer %@ · corpos %d",
        name, result.main * 100, result.process * 100,
        result.server.map { String(format: "%.2f%%", $0 * 100) } ?? "—", result.bodies))
      fflush(stdout)
      return result
    }
    let shimmering = await measure("três títulos com brilho")
    runtime.contextVisible = false
    let hidden = await measure("Contexto oculto")
    runtime.contextVisible = true
    // SwiftUI redraws nothing while the band runs: the rows' bodies run at most on the minute's tick (an animation
    // in SwiftUI would run them on every frame), and the main thread stays as idle as without the column.
    guard shimmering.bodies <= 12, shimmering.main < hidden.main + 0.02 else {
      throw Failure(description: "o brilho custa: \(shimmering) contra \(hidden)")
    }
  }

  private static func processCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  /// The window server's CPU time in seconds (`ps`), where Core Animation runs the band.
  private static func windowServerCPU() -> Double? {
    func run(_ path: String, _ arguments: [String]) -> String? {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = arguments
      process.standardOutput = pipe
      guard (try? process.run()) != nil else { return nil }
      process.waitUntilExit()
      return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let pid = run("/usr/bin/pgrep", ["-x", "WindowServer"])?.split(separator: "\n").first,
      let time = run("/bin/ps", ["-o", "cputime=", "-p", String(pid)]) else { return nil }
    // `[[hh:]mm:]ss.cc`
    return time.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
  }

  /// A `todowrite` call that succeeds: one item done, one in hand, one pending.
  private static func progressEvents(_ id: String) -> [ServerEvent] {
    let todos = #"[{"content":"Ler o tracker","status":"completed"},{"content":"Editar a Live Activity","status":"in_progress"},{"content":"Rodar os testes","status":"pending"}]"#
    return [
      #"{"type":"session.tool.input.started","created":0,"data":{"sessionID":"\#(id)","id":"call_todo_\#(id)","name":"todowrite"}}"#,
      #"{"type":"session.tool.called","created":0,"data":{"sessionID":"\#(id)","id":"call_todo_\#(id)","name":"todowrite","input":{"todos":\#(todos)}}}"#,
      #"{"type":"session.tool.success","created":0,"data":{"sessionID":"\#(id)","id":"call_todo_\#(id)"}}"#,
    ].map { .update(try! JSONDecoder().decode(ConversationEvent.self, from: Data($0.utf8))) }
  }

  private static func event(_ type: String, _ id: String) -> ServerEvent {
    let json = #"{"type":"\#(type)","created":\#(Date.now.timeIntervalSince1970 * 1000),"data":{"sessionID":"\#(id)"}}"#
    return .update(try! JSONDecoder().decode(ConversationEvent.self, from: Data(json.utf8)))
  }

  /// A Markdown text view of the window whose text contains `text`, laid out with height (and on screen).
  private static func rendered(_ text: String, visible: Bool, in window: NSWindow) async throws {
    try await wait("texto \"\(text)\" no painel") {
      views(window).contains { view in
        guard let view = view as? MacResponseTextView, view.string.contains(text), view.frame.height > 0 else { return false }
        return !visible || !view.visibleRect.isEmpty
      } ? true : nil
    }
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

  // MARK: Progresso — the pill, its popover and the Sessões row (rev. 2026-10-30)

  private static func progresso(window: NSWindow, runtime: MacWindowRuntime, theme: AppTheme, folder: String,
    shot: (String) -> Void) async throws
  {
    let store = try require(runtime.store, "sessões")
    let conversation = try await wait("conversa") { store.liveConversation(MacFixture.rootID) }
    // The background copy has no accessibility client, so SwiftUI builds no accessibility tree: the pill reports
    // what it shows itself.
    let pill = try await wait("pílula do Progresso", timeout: 12) { ConversationProgressPill.shown }
    guard pill == "Progresso: 3 de 7. Agora: Atualizar a Live Activity e o relógio" else {
      throw Failure(description: "pílula: \(pill)")
    }
    let row = try await wait("linha com Progresso") {
      store.rows.first { $0.id == MacFixture.rootID }?.progress
    }
    guard row.count == "3/7", row.current?.content == "Atualizar a Live Activity e o relógio" else {
      throw Failure(description: "linha: \(row.count) \(row.current?.content ?? "-")")
    }
    try await Task.sleep(for: .milliseconds(600))
    shot("pilula")
    NotificationCenter.default.post(name: ConversationProgressPill.openRequest, object: nil)
    let popover = try await wait("popover") {
      NSApp.windows.first { $0 !== window && $0.isVisible && $0.className.contains("Popover") }
    }
    try await Task.sleep(for: .milliseconds(700))
    MacCapture.shot(popover, theme: theme, to: folder + "/\(MacCapture.name)-popover.png")
    shot("popover-janela")
    // The run ends with the popover open: the server no longer lists the root as running, both reads follow it,
    // and the pill leaves with its popover.
    progressEnded = true
    conversation.revalidate()
    await store.reload()
    try await wait("pílula e popover sumiram") {
      ConversationProgressPill.shown == nil && !conversation.executing && !popover.isVisible ? true : nil
    }
    try await wait("linha sem Progresso") {
      store.rows.first { $0.id == MacFixture.rootID }.map { $0.progress == nil ? true : nil } ?? nil
    }
    try await Task.sleep(for: .milliseconds(600))
    shot("fim")
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
