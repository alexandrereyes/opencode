import AppKit
import SwiftUI

/// A click outside a sheet (on the dimmed window behind it, or anywhere else on that window) closes the sheet like
/// Esc: the click becomes an Esc key equivalent for the topmost sheet, so its Cancelar/Fechar button runs with the
/// same effect, including any confirmation that button asks for. Alerts and confirmation dialogs are sheets too and
/// close as their Cancelar would. Each click closes only the topmost sheet.
@MainActor enum MacOutsideClick {
  private static var monitor: Any?

  static func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
      guard let window = event.window, var sheet = window.attachedSheet else { return event }
      while let next = sheet.attachedSheet { sheet = next }
      // Modelo e esforço over Nova sessão closes first, by its own monitor.
      if sheet.childWindows?.contains(where: { $0.isVisible && $0.identifier?.rawValue == "mac-model-palette" }) == true {
        return event
      }
      guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: event.timestamp, windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
      else { return event }
      _ = sheet.performKeyEquivalent(with: escape)
      return nil
    }
  }
}

extension View {
  /// Esc (and so a click outside, `MacOutsideClick`) closes a sheet that has no Cancelar or Fechar button of its own.
  func macCancelable() -> some View { modifier(MacCancelable()) }
}

private struct MacCancelable: ViewModifier {
  @Environment(\.dismiss) private var dismiss
  func body(content: Content) -> some View {
    content.background {
      Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}
