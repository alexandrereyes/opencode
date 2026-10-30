import Observation
import OpenCodeKit
import SwiftUI

@MainActor @Observable final class ToastCenter {
  enum Kind { case success, error }
  struct Message: Identifiable {
    let id = UUID()
    let text: String
    let kind: Kind
    let retry: (() -> Void)?
    /// The button's title when there is an action; retrying by default.
    var action = "Tentar novamente"
  }
  private(set) var message: Message?

  func show(_ text: String, kind: Kind = .success, action: String = "Tentar novamente", retry: (() -> Void)? = nil) {
    message = Message(text: text, kind: kind, retry: retry, action: action)
    AccessibilityNotification.Announcement(text).post()
  }
  func dismiss(_ id: UUID) {
    if message?.id == id { message = nil }
  }
}

private struct ToastOverlay: ViewModifier {
  @Environment(\.appTheme) private var theme
  let center: ToastCenter
  func body(content: Content) -> some View {
    content.overlay(alignment: .top) {
      if let message = center.message {
        HStack(spacing: 12) {
          Label {
            Text(message.text).foregroundStyle(theme.color(.textStrong)).lineLimit(3)
          } icon: {
            Image(
              systemName: message.kind == .error
                ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
            )
            .foregroundStyle(theme.color(message.kind == .error ? .error : .success))
          }
          if let retry = message.retry {
            Button(message.action) {
              center.dismiss(message.id)
              retry()
            }
            .foregroundStyle(theme.color(.primary))
          }
        }
        .font(.subheadline).padding(.horizontal, 18).padding(.vertical, 12)
        .adaptiveGlass(Capsule()).padding(12)
        .accessibilityElement(children: .combine).accessibilityIdentifier("action-toast")
        .allowsHitTesting(message.retry != nil)
        .voiceCaptureHidden()
      }
    }
    .task(id: center.message?.id) {
      guard let message = center.message else { return }
      do { try await Task.sleep(for: .seconds(message.kind == .error ? 6 : 4)) } catch { return }
      center.dismiss(message.id)
    }
  }
}

extension View {
  func toastOverlay(_ center: ToastCenter) -> some View { modifier(ToastOverlay(center: center)) }
}
