import UIKit

/// UIKit's semantic feedback follows the device's system haptics preferences.
@MainActor enum Haptics {
  enum Kind { case light, success, warning, selection, soft }
  static func play(_ kind: Kind) {
    switch kind {
    case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
    case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
    case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
    case .selection: UISelectionFeedbackGenerator().selectionChanged()
    }
  }
}
