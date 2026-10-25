import Network
import Observation
import OpenCodeKit
import UIKit

/// One open resource viewer: the hub stream (WebSocket), control (take/return) and input. Kind views read `image`
/// for JPEG/PNG streams or install `rawFrames` for other formats (H.264), and send input with `send(_:)`.
/// Specification: `packages/plugin-app-custom/docs/resources.md`.
///
/// Connection lifecycle: one socket at a time, numbered by `generation`; anything that arrives for an older one (a
/// late message, a decode that finishes after a reconnect) is ignored. The stream counts as live only after the
/// first frame or pong, a missed heartbeat (no pong for `heartbeatTimeout`) reconnects, and the backoff starts over
/// after a connection that worked. `finish()` ends the viewer for good: nothing reconnects afterwards, and giving
/// control back on close does not reopen the stream. Taking control upgrades the open socket (`auth`) when the hub
/// supports it, so the stream and its last frame stay.
@MainActor @Observable final class ResourceViewerModel {
  enum Holder: Equatable {
    /// Nobody holds control: the agent may use the resource.
    case agent
    /// This viewer holds control; touches go to the resource.
    case me
    /// Alexandre holds control from another viewer.
    case elsewhere
  }

  private(set) var resource: SessionResource
  private(set) var image: UIImage?
  private(set) var hello: (format: String, width: Int, height: Int)?
  private(set) var meta: [String: JSONValue] = [:]
  private(set) var holder: Holder = .agent
  private(set) var controlExpiresAt: Double?
  /// Round trip to the hub, from the stream's ping/pong.
  private(set) var latency: Int?
  /// Video: the stream answered (a frame or a pong) on the current connection.
  private(set) var connected = false
  /// Input: in control on a live connection, with no unanswered input failure.
  var inputAvailable: Bool { inControl && connected && inputIssue == nil }
  private(set) var failure: String?
  /// A short diagnosis from the adapter or about input, shown discreetly and cleared after a few seconds.
  private(set) var notice: String?
  private(set) var busy = false
  private(set) var telemetry = ResourceStreamTelemetry()
  var controlsVisible = true
  var keyboardVisible = false
  /// Traits of the hidden keyboard field, set by the kind (Chrome follows the page's focused field).
  var keyboardStyle = ResourceKeyboardStyle()
  /// Window frames of floating controls over the screen; touches there never reach the resource.
  @ObservationIgnored var exclusions: [String: CGRect] = [:]
  /// Frames the shell cannot draw itself (for example H.264); the kind view decodes them.
  @ObservationIgnored var rawFrames: ((ResourceFrame) -> Void)?
  /// Closes the viewer by clearing its presentation (the X button).
  @ObservationIgnored var close: (() -> Void)?

  @ObservationIgnored let client: OpenCodeClient
  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private var connection: Task<Void, Never>?
  @ObservationIgnored private var pinger: Task<Void, Never>?
  @ObservationIgnored private var noticeTimer: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var decoding = false
  @ObservationIgnored private var pendingFrame: (frame: ResourceFrame, received: Double)?
  @ObservationIgnored private var received = 0
  @ObservationIgnored private var lastAnswer = Date.distantPast
  @ObservationIgnored private var features: (ack: Bool, auth: Bool, profiles: [String])?
  /// Whether this viewer wants control; reconnections renew it instead of asking for a view ticket.
  @ObservationIgnored private var wantsControl = false
  @ObservationIgnored private var finished = false
  /// Between asking for control and the socket carrying the control ticket, the hub announces our own take as held
  /// "elsewhere" (the socket is still a viewer's); those announcements are ignored.
  @ObservationIgnored private var taking = false
  @ObservationIgnored private var inputIssue: String?
  @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
  @ObservationIgnored private let path = NWPathMonitor()
  /// `economy` on cellular or Low Data Mode, `standard` otherwise.
  @ObservationIgnored private var profile = "standard"

  static let heartbeat: Duration = .seconds(2)
  static let heartbeatTimeout: TimeInterval = 7

  init(resource: SessionResource, client: OpenCodeClient) {
    self.resource = resource
    self.client = client
  }

  var inControl: Bool { holder == .me }
  /// Clockwise turn that shows the frame upright, from the stream's `meta.rotation` (iOS Simulator in landscape).
  /// Frames and touches stay in the unrotated frame; `ResourceFrameView` and `ResourceTouchOverlay` apply it.
  /// Adapters whose frames already arrive upright (Android) report their orientation as `meta.orientation` instead.
  var rotation: Int {
    guard case .number(let degrees) = meta["rotation"] else { return 0 }
    return ResourceScreenGeometry.normalized(Int(degrees))
  }
  /// In control, touches on the screen go to the resource (except on floating controls, see `exclusions`); otherwise
  /// a tap on the screen toggles the controls.
  var touching: Bool { inControl }
  /// "iPhone 17 · ao vivo · 38 ms": how old the picture on screen was when shown (capture → screen) while frames
  /// flow, otherwise the hub round trip.
  var status: String {
    let device = resource.meta.device ?? resource.kind.short
    guard connected else { return "\(device) · conectando…" }
    let now = Date.now.timeIntervalSince1970 * 1000
    let age = telemetry.flowing(now: now) ? telemetry.presentationAge : nil
    return [device, "ao vivo", (age.map { Int($0.rounded()) } ?? latency).map { "\($0) ms" }].compactMap { $0 }
      .joined(separator: " · ")
  }
  /// The stream's measurements, one per line, for the status pill's menu and VoiceOver.
  var statusDetails: [String] {
    let ms = { (value: Double?) in value.map { "\(Int($0.rounded())) ms" } ?? "—" }
    var lines = [
      "Atraso do quadro na tela: \(ms(telemetry.presentationAge))",
      "Captura → aparelho: \(ms(telemetry.arrivalAge))",
      "Decodificação: \(ms(telemetry.decodeTime))",
      "Ida e volta: \(latency.map { "\($0) ms" } ?? "—")",
      String(format: "%.0f quadros/s · %.0f KB/s", telemetry.framesPerSecond, telemetry.kilobytesPerSecond),
      profile == "economy" ? "Qualidade: economia (rede limitada)" : "Qualidade: padrão",
    ]
    if let delivery = telemetry.delivery {
      if let capture = delivery.capture { lines.insert("Captura → hub: \(ms(capture.p50))", at: 2) }
      lines.append("Substituídos no hub: \(delivery.replaced) · descartados: \(delivery.dropped)")
    }
    return lines
  }

  func start() {
    guard connection == nil, !finished else { return }
    path.pathUpdateHandler = { [weak self] update in
      let economy = update.isConstrained || update.isExpensive
      Task { @MainActor in self?.choose(economy ? "economy" : "standard") }
    }
    path.start(queue: .main)
    connect(with: nil)
  }

  /// Stops streaming until `resume()` (the app went to the background); control is kept and renewed on resume.
  func suspend() {
    disconnect()
    connection?.cancel()
    connection = nil
  }

  /// Back in the foreground: reconnect at once, without waiting for a backoff.
  func resume() {
    guard !finished, connection == nil else { return }
    connect(with: nil)
  }

  /// The viewer closed: stop for good and, if it held control, give it back without reopening the stream.
  func finish() {
    guard !finished else { return }
    finished = true
    path.cancel()
    suspend()
    noticeTimer?.cancel()
    guard inControl || wantsControl else { return }
    wantsControl = false
    holder = .agent
    let client = client
    let id = resource.id
    Task { _ = try? await client.resourceControl(id, .release) }
  }

  /// "Assumir controle": the agent's commands on this resource are refused until `giveBack()` or 2 minutes idle.
  func takeControl() async {
    busy = true
    taking = true
    defer { busy = false }
    do {
      let result = try await client.resourceControl(resource.id, .take)
      resource = result.resource
      guard let ticket = result.ticket, !finished else {
        taking = false
        return
      }
      wantsControl = true
      if features?.auth == true, let socket, connected {
        // Same socket, same stream: only its authorization changes.
        transmit(.auth(ticket.ticket), on: socket)
      } else {
        connect(with: ticket)
      }
      holder = .me
      inputIssue = nil
      controlsVisible = false
      Haptics.play(.success)
    } catch {
      taking = false
      failure = "Não foi possível assumir o controle."
    }
  }

  /// "Devolver": the agent may use the resource again and its session is told to re-check the screen. The stream
  /// keeps running; older hubs, whose sockets cannot change authorization, get a fresh view connection.
  func giveBack() async {
    busy = true
    defer { busy = false }
    keyboardVisible = false
    wantsControl = false
    do {
      resource = try await client.resourceControl(resource.id, .release).resource
      holder = .agent
      controlsVisible = true
      if features?.auth != true, !finished { connect(with: nil) }
    } catch { failure = "Não foi possível devolver o controle." }
  }

  func send(_ events: [ResourceInput]) {
    guard inControl, let socket, !events.isEmpty else { return }
    transmit(.input(events), on: socket)
  }

  private func choose(_ next: String) {
    guard next != profile else { return }
    profile = next
    if let socket, features?.profiles.contains(next) == true { transmit(.profile(next), on: socket) }
  }

  /// Sends one message; a failed send means the connection is gone, so input is marked unavailable and the socket is
  /// dropped to reconnect. Message contents (typed text) never reach logs or notices.
  private func transmit(_ message: ResourceClientMessage, on task: URLSessionWebSocketTask) {
    guard let text = message.text else { return }
    let current = generation
    task.send(.string(text)) { [weak self] error in
      guard error != nil else { return }
      Task { @MainActor in
        guard let self, self.generation == current else { return }
        if case .input = message { self.report(input: "Sem conexão para enviar ao recurso; reconectando…") }
        task.cancel(with: .abnormalClosure, reason: nil)
      }
    }
  }

  private func disconnect() {
    generation += 1
    pinger?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    connected = false
    decoding = false
    pendingFrame = nil
    features = nil
  }

  private func connect(with ticket: ResourceTicket?) {
    connection?.cancel()
    disconnect()
    connection = Task { [weak self] in await self?.run(ticket: ticket) }
  }

  private func run(ticket given: ResourceTicket?) async {
    var delay = 1.0
    var first = given
    while !Task.isCancelled, !finished {
      var worked = false
      do {
        let ticket: ResourceTicket
        if let first {
          ticket = first
        } else if wantsControl {
          if let renewed = try await client.resourceControl(resource.id, .renew).ticket {
            ticket = renewed
          } else {
            wantsControl = false
            holder = .agent
            ticket = try await client.resourceTicket(resource.id)
          }
        } else {
          ticket = try await client.resourceTicket(resource.id)
        }
        first = nil
        guard !Task.isCancelled, !finished, let url = client.resourceURL(ticket, "stream", websocket: true) else { return }
        disconnect()
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        socket = task
        received = 0
        lastAnswer = .now
        task.resume()
        startPinging(task, generation: generation)
        try await receive(task, generation: generation) { worked = true }
      } catch {
        if Task.isCancelled || finished { return }
        connected = false
        if failure == nil { failure = "Sem conexão com o recurso; tentando de novo…" }
      }
      if Task.isCancelled || finished { return }
      // A connection that delivered something starts the backoff over.
      if worked { delay = 1 }
      try? await Task.sleep(for: .seconds(delay))
      delay = min(delay * 2, 10)
      if let refreshed = try? await client.resource(resource.id) { resource = refreshed }
    }
  }

  private func receive(_ task: URLSessionWebSocketTask, generation current: Int, worked: () -> Void) async throws {
    while !Task.isCancelled {
      let message = try await task.receive()
      // A replaced socket may still deliver one late message.
      guard current == generation else { return }
      switch message {
      case .string(let text):
        guard let message = try? JSONDecoder().decode(ResourceServerMessage.self, from: Data(text.utf8)) else { continue }
        if case .pong = message { alive(); worked() }
        handle(message, on: task)
      case .data(let data):
        alive()
        worked()
        received += 1
        if features?.ack == true { transmit(.ack(received), on: task) }
        guard let frame = ResourceFrame(data) else { continue }
        draw(frame)
      @unknown default: continue
      }
    }
  }

  private func alive() {
    lastAnswer = .now
    if !connected {
      connected = true
      failure = nil
    }
  }

  private func handle(_ message: ResourceServerMessage, on task: URLSessionWebSocketTask) {
    switch message {
    case .features(let ack, let auth, let profiles):
      features = (ack, auth, profiles)
      if profiles.contains(profile), profile != "standard" { transmit(.profile(profile), on: task) }
    case .hello(let format, let width, let height, _, _): hello = (format, width, height)
    case .pong(let sent, let hub):
      let now = Date.now.timeIntervalSince1970 * 1000
      telemetry.pong(sent: sent, hub: hub, received: now)
      latency = Int((now - sent).rounded())
    case .control(let holder, let expiresAt, let mine):
      if taking, holder != nil, !mine { return }
      if mine { taking = false }
      let next: Holder = holder == nil ? .agent : mine ? .me : .elsewhere
      if self.holder == .me, next != .me {
        controlsVisible = true
        keyboardVisible = false
        wantsControl = false
      }
      self.holder = next
      controlExpiresAt = expiresAt
    case .meta(let value): meta.merge(value) { $1 }
    case .stats(let stats): telemetry.report(stats)
    case .notice(let text): show(text)
    case .error("not_in_control"):
      if holder == .me { holder = .agent }
    case .error("input_failed"): report(input: "O recurso não aplicou o último comando.")
    case .error("input_overflow"): report(input: "Comandos demais na fila; alguns foram ignorados.")
    case .error("invalid_ticket"):
      // The upgrade was refused: reconnect, renewing control if it is still ours.
      taking = false
      connect(with: nil)
    case .error("invalid message"): break
    case .error(let text): show(text)
    case .end(let reason) where reason != "ended":
      connected = false
      show(reason)
    case .end: connected = false
    case .unknown: break
    }
  }

  private func report(input text: String) {
    inputIssue = text
    show(text)
  }

  private func show(_ text: String) {
    guard !text.isEmpty else { return }
    notice = text
    noticeTimer?.cancel()
    noticeTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.notice = nil
      self?.inputIssue = nil
    }
  }

  private func draw(_ frame: ResourceFrame) {
    guard let format = hello?.format, format == "jpeg" || format == "png" else {
      rawFrames?(frame)
      return
    }
    decode(frame, received: Date.now.timeIntervalSince1970 * 1000)
  }

  /// One decode at a time; frames arriving meanwhile replace each other, so the newest one is always drawn last
  /// (a burst's final frame or a sharp still after scrolling is never dropped). Decodes from an older connection
  /// are discarded.
  private func decode(_ frame: ResourceFrame, received: Double) {
    guard !decoding else {
      pendingFrame = (frame, received)
      return
    }
    decoding = true
    let current = generation
    let payload = frame.payload
    Task.detached(priority: .userInitiated) {
      let image = UIImage(data: payload)?.preparingForDisplay()
      await MainActor.run { [weak self] in
        guard let self, self.generation == current else { return }
        self.decoding = false
        if let image {
          self.image = image
          self.telemetry.frame(
            bytes: payload.count, captured: frame.capturedAt, received: received,
            presented: Date.now.timeIntervalSince1970 * 1000)
        }
        if let next = self.pendingFrame {
          self.pendingFrame = nil
          self.decode(next.frame, received: next.received)
        }
      }
    }
  }

  /// Pings every `heartbeat`; without a frame or pong for `heartbeatTimeout` the socket is dropped and reconnects.
  private func startPinging(_ task: URLSessionWebSocketTask, generation current: Int) {
    pinger?.cancel()
    pinger = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.generation == current else { return }
        if Date.now.timeIntervalSince(self.lastAnswer) > Self.heartbeatTimeout {
          self.connected = false
          task.cancel(with: .abnormalClosure, reason: nil)
          return
        }
        self.transmit(.ping(t: Date.now.timeIntervalSince1970 * 1000), on: task)
        try? await Task.sleep(for: Self.heartbeat)
      }
    }
  }
}
