import AppKit
import OpenCodeKit

/// The right Option key dictates into the composer with the focus in the front window, a sheet's included (Nova
/// sessão, a comment, Pergunta paralela), or else into that window's conversation composer (`DictationKeyGesture`):
/// a tap starts and the next stops, holding records until release. Local event monitors only see events while the
/// app is in front, so the key keeps its normal meaning in every other app; the left Option key is never looked at.
@MainActor final class MacDictationKey {
  static let shared = MacDictationKey()

  /// A composer on screen (`MacComposer`), registered while it is there.
  struct Target {
    /// The composer view that registered it.
    let owner: UUID
    /// The window whose conversation composer this is; nil for the others.
    let conversation: UUID?
    /// Its text view, while it is the draft's editor.
    let editor: () -> NSTextView?
    let recording: () -> Bool
    let available: () -> Bool
    let perform: (DictationKeyGesture.Action) -> Void
  }

  /// In registration order: another conversation's composer may appear before the previous one leaves.
  private var targets: [Target] = []
  private var gesture = DictationKeyGesture()
  private var target: Target?
  private var hold: Task<Void, Never>?
  private var monitor: Any?

  func register(_ target: Target) {
    targets.removeAll { $0.owner == target.owner }
    targets.append(target)
    start()
  }

  func unregister(_ owner: UUID) {
    targets.removeAll { $0.owner == owner }
  }

  /// The focused composer of the key window or of the front window's sheet; else the front window's conversation
  /// composer, unless a sheet covers it.
  private var focused: Target? {
    let front = MacRuntime.shared.front?.window
    var sheet = front?.attachedSheet
    while let next = sheet?.attachedSheet { sheet = next }
    let windows = [NSApp.keyWindow, sheet, front].compactMap { $0 }
    for window in windows {
      if let target = targets.last(where: { target in
        target.editor().map { $0.window === window && window.firstResponder === $0 } ?? false
      }) { return target }
    }
    guard let runtime = MacRuntime.shared.front, front?.attachedSheet == nil else { return nil }
    return targets.last { $0.conversation == runtime.id }
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
      guard let target = focused, target.available() else { return }
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
