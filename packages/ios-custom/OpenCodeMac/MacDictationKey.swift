import AppKit
import OpenCodeKit

/// The right Option key dictates into the front window's composer (`DictationKeyGesture`): a tap starts and the
/// next stops, holding records until release. Local event monitors only see events while the app is in front, so
/// the key keeps its normal meaning in every other app; the left Option key is never looked at.
@MainActor final class MacDictationKey {
  static let shared = MacDictationKey()

  /// The composer of each window's conversation, registered while it is on screen.
  struct Target {
    /// The composer view that registered it: another conversation's composer may appear before it leaves.
    let owner: UUID
    let recording: () -> Bool
    let available: () -> Bool
    let perform: (DictationKeyGesture.Action) -> Void
  }

  private var targets: [UUID: Target] = [:]
  private var gesture = DictationKeyGesture()
  private var target: Target?
  private var hold: Task<Void, Never>?
  private var monitor: Any?

  func register(_ window: UUID, _ target: Target) {
    targets[window] = target
    start()
  }

  func unregister(_ window: UUID, owner: UUID) {
    if targets[window]?.owner == owner { targets[window] = nil }
  }

  private func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      self?.handle(event)
      return event
    }
  }

  private func handle(_ event: NSEvent) {
    guard event.type == .flagsChanged else {
      if gesture.down { perform(gesture.interrupted()) }
      return
    }
    // NX_DEVICERALTKEYMASK: the right Option key itself, independent of the left one.
    let rightDown = event.modifierFlags.rawValue & 0x40 != 0
    guard event.keyCode == DictationKeyGesture.keyCode else {
      // Another modifier changed while the key is down: a shortcut such as ⌥⌘, not dictation.
      if gesture.down { perform(gesture.interrupted()) }
      return
    }
    if rightDown, !gesture.down {
      guard let window = MacRuntime.shared.front, window.window?.attachedSheet == nil,
        let target = targets[window.id], target.available() else { return }
      self.target = target
      let others = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        .subtracting([.option, .capsLock, .numericPad, .function])
      gesture.press(recording: target.recording(), otherModifiers: !others.isEmpty || event.modifierFlags.rawValue & 0x20 != 0)
      hold?.cancel()
      hold = Task { [weak self] in
        try? await Task.sleep(for: DictationKeyGesture.holdDelay)
        guard !Task.isCancelled, let self else { return }
        self.perform(self.gesture.held())
      }
    } else if !rightDown, gesture.down {
      hold?.cancel()
      perform(gesture.release())
      target = nil
    }
  }

  private func perform(_ action: DictationKeyGesture.Action) {
    guard action != .none else { return }
    target?.perform(action)
  }
}
