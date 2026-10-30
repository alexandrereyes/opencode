#if DEBUG
import AppKit
import OpenCodeKit
import SwiftUI

/// Offline checks of the adjustment round (A1–A20) on the production views, driven through AppKit events in the
/// closed fixture: `-OpenCodeMacAjustes composer|question|quote|image|viewer|archived|numbers|width|dictation|divider|edge`. Each
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
      case "viewer": try await viewer(window: window, theme: theme, folder: folder)
      case "archived": try await archived(window: window, shot: shot)
      case "numbers": try await numbers(window: window, runtime: runtime)
      case "width": try await width(window: window, runtime: runtime, shot: shot)
      case "dictation": try await dictation(window: window, runtime: runtime, shot: shot)
      case "jump": try await jump(window: window, runtime: runtime, shot: shot)
      case "master": try await master(window: window, runtime: runtime, shot: shot)
      case "divider": try await divider(window: window, runtime: runtime)
      case "edge": try await edge(window: window, shot: shot)
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
      views(window).compactMap { $0 as? ComposerTextNSView }.first {
        $0.accessibilityIdentifier() == "question-reply" && $0.window != nil && $0.visibleRect.height > 4
      }
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
    try await Task.sleep(for: .milliseconds(500))
    let after = clip.convert(spot, from: nil)
    try expect(abs(scroll.magnification - 1) < 0.001 && hypot(after.x - target.x, after.y - target.y) < 1,
      "o duplo clique não foi a 100% no ponto \(target) → \(after)")
    viewer.sendEvent(mouse(.leftMouseDown, at: spot, in: viewer, clicks: 2))
    viewer.sendEvent(mouse(.leftMouseUp, at: spot, in: viewer, clicks: 2))
    try await Task.sleep(for: .milliseconds(500))
    try expect(abs(scroll.magnification - small) < 0.002, "o segundo duplo clique não voltou ao ajuste")

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
