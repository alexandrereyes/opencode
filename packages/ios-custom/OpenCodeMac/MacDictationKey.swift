import AppKit
import OpenCodeKit

/// The right Option key dictates into the composer with the focus in the front window, a sheet's included (Nova
/// sessão, a comment, Pergunta paralela), or else into that window's conversation composer (`DictationKeyGesture`):
/// a tap starts and the next stops, holding records until release. Local event monitors only see events while the
/// app is in front, so the key keeps its normal meaning in every other app; the left Option key is never looked at.
/// Esc during a dictation (any composer's, however it started) cancels it and is consumed here, before AppKit's key
/// equivalents and the editor: no sheet closes and the focus stays. Without one, Esc keeps its meaning. ⌥⌘E during a
/// dictation turns its AI review on or off (during "Ajustando texto…" it uses the original text), also while the
/// right Option key is held: unlike other keys and modifiers, ⌘ and that E do not end the hold.
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
    /// A recording or a transcription under way, which Esc cancels (`VoiceRecordingComposer.cancellable`).
    let dictating: () -> Bool
    let available: () -> Bool
    let perform: (DictationKeyGesture.Action) -> Void
  }

  /// In registration order: another conversation's composer may appear before the previous one leaves.
  private var targets: [Target] = []
  private var gesture = DictationKeyGesture()
  private var target: Target?
  private var hold: Task<Void, Never>?
  private var monitor: Any?
  /// The last Esc down cancelled a dictation.
  private var escaped = false

  func register(_ target: Target) {
    targets.removeAll { $0.owner == target.owner }
    targets.append(target)
    start()
  }

  func unregister(_ owner: UUID) {
    targets.removeAll { $0.owner == owner }
  }

  /// The key window, the front window's innermost sheet and the front window.
  private var windows: [NSWindow] {
    let front = MacRuntime.shared.front?.window
    var sheet = front?.attachedSheet
    while let next = sheet?.attachedSheet { sheet = next }
    return [NSApp.keyWindow, sheet, front].compactMap { $0 }
  }

  /// The focused composer of the key window or of the front window's sheet; else the front window's conversation
  /// composer, unless a sheet covers it.
  private var focused: Target? {
    for window in windows {
      if let target = targets.last(where: { target in
        target.editor().map { $0.window === window && window.firstResponder === $0 } ?? false
      }) { return target }
    }
    guard let runtime = MacRuntime.shared.front, runtime.window?.attachedSheet == nil else { return nil }
    return targets.last { $0.conversation == runtime.id }
  }

  private func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      // An Esc that cancelled a dictation is used up: it reaches no sheet, button or editor.
      self?.handle(event) == true ? nil : event
    }
  }

  /// Whether the event was used and must go no further.
  private func handle(_ event: NSEvent) -> Bool {
    if event.type == .keyDown, event.keyCode == 53 {
      // Holding Esc repeats it: the repeats of an Esc that cancelled do not close the sheet afterwards.
      if event.isARepeat, escaped { return true }
      escaped = escape()
      return escaped
    }
    if event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "e",
      event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option] {
      let dictating = self.dictating
      guard gesture.toggleRevision(dictating: dictating != nil) == .toggleRevision, let dictating else { return false }
      if !event.isARepeat { dictating.perform(.toggleRevision) }
      return true
    }
    guard event.type == .flagsChanged else {
      if gesture.down { perform(gesture.interrupted()) }
      return false
    }
    // NX_DEVICERALTKEYMASK: the right Option key itself, independent of the left one.
    let rightDown = event.modifierFlags.rawValue & 0x40 != 0
    guard event.keyCode == DictationKeyGesture.keyCode else {
      // Another modifier changed while the key is down: a shortcut such as ⌥⌘, not dictation; during a hold ⌘
      // (left 55, right 54) waits for its key, which may be ⌥⌘E.
      if gesture.down { perform(gesture.modifier(command: event.keyCode == 55 || event.keyCode == 54)) }
      return false
    }
    if rightDown, !gesture.down {
      guard let target = focused, target.available() else { return false }
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
    return false
  }

  /// Esc cancels the dictation of `dictating`. Returns whether it cancelled.
  private func escape() -> Bool {
    let dictating = self.dictating
    hold?.cancel()
    guard gesture.escape(dictating: dictating != nil) == .cancel, let dictating else { return false }
    dictating.perform(.cancel)
    return true
  }

  /// The composer the key is held for, else the one it would dictate into, else any composer dictating in the key
  /// window, its sheet or the front window, if it is dictating.
  private var dictating: Target? {
    let held = gesture.down ? target.flatMap { $0.dictating() ? $0 : nil } : nil
    return held ?? focused.flatMap { $0.dictating() ? $0 : nil } ?? targets.last { target in
      target.dictating() && target.editor().map { editor in windows.contains { $0 === editor.window } } == true
    }
  }

  private func perform(_ action: DictationKeyGesture.Action) {
    guard action != .none else { return }
    target?.perform(action)
  }
}
