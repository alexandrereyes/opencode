import Foundation

/// A desktop call keeps its event stream even when every window is minimized or closed.
public struct VoiceWindowActivity: Sendable {
  private var visible: Set<UUID> = []
  public init() {}
  public mutating func window(_ id: UUID, visible: Bool) {
    if visible { self.visible.insert(id) } else { self.visible.remove(id) }
  }
  public func requiresEvents(calling: Bool) -> Bool { calling || !visible.isEmpty }
}
