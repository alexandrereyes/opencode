#if DEBUG
import AppKit
import AVFoundation
import OpenCodeKit
import SwiftUI

/// Deterministic checks and captures in the closed Mac fixture, never the microphone or a provider.
@MainActor enum MacVoiceChecks {
  static var enabled: Bool {
    MacLaunch.fixture && MacFixture.value("-OpenCodeServerURL") == "http://127.0.0.1:4203"
  }
  static func prepare(_ draft: ConversationDraft) {
    guard enabled, DictationFixtures.mode == "fake" else { return }
    let transcription = TranscriptionController(source: DictationFixtureSource(), engine: DictationFixtureEngine(),
      monitorsNetwork: false)
    draft.recordingFactory = {
      VoiceRecordingComposer(file: $0, capture: DictationFixtureCapture(), transcription: transcription)
    }
  }

  static func run(_ runtime: MacWindowRuntime, openWindow: OpenWindowAction) async throws {
    guard enabled, let sessions = runtime.store else { return }
    let audio = runtime.app.audio
    let target = MacWindowTarget(sessionID: runtime.selection.sessionID)
    openWindow(id: "main", value: target)
    try await wait { runtime.app.windows[target.id]?.window != nil }
    guard let second = runtime.app.windows[target.id], let secondWindow = second.window else { throw Failure("segunda janela") }
    secondWindow.setFrame(NSRect(x: -6500, y: 40, width: 1500, height: 940), display: true)
    runtime.window?.makeKeyAndOrderFront(nil)
    // Locked desktops do not emit key-window transitions. Deliver the real AppKit connection notification.
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: runtime.window)
    try require(runtime.app.front === runtime && second.store === sessions, "serviço único e janela da frente")
    let conversation = sessions.conversation(MacFixture.rootID)
    let input = runtime.input(conversation)
    let other = second.input(conversation)
    try await wait { other.draft.input?.window != nil && input.draft.input?.window != nil }
    try require(input !== other && input.draft !== other.draft && input.readAloud !== other.readAloud,
      "áudio e compositor independentes na mesma sessão")
    let untouched = other.draft.document
    print("MacVoice microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
    if let root = MacFixture.value("-OpenCodeMacParakeetRoot") {
      try await checkParakeet(root: URL(fileURLWithPath: root))
    }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeMacReadAloudFixture"),
      let conversation = sessions.liveConversation(MacFixture.rootID),
      let message = conversation.messages.last(where: { !$0.responseText.isEmpty }),
      let response = ReadAloud.response(conversation.messages, endingAt: message.id, sessionID: conversation.id) {
      input.readAloud.read(response, title: "Resposta de demonstração", client: try speechClient(sessions))
      try await wait { input.readAloud.active?.phase == .playing }
      input.readAloud.active?.pause()
      try require(other.readAloud.active == nil, "player só na janela de origem")
    }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeVoiceBarExpanded") { runtime.voicePresentation.expanded = true }
    try require(!second.voicePresentation.expanded, "expansão independente")
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeVoiceFixture") {
      audio.voice.start(sessions: sessions)
      try await wait { audio.voice.state.masterWorking }
      let call = audio.voice.sessionID
      second.app.audio.voice.start(sessions: sessions)
      try require(call == audio.voice.sessionID, "sem segunda chamada")
      try require(audio.voice.state.phase == .listening, "motor falso conectado")
      second.voicePresentation.mute(audio.voice)
      try require(audio.voice.state.muted, "mudo compartilhado")
      audio.voice.mute()
      await audio.voice.end()
      try require(!audio.voice.state.visible, "encerramento")
      audio.voice.start(sessions: sessions)
      try await wait { audio.voice.state.masterWorking }
      runtime.voicePresentation.expanded = true
    }
    guard let action = MacFixture.value("-OpenCodeMacDictationAction"), DictationFixtures.mode == "fake" else { return }
    let draft = input.draft
    try await wait { draft.input?.window != nil }
    let token = ComposerToken(kind: .agent, id: "explore", text: "@explore")
    draft.text = ComposerDocument(text: "Revise com @explore", tokens: [.init(start: 11, end: 19, token: token)]).attributed
    draft.selection = NSRange(location: draft.editorText.length, length: 0)
    let tokens = draft.document.tokens
    try require(tokens.count == 1, "token de entrada")
    try await wait { draft.input?.textStorage.string == draft.editorText.string }
    let recording = draft.recording
    if audio.voice.state.visible { await audio.voice.end() }
    // Use the real AppKit target, including its coordinate conversion and hold timer.
    guard let window = draft.input?.window, let root = window.contentView else { throw Failure("editor ausente") }
    func targets(_ view: NSView) -> [VoiceRecordingTouchTarget.TouchView] {
      (view as? VoiceRecordingTouchTarget.TouchView).map { [$0] } ?? view.subviews.flatMap(targets)
    }
    guard let target = targets(root).first(where: { $0.available }) else { throw Failure("microfone ausente") }
    let origin = target.convert(NSPoint(x: 20, y: 20), to: nil)
    func mouse(_ kind: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
      guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
        throw Failure("evento AppKit")
      }
      return event
    }
    target.mouseDown(with: try mouse(.leftMouseDown, origin))
    try await wait { recording.state == .recording }
    try require(recording.gesture.state == .holding, "grava no primeiro clique")
    target.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: origin.x, y: origin.y + 90)))
    target.mouseUp(with: try mouse(.leftMouseUp, origin))
    try require(recording.gesture.state == .locked, "arrastar para cima trava")
    try await wait { recording.elapsed >= 1.1 }
    if action == "recording" { return }
    NotificationCenter.default.post(name: .macAudioDeviceChanged, object: nil)
    try require(recording.state == .paused, "troca de dispositivo pausa sem perder a gravação")
    try await wait { recording.previewReady }
    try require(recording.state == .paused && recording.previewDuration > 1, "pré-escuta PCM")
    if action == "paused" { return }
    let before = draft.document.text
    recording.finish()
    try await wait { recording.state == .idle }
    try require(draft.document.text.contains(DictationFixtures.text), "transcrição inserida")
    try require(draft.document.text.hasPrefix(before), "texto anterior preservado")
    try require(draft.document.tokens == tokens, "token preservado")
    try require(other.draft.document == untouched && !other.draft.recording.visible && !other.draft.expanded,
      "ditado e revisão não vazam para a outra janela")
    try require(!FileManager.default.fileExists(atPath: recording.file.path), "áudio removido depois da inserção")
    if action == "review" { return }
    draft.expanded = false
    try await wait { window.attachedSheet == nil && targets(root).contains(where: { $0.available }) }
    guard let next = targets(root).first(where: { $0.available }) else { throw Failure("microfone após revisão") }
    next.mouseDown(with: try mouse(.leftMouseDown, origin))
    try await wait { recording.state == .recording }
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    try await wait { recording.state == .idle && !recording.discarding && targets(root).contains(where: { $0.available }) }
    // The cancelled pointer must not trap the next click in the old hold.
    guard let recovered = targets(root).first(where: { $0.available }) else { throw Failure("microfone após cancelamento") }
    recovered.mouseDown(with: try mouse(.leftMouseDown, origin))
    try await wait { recording.state == .recording }
    recovered.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: origin.x - 110, y: origin.y)))
    recovered.mouseUp(with: try mouse(.leftMouseUp, origin))
    try await wait { recording.state == .idle && !recording.discarding }
    try await checkPlayback(sessions)
    // The shortcut is delivered by the front editor, not by the shared Session.
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: secondWindow)
    guard let editor = other.draft.input?.textView, let key = NSEvent.keyEvent(with: .keyDown,
      location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: secondWindow.windowNumber,
      context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else {
      throw Failure("atalho do editor")
    }
    editor.keyDown(with: key)
    try await wait { other.draft.recording.state == .recording }
    try require(!draft.recording.visible, "atalho só na janela da frente")
    other.draft.recording.discard()
    runtime.app.revealVoice()
    try require(runtime.app.front === second, "notificação mantém o destino da janela da frente")
    print("MacVoiceChecks ok: hold, lock, device change, PCM, insertion, cancellation, next click, server-voice player")
  }

  private static func checkPlayback(_ sessions: SessionStore) async throws {
    let client = try speechClient(sessions)
    let response = ReadAloud.pieces(ReadAloud.segments(await ResponseMarkdownCache.shared.parse("Áudio de teste.")))
    let player = ReadAloudPlayer(title: "Teste", path: "fixture:voice", pieces: response, client: client)
    await player.restore()
    player.play()
    try await wait { player.phase == .playing || { if case .failed = player.phase { true } else { false } }() }
    try require(player.phase == .playing, "player toca áudio retornado pelo RPC")
    player.pause()
    player.cycleRate()
    player.seek(to: 0.5)
    try require(player.phase == .paused && player.position == 0.5, "pausa e busca")
    player.stop()
    try require(player.closed, "player fecha")
  }

  private static func speechClient(_ sessions: SessionStore) throws -> OpenCodeClient {
    guard let file = Bundle.main.url(forResource: "dictation-fixture", withExtension: "caf") else { throw Failure("PCM ausente") }
    let data = try Data(contentsOf: file)
    return OpenCodeClient.inMemory(configuration: sessions.client.configuration) { request in
      switch request.url?.lastPathComponent {
      case "info": return #"{"output":{"model":"fixture","voice":"Kore","maxCharacters":1500,"charactersPerSecond":14,"usdPerSecond":0}}"#
      case "getPosition": return #"{"output":{"position":null}}"#
      case "synthesize": return "{\"output\":{\"audio\":\"\(data.base64EncodedString())\"}}"
      default: return #"{"output":{}}"#
      }
    }
  }

  /// Opt-in, recorded Portuguese through the production downloader, checksum installer, decoder and model.
  /// The caller supplies a private model directory; no installed app's models or drafts are touched.
  private static func checkParakeet(root: URL) async throws {
    let source = TranscriptionDownloader(files: TranscriptionModelFiles(root: root, manifest: .parakeetUltra))
    let transcription = TranscriptionController(source: source, monitorsNetwork: false)
    transcription.download(cellular: true)
    try await wait(seconds: 600) { transcription.status == .ready || { if case .failed = transcription.status { true } else { false } }() }
    try require(transcription.status == .ready, "download Parakeet: \(transcription.label)")
    guard let fixture = Bundle.main.url(forResource: "dictation-fixture", withExtension: "caf") else { throw Failure("PCM ausente") }
    var text = ""
    let job = DictationJob(file: fixture) { text = $0 }
    transcription.enqueue(job)
    try await wait(seconds: 180) { job.state == .done || { if case .failed = job.state { true } else { false } }() }
    try require(job.state == .done && text.localizedCaseInsensitiveContains("sessões") && text.localizedCaseInsensitiveContains("revisão"),
      "inferência Parakeet: \(text)")
    let report: [String: JSONValue] = ["text": .string(text),
      "loadSeconds": transcription.loadSeconds.map(JSONValue.number) ?? .null,
      "inferenceSeconds": transcription.transcriptionSeconds.map(JSONValue.number) ?? .null,
      "audioSeconds": transcription.audioSeconds.map(JSONValue.number) ?? .null]
    try JSONEncoder().encode(report).write(to: root.appending(path: "verification.json"))
    transcription.setActive(false)
    await source.stop()
    print("MacParakeet ok: \(text)")
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
  }
  private static func wait(seconds: Double = 15, line: UInt = #line, _ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !ready() {
      if ContinuousClock.now > deadline { throw Failure("tempo esgotado na linha \(line)") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
}
#endif
