import Foundation
import OpenCodeKit

/// The app owns one connection; screens only subscribe to its decoded frames.
@MainActor final class EventHub {
  struct Frame: Sendable {
    let sequence: Int
    let event: ServerEvent
  }
  private var subscribers: [UUID: AsyncStream<Frame>.Continuation] = [:]
  private(set) var sequence = 0
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
          sequence += 1
          if case .connected = event { delay = 1 }
          for continuation in subscribers.values {
            // A slow screen must revalidate rather than silently retaining an incomplete delta history.
            if case .dropped = continuation.yield(Frame(sequence: sequence, event: event)) {
              continuation.yield(Frame(sequence: sequence, event: .connected))
            }
          }
        }
      } catch { if Task.isCancelled { return } }
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      delay = min(delay * 2, 15)
    }
  }
}
