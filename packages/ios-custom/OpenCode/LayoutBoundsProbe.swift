#if DEBUG
import SwiftUI

struct LayoutBoundsProbe: UIViewRepresentable {
  let id: String
  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isAccessibilityElement = true
    view.accessibilityIdentifier = id
    view.accessibilityLabel = "Geometria de verificação"
    view.isUserInteractionEnabled = false
    return view
  }
  func updateUIView(_ view: UIView, context: Context) {}
}
#endif
