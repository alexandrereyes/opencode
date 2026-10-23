import AVFAudio
import Foundation
import Observation
import OpenCodeKit
import OSLog

@MainActor @Observable final class VoiceController {
  private(set) var state = VoiceState()
  private(set) var detail = ""
  private(set) var connectedAt: Date?
  private(set) var currentSpokenLine = ""
  private(set) var masterProgressLine = ""
  var elapsed: TimeInterval { connectedAt.map { max(0, Date.now.timeIntervalSince($0)) } ?? 0 }
  private(set) var sessionID: UUID?
  private(set) var busy = false
  @ObservationIgnored private var transport: (any VoiceTransporting)?
  @ObservationIgnored private var master: (any VoiceMasterServing)?
  @ObservationIgnored private var signaling: VoiceSignaling?
  @ObservationIgnored private var connection: Task<Void, Never>?
  @ObservationIgnored private var renewal: Task<Void, Never>?
  @ObservationIgnored private var watchdog: Task<Void, Never>?
  @ObservationIgnored private var narrationTask: Task<Void, Never>?
  @ObservationIgnored private var delegationTask: Task<Void, Never>?
  @ObservationIgnored private var retirement: Task<Void, Never>?
  @ObservationIgnored private var activity = VoiceActivityDriver()
  @ObservationIgnored private var epoch = UUID()
  @ObservationIgnored private var ready = false
  @ObservationIgnored private var mediaConnected = false
  @ObservationIgnored private var currentDelegation: String?
  @ObservationIgnored private var handled: Set<String> = []
  @ObservationIgnored private var delegationQueue: [(String, String)] = []
  @ObservationIgnored private var narration = VoiceNarration()
  @ObservationIgnored private var userUntil: Double = 0
  @ObservationIgnored private var finalNarration = false
  @ObservationIgnored private var theme = AppTheme.selected
  @ObservationIgnored private let http: URLSession
  @ObservationIgnored private var memory: VoiceMemoryStore?
  @ObservationIgnored private var memoryEvents: Task<Void, Never>?
  @ObservationIgnored private var inputItemID: String?
  @ObservationIgnored private var outputItemID: String?
  @ObservationIgnored private var interruptedAssistant = false
  @ObservationIgnored private var interruptedUser = false
  @ObservationIgnored private var capturedTurns: Set<String> = []
  #if DEBUG
  struct TestDependencies {
    let transport: (@escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) -> any VoiceTransporting
    let master: (@escaping @MainActor (VoiceMasterUpdate) -> Void) -> any VoiceMasterServing
    let request: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    var permission = true
    var memory: VoiceMemoryStore?
  }
  @ObservationIgnored private var testing: TestDependencies?
  convenience init(testing: TestDependencies) { self.init(); self.testing = testing }
  #endif

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 30
    http = URLSession(configuration: config)
  }
  func setTheme(_ theme: AppTheme) { self.theme = theme; publish() }
  func toggle(sessions: SessionStore) {
    guard !busy else { return }
    if state.visible { Task { await end() } } else { start(sessions: sessions) }
  }
  func start(sessions: SessionStore) {
    guard !busy, !state.visible else { return }
    let token = UUID()
    epoch = token; sessionID = token; ready = false; mediaConnected = false
    connectedAt = nil; currentSpokenLine = ""; masterProgressLine = ""
    handled = []; currentDelegation = nil; narration = VoiceNarration(); finalNarration = false
    state.apply(.start); detail = "Preparando o microfone"; publish()
    inputItemID = nil; outputItemID = nil; interruptedAssistant = false; interruptedUser = false; capturedTurns = []
    #if DEBUG
    memory = testing == nil ? sessions.voiceMemory : testing?.memory
    #else
    memory = sessions.voiceMemory
    #endif
    let updates: @MainActor (VoiceMasterUpdate) -> Void = { [weak self] update in
      guard let self, self.epoch == token else { return }
      self.receive(update)
    }
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    let isolated = sessions.client.configuration.url.host == "127.0.0.1" && [4177, 4180].contains(sessions.client.configuration.url.port ?? -1)
    let fixture = isolated && arguments.contains("-OpenCodeVoiceFixture")
    let fakeMaster = isolated && (fixture || arguments.contains("-OpenCodeVoiceFakeMaster"))
    master = testing?.master(updates) ?? (fakeMaster ? VoiceFakeMaster(update: updates) : VoiceMaster(sessions: sessions, update: updates))
    if fixture {
      connectedAt = .now; state.apply(.connected); detail = "Demonstração local"; publish()
      connection = Task { [weak self] in
        guard let self else { return }
        _ = await memory?.prepare()
        guard epoch == token else { return }
        for json in [
          #"{"type":"input_transcript.added","item":{"id":"fixture-user","text":"Confira a demonstração."}}"#,
          #"{"type":"turn.done","turn":{"id":"fixture-user-turn","role":"user","transcript":"Confira a demonstração."}}"#,
          #"{"type":"output_transcript.added","item":{"id":"fixture-assistant","text":"Vou conferir a demonstração."}}"#,
          #"{"type":"input_transcript.added","item":{"id":"fixture-barge","text":"Uma correção."}}"#,
          #"{"type":"turn.done","turn":{"id":"fixture-assistant-turn","role":"assistant","transcript":"Vou conferir a demonstração. Este é o texto canônico completo.","interrupted":true}}"#,
        ] { if let event = try? VoiceProtocol.decode(Data(json.utf8)) { handle(event) } }
        try? await self.master?.ask(VoiceMasterRequest("Demonstração"))
      }
      return
    }
    #else
    master = VoiceMaster(sessions: sessions, update: updates)
    #endif
    let events: @MainActor @Sendable (VoiceTransportEvent) -> Void = { [weak self] event in
      guard let self, self.epoch == token else { return }
      self.receive(event)
    }
    #if DEBUG
    transport = testing?.transport(events) ?? VoiceTransport(event: events)
    #else
    transport = VoiceTransport(event: events)
    #endif
    let signal = VoiceSignaling()
    signaling = signal
    connection = Task { [weak self] in
      guard let self else { return }
      do {
        let allowed = await permission()
        try Task.checkCancellation()
        guard epoch == token else { return }
        guard allowed else { throw ClientError.operation("Permita o microfone nos Ajustes para conversar por voz.") }
        armWatchdog(token: token, seconds: 45, message: "A conexão de voz demorou demais. Confira o WARP e tente novamente.")
        VoiceTransport.log.notice("phase=start")
        detail = "Conectando ao serviço privado"; publish()
        guard let transport else { throw VoiceWireError.invalidAnswer }
        // Local factory/audio setup overlaps the reservation, but no provider call is speculative.
        async let offer = transport.offer()
        async let history = memory?.prepare()
        try await renew(signal, method: "POST")
        guard epoch == token else { return }
        beginRenewal(signal, token: token)
        let request = try signal.offerRequest(sdp: await offer, history: await history)
        let (data, response) = try await perform(request)
        guard let response = response as? HTTPURLResponse else { throw VoiceWireError.invalidAnswer }
        let answer = try VoiceSignaling.parseAnswer(data, response: response)
        try Task.checkCancellation()
        guard epoch == token else { return }
        try await transport.answer(answer)
        VoiceTransport.log.notice("phase=answer-applied")
      } catch {
        guard epoch == token, !Task.isCancelled else { return }
        await fail(error.localizedDescription)
      }
    }
  }
  private func permission() async -> Bool {
    #if DEBUG
    if let testing { return testing.permission }
    #endif
    return AVAudioApplication.shared.recordPermission == .granted
      ? true : await AVAudioApplication.requestRecordPermission()
  }
  private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
    #if DEBUG
    if let testing { return try await testing.request(request) }
    #endif
    return try await http.data(for: request)
  }
  private func renew(_ signal: VoiceSignaling, method: String) async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let (data, response) = try await perform(signal.leaseRequest(method: method))
    let lease = try signal.parseLease(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    guard lease.remaining - (ProcessInfo.processInfo.systemUptime - started) > 10 else {
      throw ClientError.operation("A autorização temporária da voz expirou. Reconecte.")
    }
  }
  private func beginRenewal(_ signal: VoiceSignaling, token: UUID) {
    renewal = Task { [weak self] in
      guard let self else { return }
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(5))
          guard epoch == token else { return }
          try await renew(signal, method: "PUT")
        }
      } catch {
        guard epoch == token, !Task.isCancelled else { return }
        await fail("A autorização da voz não pôde ser renovada. A chamada foi encerrada por segurança.")
      }
    }
  }
  private func armWatchdog(token: UUID, seconds: Int, message: String) {
    watchdog?.cancel()
    watchdog = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      guard let self, epoch == token else { return }
      await fail(message)
    }
  }
  private func receive(_ event: VoiceTransportEvent) {
    switch event {
    case .connected:
      mediaConnected = true
      if ready { connected() }
    case .resumed: state.apply(.resume); publish()
    case .interrupted:
      if state.phase == .speaking { interruptedAssistant = true }
      if inputItemID != nil { interruptedUser = true }
      state.apply(.interruption); detail = "Toque em retomar após a interrupção"; publish()
    case .disconnected:
      if state.phase == .speaking { interruptedAssistant = true }
      if inputItemID != nil { interruptedUser = true }
      mediaConnected = false; state.apply(.reconnect); publish()
      armWatchdog(token: epoch, seconds: 10, message: "A conexão de áudio não se recuperou. Reconecte a chamada.")
    case .failed: Task { await fail("A conexão de áudio foi encerrada. Tente reconectar.") }
    case .data(let data):
      do { handle(try VoiceProtocol.decode(data)) }
      catch { Task { await fail(error.localizedDescription) } }
    }
  }
  private func connected() {
    if connectedAt == nil { connectedAt = .now }
    watchdog?.cancel(); watchdog = nil
    state.apply(.connected); detail = "Pode falar com a Sessão mestra"; publish()
    VoiceTransport.log.notice("phase=ready")
    if narrationTask == nil {
      narrationTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
          await self?.flushNarration()
        }
      }
    }
  }
  private func handle(_ event: VoiceEvent) {
    switch event {
    case .ready: ready = true; if mediaConnected { connected() }
    case .input(let piece):
      inputItemID = piece.id ?? inputItemID
      if state.phase == .speaking { interruptedAssistant = true }
      VoiceTransport.log.notice("phase=input-transcript")
      state.apply(.bargeIn); userUntil = ProcessInfo.processInfo.systemUptime + 2
      publish()
    case .output(let piece):
      outputItemID = piece.id ?? outputItemID
      VoiceTransport.log.notice("phase=output-transcript")
      currentSpokenLine = String((state.phase == .speaking ? currentSpokenLine + " " + piece.text : piece.text).suffix(2000))
      state.apply(.speech); publish()
    case .turnDone(let turn):
      capture(turn)
      if turn.role == .assistant { state.apply(.silence); outputItemID = nil; interruptedAssistant = false }
      else { userUntil = ProcessInfo.processInfo.systemUptime + 1; inputItemID = nil; interruptedUser = false }
      publish()
    case .failure: Task { await fail("O serviço de voz informou uma falha. Tente novamente mais tarde.") }
    case .delegation(let id, let text):
      VoiceTransport.log.notice("phase=delegation")
      guard !handled.contains(id) else { return }
      guard handled.count < 1024, delegationQueue.count < 8 else {
        Task { await fail("Há pedidos demais nesta chamada. Reconecte para continuar.") }; return
      }
      handled.insert(id); delegationQueue.append((id, text))
      if delegationTask == nil { delegationTask = Task { await pumpDelegations() } }
    case .ignored: break
    }
  }
  private func capture(_ turn: VoiceCompletedTurn) {
    guard let memory, let callID = sessionID, let text = turn.text,
      let nativeID = turn.id ?? turn.itemID ?? (turn.role == .assistant ? outputItemID : inputItemID),
      !nativeID.isEmpty, capturedTurns.insert(nativeID).inserted else { return }
    let itemID = turn.itemID ?? (turn.role == .assistant ? outputItemID : inputItemID) ?? nativeID
    let sourceID = nativeID == itemID ? itemID : nativeID + ":" + itemID
    let recorded = VoiceMemoryTurn(id: callID.uuidString + ":" + sourceID, role: turn.role, text: text,
      at: Date.now.timeIntervalSince1970 * 1000,
      interrupted: turn.interrupted || (turn.role == .assistant ? interruptedAssistant : interruptedUser))
    let previous = memoryEvents
    memoryEvents = Task {
      await previous?.value
      await memory.capture(recorded)
    }
  }
  private func pumpDelegations() async {
    let token = epoch
    defer { if epoch == token { delegationTask = nil } }
    while epoch == token, !Task.isCancelled, !delegationQueue.isEmpty {
      let request = delegationQueue.removeFirst()
      currentDelegation = request.0
      state.masterWorking = true; detail = "Enviando à Sessão mestra…"; publish()
      do { try await master?.ask(VoiceMasterRequest(request.1)) }
      catch {
        guard epoch == token, !Task.isCancelled else { return }
        receive(.failed("Não foi possível enviar o pedido à Sessão mestra. " + error.localizedDescription))
      }
    }
  }
  private func receive(_ update: VoiceMasterUpdate) {
    switch update {
    case .progress(let text): state.masterWorking = true; detail = text; masterProgressLine = text; narration.offer(text)
    case .finished(let text):
      state.masterWorking = false; detail = "A Sessão mestra concluiu"
      masterProgressLine = detail
      finalNarration = true; narration.offer("Resultado da Sessão mestra: " + text)
    case .failed(let text): state.masterWorking = false; detail = text; masterProgressLine = text; finalNarration = true; narration.offer(text)
    case .disconnected:
      detail = "Sem atualizações da mestra. Reconectando ao OpenCode…"
      masterProgressLine = detail
      narration.offer("Perdi temporariamente as atualizações da Sessão mestra. Ainda não posso confirmar o resultado.")
    }
    publish()
  }
  private func flushNarration() async {
    guard let id = currentDelegation, let transport, state.phase == .listening,
      let text = narration.take(now: ProcessInfo.processInfo.systemUptime, speaking: false,
        userUntil: userUntil, final: finalNarration) else { return }
    let token = epoch
    finalNarration = false
    do {
      for data in try VoiceProtocol.append(id: id, text: text) {
        guard epoch == token else { return }
        try await transport.send(data)
      }
    } catch {
      guard epoch == token else { return }
      await fail("Não foi possível transmitir a atualização da Sessão mestra.")
    }
  }
  func mute() { state.muted.toggle(); transport?.mute(state.muted); publish() }
  func resume() { transport?.resume() }
  func end() async { await retire(); state.apply(.end); detail = ""; publish() }
  func retry(sessions: SessionStore) async { await end(); start(sessions: sessions) }
  private func fail(_ message: String) async {
    guard state.visible, state.phase != .failed, !busy else { return }
    VoiceTransport.log.notice("phase=failed")
    await retire(); state.apply(.failure(message)); detail = message; publish()
  }
  private func retire() async {
    if let retirement { await retirement.value; return }
    busy = true
    let retirement = Task { await releaseResources() }
    self.retirement = retirement
    await retirement.value
    self.retirement = nil
    busy = false
  }
  private func releaseResources() async {
    let callID = sessionID
    let memory = memory
    epoch = UUID()
    connection?.cancel(); renewal?.cancel(); watchdog?.cancel(); narrationTask?.cancel(); delegationTask?.cancel()
    connection = nil; renewal = nil; watchdog = nil; narrationTask = nil; delegationTask = nil
    delegationQueue = []; master?.stop(); master = nil
    let transport = transport; self.transport = nil
    let signal = signaling; signaling = nil
    await transport?.close()
    if let signal, let request = try? signal.leaseRequest(method: "DELETE") {
      // Teardown precedes release. A failed DELETE is bounded by the proxy lease TTL.
      _ = try? await perform(request)
    }
    await memoryEvents?.value; memoryEvents = nil
    if let callID { await memory?.finish(callID) }
    sessionID = nil; await activity.end()
  }
  private func publish() {
    #if DEBUG
    if testing != nil { return }
    #endif
    guard let id = sessionID else { return }
    activity.update(id: id, state: state, theme: theme) { [weak self] action in
      guard let self, self.sessionID == id else { return }
      if action == .end { await self.end() } else { self.mute() }
    }
  }
}
