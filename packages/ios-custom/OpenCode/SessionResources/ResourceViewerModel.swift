import Observation
import OpenCodeKit
import UIKit

/// One open resource viewer: the hub stream (WebSocket), control (take/return) and input. Kind views read `image`
/// for JPEG/PNG streams or install `rawFrames` for other formats (H.264), and send input with `send(_:)`.
/// Specification: `packages/plugin-app-custom/docs/resources.md`.
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
  private(set) var connected = false
  private(set) var failure: String?
  private(set) var busy = false
  var controlsVisible = true
  var keyboardVisible = false
  /// Traits of the hidden keyboard field, set by the kind (Chrome follows the page's focused field).
  var keyboardStyle = ResourceKeyboardStyle()
  /// Frames the shell cannot draw itself (for example H.264); the kind view decodes them.
  @ObservationIgnored var rawFrames: ((ResourceFrame) -> Void)?

  @ObservationIgnored let client: OpenCodeClient
  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private var connection: Task<Void, Never>?
  @ObservationIgnored private var pinger: Task<Void, Never>?
  @ObservationIgnored private var decoding = false
  @ObservationIgnored private var pendingFrame: Data?
  @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

  init(resource: SessionResource, client: OpenCodeClient) {
    self.resource = resource
    self.client = client
  }

  var inControl: Bool { holder == .me }
  /// "iPhone 17 · ao vivo · 38 ms".
  var status: String {
    let device = resource.meta.device ?? resource.kind.title
    guard connected else { return "\(device) · conectando…" }
    return [device, "ao vivo", latency.map { "\($0) ms" }].compactMap { $0 }.joined(separator: " · ")
  }

  func start() {
    guard connection == nil else { return }
    connection = Task { [weak self] in await self?.run(control: false) }
  }

  func stop() {
    connection?.cancel()
    connection = nil
    pinger?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    connected = false
  }

  /// "Assumir controle": the agent's commands on this resource are refused until `giveBack()` or 2 minutes idle.
  func takeControl() async {
    busy = true
    defer { busy = false }
    do {
      let result = try await client.resourceControl(resource.id, .take)
      resource = result.resource
      guard let ticket = result.ticket else { return }
      reconnect(with: ticket)
      holder = .me
      controlsVisible = false
      Haptics.play(.success)
    } catch { failure = "Não foi possível assumir o controle." }
  }

  /// "Devolver": the agent may use the resource again and its session is told to re-check the screen.
  func giveBack() async {
    busy = true
    defer { busy = false }
    keyboardVisible = false
    do {
      resource = try await client.resourceControl(resource.id, .release).resource
      holder = .agent
      controlsVisible = true
      reconnect(with: nil)
    } catch { failure = "Não foi possível devolver o controle." }
  }

  func send(_ events: [ResourceInput]) {
    guard inControl, let socket, !events.isEmpty else { return }
    struct Message: Encodable { let type = "input"; let events: [ResourceInput] }
    guard let data = try? JSONEncoder().encode(Message(events: events)), let text = String(data: data, encoding: .utf8)
    else { return }
    socket.send(.string(text)) { _ in }
  }

  private func reconnect(with ticket: ResourceTicket?) {
    connection?.cancel()
    pinger?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    connection = Task { [weak self] in await self?.run(control: ticket != nil, ticket: ticket) }
  }

  private func run(control: Bool, ticket given: ResourceTicket? = nil) async {
    var delay = 1.0
    var first = given
    while !Task.isCancelled {
      do {
        let ticket: ResourceTicket
        if let first {
          ticket = first
        } else if control {
          guard let renewed = try await client.resourceControl(resource.id, .renew).ticket else {
            holder = .agent
            return await run(control: false)
          }
          ticket = renewed
        } else {
          ticket = try await client.resourceTicket(resource.id)
        }
        first = nil
        guard let url = client.resourceURL(ticket, "stream", websocket: true) else { return }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        socket = task
        task.resume()
        failure = nil
        startPinging(task)
        try await receive(task)
      } catch {
        if Task.isCancelled { return }
        connected = false
        if failure == nil { failure = "Sem conexão com o recurso; tentando de novo…" }
      }
      if Task.isCancelled { return }
      try? await Task.sleep(for: .seconds(delay))
      delay = min(delay * 2, 10)
      if let refreshed = try? await client.resource(resource.id) { resource = refreshed }
    }
  }

  private func receive(_ task: URLSessionWebSocketTask) async throws {
    while !Task.isCancelled {
      let message = try await task.receive()
      // A replaced socket (control taken or given back) may still deliver one late message.
      guard task === socket else { return }
      switch message {
      case .string(let text):
        connected = true
        guard let message = try? JSONDecoder().decode(ResourceServerMessage.self, from: Data(text.utf8)) else { continue }
        handle(message)
      case .data(let data):
        connected = true
        guard let frame = ResourceFrame(data) else { continue }
        draw(frame)
      @unknown default: continue
      }
    }
  }

  private func handle(_ message: ResourceServerMessage) {
    switch message {
    case .hello(let format, let width, let height, _, _): hello = (format, width, height)
    case .pong(let sent, _): latency = Int((Date.now.timeIntervalSince1970 * 1000 - sent).rounded())
    case .control(let holder, let expiresAt, let mine):
      let next: Holder = holder == nil ? .agent : mine ? .me : .elsewhere
      if self.holder == .me, next != .me {
        controlsVisible = true
        keyboardVisible = false
      }
      self.holder = next
      controlExpiresAt = expiresAt
    case .meta(let value): meta.merge(value) { $1 }
    case .error(let message) where message == "not_in_control": holder = holder == .me ? .agent : holder
    case .error, .unknown: break
    case .end: connected = false
    }
  }

  private func draw(_ frame: ResourceFrame) {
    guard let format = hello?.format, format == "jpeg" || format == "png" else {
      rawFrames?(frame)
      return
    }
    decode(frame.payload)
  }

  /// One decode at a time; frames arriving meanwhile replace each other, so the newest one is always drawn last
  /// (a burst's final frame or a sharp still after scrolling is never dropped).
  private func decode(_ payload: Data) {
    guard !decoding else {
      pendingFrame = payload
      return
    }
    decoding = true
    Task.detached(priority: .userInitiated) {
      let image = UIImage(data: payload)?.preparingForDisplay()
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.decoding = false
        if let image { self.image = image }
        if let next = self.pendingFrame {
          self.pendingFrame = nil
          self.decode(next)
        }
      }
    }
  }

  private func startPinging(_ task: URLSessionWebSocketTask) {
    pinger?.cancel()
    pinger = Task { [weak self] in
      while !Task.isCancelled {
        let now = Date.now.timeIntervalSince1970 * 1000
        task.send(.string(#"{"type":"ping","t":\#(now)}"#)) { _ in }
        try? await Task.sleep(for: .seconds(2))
        if self == nil { return }
      }
    }
  }
}
