import AVFAudio
import Foundation
import Observation
import OpenCodeKit
import OSLog
#if os(macOS)
import AVFoundation
#endif

@MainActor @Observable final class VoiceController {
  let preferences: VoicePreferences
  let toast = ToastCenter()
  private(set) var state = VoiceState()
  private(set) var detail = ""
  private(set) var connectedAt: Date?
  private(set) var currentSpokenLine = ""
  private(set) var masterProgressLine = ""
  var elapsed: TimeInterval { connectedAt.map { max(0, Date.now.timeIntervalSince($0)) } ?? 0 }
  private(set) var sessionID: UUID?
  private(set) var busy = false
  /// Set when automatic recovery gave up; the UI offers "Tentar de novo".
  private(set) var alert: String?
  /// Whether this call's Live Activity was accepted; background recording stops without it.
  #if os(iOS)
  var liveActivityActive: Bool { activity.active }
  #endif
  #if os(macOS)
  var permissionDenied = false
  @ObservationIgnored var stateChanged: (() -> Void)?
  #endif
  @ObservationIgnored private var transport: (any VoiceTransporting)?
  @ObservationIgnored private var master: (any VoiceMasterServing)?
  @ObservationIgnored private var signaling: VoiceSignaling?
  @ObservationIgnored private var connection: Task<Void, Never>?
  @ObservationIgnored private var renewal: Task<Void, Never>?
  @ObservationIgnored private var watchdog: Task<Void, Never>?
  @ObservationIgnored private var leaseDeadline: Task<Void, Never>?
  @ObservationIgnored private var recoveryTask: Task<Void, Never>?
  @ObservationIgnored private var narrationTask: Task<Void, Never>?
  @ObservationIgnored private var delegationTask: Task<Void, Never>?
  @ObservationIgnored private var retirement: Task<Void, Never>?
  #if os(iOS)
  @ObservationIgnored private var activity = VoiceActivityDriver()
  #endif
  @ObservationIgnored private var epoch = UUID()
  /// One GPT Live call inside the conversation; a new link after each network recovery.
  @ObservationIgnored private var link = UUID()
  @ObservationIgnored private var lease = VoiceLeaseClock()
  @ObservationIgnored private var recovery = VoiceRecovery()
  @ObservationIgnored private var policy = VoiceRecoveryPolicy()
  @ObservationIgnored private var network: any VoicePathMonitoring = VoicePathMonitor()
  @ObservationIgnored private var cues: any VoiceCueing = VoiceCuePlayer()
  @ObservationIgnored private var makeTransport: (@escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) -> any VoiceTransporting = {
    VoiceTransport(event: $0)
  }
  @ObservationIgnored private var callVoice = GPTLiveVoice.defaultVoice
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
    var policy = VoiceRecoveryPolicy()
    var network: (any VoicePathMonitoring)?
    var cues: (any VoiceCueing)?
  }
  @ObservationIgnored private var testing: TestDependencies?
  convenience init(testing: TestDependencies, preferences: VoicePreferences = VoicePreferences()) {
    self.init(preferences: preferences); self.testing = testing
    policy = testing.policy; makeTransport = testing.transport
    if let network = testing.network { self.network = network }
    if let cues = testing.cues { self.cues = cues }
  }
  #endif

  init(preferences: VoicePreferences = VoicePreferences()) {
    self.preferences = preferences
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
    NotificationCenter.default.post(name: .audioCaptureWillStart, object: nil)
    callVoice = preferences.voice
    let token = UUID()
    epoch = token; sessionID = token; ready = false; mediaConnected = false
    recovery = VoiceRecovery(policy: policy); alert = nil
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
    #if os(macOS)
    let isolated = (sessions.client.configuration.url.host == "127.0.0.1" && sessions.client.configuration.url.port == 4203)
      || (MacLaunch.fixture && MacFixture.value("-OpenCodeServerURL") == "http://127.0.0.1:4203")
    #else
    let isolated = sessions.client.configuration.url.host == "127.0.0.1" && [4177, 4180, 4183].contains(sessions.client.configuration.url.port ?? -1)
    #endif
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
    #if os(macOS)
    if MacLaunch.fixture, testing == nil {
      connection = Task { await fail("Use o motor falso de voz nesta demonstração local.") }
      return
    }
    #endif
    #else
    master = VoiceMaster(sessions: sessions, update: updates)
    #endif
    network.start { [weak self] path in
      guard let self, self.epoch == token else { return }
      self.pathChanged(path)
    }
    connection = Task { [weak self] in
      guard let self else { return }
      let allowed = await permission()
      guard epoch == token, !Task.isCancelled else { return }
      guard allowed else { await fail("Permita o microfone nos Ajustes para conversar por voz."); return }
      do {
        try await open(token: token, timeout: 45, message: "A conexão de voz demorou demais. Confira o WARP e tente novamente.")
      } catch {
        guard epoch == token, !Task.isCancelled, !(error is CancellationError) else { return }
        await fail(error.localizedDescription)
      }
    }
  }
  /// Opens one GPT Live call: transport, lease reservation and offer, resuming memory as initial items.
  /// Readiness arrives later through `connected()`, before `timeout` or the link is lost.
  private func open(token: UUID, timeout: Double, message: String) async throws {
    let current = UUID()
    link = current; ready = false; mediaConnected = false; lease = VoiceLeaseClock()
    armWatchdog(token: token, seconds: timeout, message: message)
    let events: @MainActor @Sendable (VoiceTransportEvent) -> Void = { [weak self] event in
      guard let self, self.epoch == token, self.link == current else { return }
      self.receive(event)
    }
    let transport = makeTransport(events)
    self.transport = transport
    if state.muted { transport.mute(true) }
    let signal = VoiceSignaling()
    signaling = signal
    VoiceLaunchLog.record("start")
    detail = recovery.active ? "Reconectando ao serviço privado" : "Conectando ao serviço privado"; publish()
    // Turns heard before a loss must be buffered before the next call reads memory.
    await memoryEvents?.value
    guard epoch == token, link == current else { throw CancellationError() }
    // Local factory/audio setup overlaps the reservation, but no provider call is speculative.
    async let offer = transport.offer()
    async let history = memory?.prepare()
    try await renew(signal, method: "POST")
    guard epoch == token, link == current else { throw CancellationError() }
    beginRenewal(signal, token: token, link: current)
    let answer = try await signal.createCall(sdp: await offer, voice: callVoice, history: await history,
      request: { [self] in try await perform($0) })
    try Task.checkCancellation()
    guard epoch == token, link == current else { throw CancellationError() }
    callVoice = answer.voice
    try await transport.answer(answer.sdp)
    if let notice = answer.fallbackNotice { toast.show(notice, kind: .error) }
    VoiceTransport.log.notice("phase=answer-applied")
  }
  private func permission() async -> Bool {
    #if DEBUG
    if let testing { return testing.permission }
    #endif
    #if os(macOS)
    let allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
      ? true : await AVCaptureDevice.requestAccess(for: .audio)
    permissionDenied = !allowed
    return allowed
    #else
    return AVAudioApplication.shared.recordPermission == .granted
      ? true : await AVAudioApplication.requestRecordPermission()
    #endif
  }
  private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
    #if DEBUG
    if let testing { return try await testing.request(request) }
    #endif
    return try await http.data(for: request)
  }
  private func renew(_ signal: VoiceSignaling, method: String) async throws {
    let current = link
    let started = Self.now
    let (data, response) = try await perform(signal.leaseRequest(method: method))
    let confirmed = try signal.parseLease(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    guard link == current else { throw CancellationError() }
    guard lease.confirm(confirmed, requestedAt: started, now: Self.now) else {
      throw ClientError.operation("A autorização temporária da voz expirou. Reconecte.")
    }
    armLeaseDeadline(token: epoch, link: current)
  }
  /// A renewal may fail transiently while the confirmed lease still covers the call. Audio stops when the
  /// lease minus its safety margin ends, even with a renewal still in flight; refusals end the call at once.
  private func beginRenewal(_ signal: VoiceSignaling, token: UUID, link current: UUID) {
    renewal = Task { [weak self] in
      guard let self else { return }
      var delay = policy.renewal
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard epoch == token, link == current else { return }
        do {
          try await renew(signal, method: "PUT")
          delay = policy.renewal
        } catch {
          guard epoch == token, link == current, !Task.isCancelled, !(error is CancellationError) else { return }
          guard VoiceLeaseClock.isTransient(error) else {
            await fail("A autorização da voz não pôde ser renovada. A chamada foi encerrada por segurança.")
            return
          }
          VoiceTransport.log.notice("phase=renewal-retry")
          guard lease.valid(at: Self.now) else { return }
          delay = min(policy.renewalRetry, max(0, lease.validUntil - Self.now))
        }
      }
    }
  }
  private func armLeaseDeadline(token: UUID, link current: UUID) {
    leaseDeadline?.cancel()
    let remaining = lease.validUntil - Self.now
    leaseDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, remaining))) } catch { return }
      guard let self, epoch == token, link == current else { return }
      lose("A autorização da voz expirou sem rede. Reconectando…")
    }
  }
  private func armWatchdog(token: UUID, seconds: Double, message: String) {
    watchdog?.cancel()
    let current = link
    watchdog = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      guard let self, epoch == token, link == current else { return }
      lose(message)
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
      mediaConnected = false; state.apply(network.current.satisfied ? .reconnect : .offline); publish()
      // WebRTC may restore the same path by itself; after the grace the call is rebuilt.
      armWatchdog(token: epoch, seconds: policy.mediaGrace, message: "A conexão de áudio não se recuperou.")
    case .failed: lose("A conexão de áudio foi encerrada.")
    case .data(let data):
      do { handle(try VoiceProtocol.decode(data)) }
      catch { Task { await fail(error.localizedDescription) } }
    }
  }
  private func connected() {
    #if os(macOS)
    if connectedAt == nil { cues.play(.started) }
    #endif
    if connectedAt == nil { connectedAt = .now; VoiceFeedback.ready() }
    watchdog?.cancel(); watchdog = nil
    if recovery.active {
      recovery.restore(); cues.play(.restored)
      VoiceTransport.log.notice("phase=recovered")
    }
    state.apply(.connected); detail = "Pode falar com a Sessão mestra"; publish()
    VoiceLaunchLog.record("ready")
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
  func end() async {
    #if os(macOS)
    let sounded = connectedAt != nil && state.visible
    #endif
    alert = nil; await retire(); state.apply(.end); detail = ""; publish(); VoiceLaunchLog.record("end")
    #if os(macOS)
    if sounded { cues.play(.ended) }
    #endif
  }
  func retry(sessions: SessionStore) async { await end(); start(sessions: sessions) }
  func dismissAlert() { alert = nil }
  /// Waits until a starting call listens or fails, so an intent keeps the process alive meanwhile.
  @available(macOS 26.0, *)
  func settled(within limit: Duration) async {
    let watch = Task { [weak self] in
      guard let self else { return }
      for await phase in Observations({ self.state.phase }) where phase != .connecting { return }
    }
    let deadline = Task { try? await Task.sleep(for: limit); watch.cancel() }
    await watch.value
    deadline.cancel()
  }
  private func fail(_ message: String) async {
    guard state.visible, state.phase != .failed, !busy else { return }
    VoiceLaunchLog.record("failed", detail: message)
    await retire(); state.apply(.failure(message)); detail = message; publish()
    VoiceFeedback.failed()
    #if os(macOS)
    MacNotifications.shared.voiceFailed()
    #endif
  }

  // MARK: Network recovery

  /// The current link is gone. An established conversation rebuilds the call with memory, within the
  /// recovery window; a call that never connected fails as before.
  private func lose(_ reason: String) {
    guard state.visible, state.phase != .failed, !busy else { return }
    guard connectedAt != nil else { Task { await fail(reason) }; return }
    let token = epoch
    let first = !recovery.active
    recovery.lose(at: Self.now)
    VoiceTransport.log.notice("phase=lost")
    // Invalidate every callback of the old call before tearing it down.
    link = UUID()
    if state.phase == .speaking { interruptedAssistant = true }
    if inputItemID != nil { interruptedUser = true }
    // Delegation items belong to the old call; the next call learns the master's state from memory.
    currentDelegation = nil; narration = VoiceNarration(); finalNarration = false
    ready = false; mediaConnected = false
    connection?.cancel(); renewal?.cancel(); watchdog?.cancel(); leaseDeadline?.cancel()
    connection = nil; renewal = nil; watchdog = nil; leaseDeadline = nil
    state.apply(network.current.satisfied ? .reconnect : .offline)
    detail = network.current.satisfied ? "Reconectando a voz…" : "Sem conexão. Aguardando a rede…"
    publish()
    // The waiting tone holds the audio session before the old transport releases its own credit.
    if first { cues.play(.lost) }
    let transport = transport; self.transport = nil
    let signal = signaling; signaling = nil
    recoveryTask?.cancel()
    recoveryTask = Task { [weak self] in
      await transport?.close()
      guard let self else { return }
      if let signal, let request = try? signal.leaseRequest(method: "DELETE") {
        // Best effort without blocking recovery; an unreachable proxy expires the lease itself.
        Task { _ = try? await self.perform(request) }
      }
      await reconnect(token: token)
    }
  }

  private func reconnect(token: UUID) async {
    while epoch == token, !Task.isCancelled {
      if !network.current.satisfied {
        if state.phase != .offline { state.apply(.offline); detail = "Sem conexão. Aguardando a rede…"; publish() }
        guard recovery.remaining(at: Self.now) > 0 else { break }
        do { try await Task.sleep(for: .seconds(policy.networkPoll)) } catch { return }
        continue
      }
      guard let delay = recovery.next(at: Self.now) else { break }
      state.apply(.reconnect); detail = "Reconectando a voz…"; publish()
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard epoch == token, network.current.satisfied else { continue }
      VoiceTransport.log.notice("phase=reconnect-attempt")
      do {
        try await open(token: token, timeout: policy.attemptTimeout, message: "A nova conexão de voz não ficou pronta.")
        return
      } catch {
        guard epoch == token, !Task.isCancelled, !(error is CancellationError) else { return }
        guard VoiceLeaseClock.isTransient(error) else { await fail(error.localizedDescription); return }
        await closeLink()
      }
    }
    guard epoch == token, !Task.isCancelled else { return }
    let message = "Não consegui reconectar a voz em \(Int(policy.window)) segundos. Confira a rede e o WARP."
    VoiceTransport.log.notice("phase=recovery-exhausted")
    cues.play(.failed)
    alert = message
    await fail(message)
  }

  /// Tears down a failed attempt so the next one starts from a clean link.
  private func closeLink() async {
    link = UUID()
    watchdog?.cancel(); renewal?.cancel(); leaseDeadline?.cancel()
    watchdog = nil; renewal = nil; leaseDeadline = nil
    let transport = transport; self.transport = nil
    let signal = signaling; signaling = nil
    await transport?.close()
    if let signal, let request = try? signal.leaseRequest(method: "DELETE") {
      Task { [self] in _ = try? await perform(request) }
    }
  }

  private func pathChanged(_ path: VoicePath) {
    guard state.visible, state.phase != .failed else { return }
    if !path.satisfied {
      if state.phase == .reconnecting { state.apply(.offline); detail = "Sem conexão. Aguardando a rede…"; publish() }
      return
    }
    if state.phase == .offline { state.apply(.reconnect); detail = "Reconectando a voz…"; publish() }
    // A disconnected peer will not migrate to a new interface; rebuild without waiting for the grace.
    if !recovery.active, connectedAt != nil, !mediaConnected, transport != nil {
      lose("A rede mudou. Reconectando a voz…")
    }
  }

  private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
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
    epoch = UUID(); link = UUID()
    network.stop(); recovery.restore(); cues.stop()
    connection?.cancel(); renewal?.cancel(); watchdog?.cancel(); narrationTask?.cancel(); delegationTask?.cancel()
    leaseDeadline?.cancel(); recoveryTask?.cancel()
    connection = nil; renewal = nil; watchdog = nil; narrationTask = nil; delegationTask = nil
    leaseDeadline = nil; recoveryTask = nil
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
    sessionID = nil
    #if os(iOS)
    await activity.end()
    #endif
  }
  private func publish() {
    #if os(macOS)
    stateChanged?()
    #endif
    #if os(iOS)
    #if DEBUG
    if testing != nil { return }
    #endif
    guard let id = sessionID else { return }
    activity.update(id: id, state: state, theme: theme) { [weak self] action in
      guard let self, self.sessionID == id else { return }
      if action == .end { await self.end() } else { self.mute() }
    }
    #endif
  }
}
