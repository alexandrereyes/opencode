import SwiftUI

/// Keep UIKit's edge-pop recognizer available with the hidden SwiftUI navigation bar.
struct ConversationBackGesture: UIViewControllerRepresentable {
  let capture: () -> Void
  let appeared: () -> Void
  func makeUIViewController(context: Context) -> Controller {
    let controller = Controller()
    controller.capture = capture
    controller.appeared = appeared
    return controller
  }
  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.capture = capture
    controller.appeared = appeared
  }
  final class Controller: UIViewController, UIGestureRecognizerDelegate {
    var capture: (() -> Void)?
    var appeared: (() -> Void)?
    private weak var originalDelegate: (any UIGestureRecognizerDelegate)?
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      appeared?()
      guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
      if gesture.delegate !== self { originalDelegate = gesture.delegate }
      gesture.delegate = self
      gesture.isEnabled = true
    }
    override func viewWillDisappear(_ animated: Bool) {
      capture?()
      super.viewWillDisappear(animated)
      if let gesture = navigationController?.interactivePopGestureRecognizer,
        gesture.delegate === self
      {
        gesture.delegate = originalDelegate
      }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let navigationController, navigationController.viewControllers.count > 1,
        navigationController.transitionCoordinator == nil
      else { return false }
      capture?()
      return true
    }
  }
}
