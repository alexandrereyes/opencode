import Foundation
import Network
import OpenCodeKit

@MainActor protocol VoicePathMonitoring: AnyObject {
  var current: VoicePath { get }
  func start(_ change: @escaping @MainActor (VoicePath) -> Void)
  func stop()
}

/// Reachability is only observed during a call; a fresh monitor per call because NWPathMonitor cannot restart.
@MainActor final class VoicePathMonitor: VoicePathMonitoring {
  private(set) var current = VoicePath(satisfied: true)
  private var monitor: NWPathMonitor?
  func start(_ change: @escaping @MainActor (VoicePath) -> Void) {
    stop()
    current = VoicePath(satisfied: true)
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let value = VoicePath(satisfied: path.status == .satisfied,
        interfaces: path.availableInterfaces.map { "\($0.type):\($0.name)" })
      Task { @MainActor [weak self] in
        guard let self, self.monitor === monitor else { return }
        self.current = value
        change(value)
      }
    }
    self.monitor = monitor
    monitor.start(queue: DispatchQueue(label: "br.com.alexandrem.opencode.voice.path"))
  }
  func stop() { monitor?.cancel(); monitor = nil }
}
