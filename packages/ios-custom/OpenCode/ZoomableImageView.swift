import OpenCodeKit
import SwiftUI
import UIKit

struct ZoomableImageView: UIViewRepresentable {
  let image: CGImage
  let name: String
  let dismiss: () -> Void

  func makeUIView(context: Context) -> ImageZoomScrollView {
    ImageZoomScrollView(image: image, name: name, dismiss: dismiss)
  }

  func updateUIView(_ view: ImageZoomScrollView, context: Context) {
    view.close = dismiss
  }
}

final class ImageZoomScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  private let picture: AccessibleZoomImage
  private var viewport = CGSize.zero
  var close: () -> Void
  private var fitted: Bool { zoomScale <= minimumZoomScale * 1.01 }

  init(image: CGImage, name: String, dismiss: @escaping () -> Void) {
    picture = AccessibleZoomImage(image: UIImage(cgImage: image))
    close = dismiss
    super.init(frame: .zero)
    delegate = self
    contentInsetAdjustmentBehavior = .never
    showsHorizontalScrollIndicator = false
    showsVerticalScrollIndicator = false
    bouncesZoom = false
    bounces = true
    addSubview(picture)
    let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
    tap.numberOfTapsRequired = 2
    addGestureRecognizer(tap)
    let swipe = UIPanGestureRecognizer(target: self, action: #selector(swipeDown(_:)))
    swipe.maximumNumberOfTouches = 1
    swipe.delegate = self
    addGestureRecognizer(swipe)
    panGestureRecognizer.require(toFail: swipe)
    picture.isAccessibilityElement = true
    picture.accessibilityLabel = name
    picture.accessibilityIdentifier = "fullscreen-image"
    picture.accessibilityTraits = [.image, .adjustable]
    picture.zoom = { [weak self] in self?.accessibleZoom() ?? false }
    picture.fit = { [weak self] in self?.accessibleFit() ?? false }
    picture.activate = { [weak self] in
      guard let self else { return false }
      return fitted ? accessibleZoom() : accessibleFit()
    }
    picture.accessibilityHint = "Toque duas vezes para ampliar ou ajustar à tela."
    picture.accessibilityCustomActions = [
      UIAccessibilityCustomAction(name: "Ampliar", target: self, selector: #selector(accessibleZoom)),
      UIAccessibilityCustomAction(name: "Ajustar à tela", target: self, selector: #selector(accessibleFit)),
      UIAccessibilityCustomAction(name: "Fechar imagem", target: self, selector: #selector(accessibleClose)),
    ]
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.height > 0 else { return }
    if viewport != bounds.size {
      viewport = bounds.size
      minimumZoomScale = min(minimumZoomScale, 1)
      maximumZoomScale = max(maximumZoomScale, 1)
      zoomScale = 1
      picture.frame = CGRect(origin: .zero, size: picture.image!.size)
      let fit = ImageZoomGeometry.fit(image: picture.bounds.size, viewport: bounds.size)
      maximumZoomScale = max(1, fit * 5)
      minimumZoomScale = fit
      zoomScale = fit
      maximumZoomScale = fit * 5
      contentSize = picture.frame.size
      centerImage()
      contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }
    centerImage()
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

  private func centerImage() {
    contentInset = UIEdgeInsets(top: max(0, (bounds.height - picture.frame.height) / 2),
      left: max(0, (bounds.width - picture.frame.width) / 2),
      bottom: max(0, (bounds.height - picture.frame.height) / 2),
      right: max(0, (bounds.width - picture.frame.width) / 2))
    picture.accessibilityValue = fitted ? "Ajustada à tela" : "Ampliada"
  }

  @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
    if !fitted { setZoomScale(minimumZoomScale, animated: true); return }
    enlarge(at: gesture.location(in: picture))
  }

  private func enlarge(at point: CGPoint) {
    let scale = minimumZoomScale * 3
    zoom(to: ImageZoomGeometry.rect(at: point, viewport: bounds.size, scale: scale), animated: true)
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer === panGestureRecognizer || gestureRecognizer === pinchGestureRecognizer {
      return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
    let velocity = pan.velocity(in: self)
    return fitted && !isZooming && velocity.y > abs(velocity.x)
  }

  @objc private func swipeDown(_ gesture: UIPanGestureRecognizer) {
    guard gesture.state == .ended, fitted else { return }
    if gesture.translation(in: self).y > 80 || gesture.velocity(in: self).y > 700 { close() }
  }

  @objc private func accessibleZoom() -> Bool {
    enlarge(at: CGPoint(x: picture.bounds.midX, y: picture.bounds.midY))
    return true
  }

  @objc private func accessibleFit() -> Bool {
    setZoomScale(minimumZoomScale, animated: true)
    return true
  }

  @objc private func accessibleClose() -> Bool { close(); return true }
}

private final class AccessibleZoomImage: UIImageView {
  var zoom: (() -> Bool)?
  var fit: (() -> Bool)?
  var activate: (() -> Bool)?

  override func accessibilityActivate() -> Bool { activate?() ?? false }
  override func accessibilityIncrement() { _ = zoom?() }
  override func accessibilityDecrement() { _ = fit?() }
}
