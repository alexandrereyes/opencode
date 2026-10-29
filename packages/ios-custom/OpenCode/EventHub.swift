import Foundation
import OpenCodeKit

/// The app owns one connection; screens only subscribe to its decoded frames.
@MainActor final class EventHub {
  struct Frame: Sendable {
    let sequence: Int
    let event: ServerEvent
    let receivedAt: Double
  }
  private var subscribers: [UUID: AsyncStream<Frame>.Continuation] = [:]
  private(set) var sequence = 0
  private(set) var connection = 0
  private(set) var connected = false
  private let client: OpenCodeClient
  init(client: OpenCodeClient) { self.client = client }
  func events() -> AsyncStream<Frame> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
      subscribers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
      }
    }
  }
  func run() async {
    var delay = 1
    while !Task.isCancelled {
      do {
        for try await event in client.events() {
          if case .connected = event {
            delay = 1
            connection += 1
            connected = true
            #if os(iOS)
            DeviceAgent.shared.connected(client)
            AgentsActivityAgent.shared.connected(client)
            SessionNotificationAgent.shared.connected(client)
            #elseif os(macOS)
            MacDataAgent.shared.connected(client)
            #endif
          }
          // iPhone data requests go to the device agent only; they must not trigger screen reloads.
          if case .update(let update) = event, update.type.hasPrefix("rpc.custom.device.") {
            #if os(iOS)
            DeviceAgent.shared.receive(update, client: client)
            #endif
            continue
          }
          // Mac data requests likewise go to the Mac's agent only.
          if case .update(let update) = event, update.type.hasPrefix("rpc.custom.mac.") {
            #if os(macOS)
            MacDataAgent.shared.receive(update, client: client)
            #endif
            continue
          }
          // The Live Activity state is not a screen change either.
          if case .update(let update) = event, update.type.hasPrefix("rpc.custom.live-activity.") {
            #if os(iOS)
            AgentsActivityAgent.shared.receive(update, client: client)
            #endif
            continue
          }
          publish(event)
        }
      } catch { if Task.isCancelled { break } }
      connected = false
      connection += 1
      #if os(iOS)
      DeviceAgent.shared.disconnected(stopped: false)
      #elseif os(macOS)
      MacDataAgent.shared.disconnected(stopped: false)
      #endif
      publish(.disconnected)
      do { try await Task.sleep(for: .seconds(delay)) } catch { break }
      delay = min(delay * 2, 15)
    }
    connected = false
    connection += 1
    #if os(iOS)
    DeviceAgent.shared.disconnected(stopped: true)
    #elseif os(macOS)
    MacDataAgent.shared.disconnected(stopped: true)
    #endif
    publish(.disconnected)
  }
  #if DEBUG
  /// Fixtures without a server feed synthetic events through the same path as the connection's.
  func inject(_ event: ServerEvent) { publish(event) }
  #endif
  private func publish(_ event: ServerEvent) {
    sequence += 1
    let receivedAt = Date.now.timeIntervalSince1970 * 1000
    for continuation in subscribers.values {
      // A slow screen must revalidate rather than silently retaining an incomplete delta history.
      if case .dropped = continuation.yield(
        Frame(sequence: sequence, event: event, receivedAt: receivedAt))
      {
        continuation.yield(Frame(sequence: sequence, event: .connected, receivedAt: receivedAt))
      }
    }
  }
}
