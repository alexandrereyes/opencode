import ImageIO
import OpenCodeKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct ZoomableImageView: UIViewRepresentable {
  let image: CGImage
  let name: String
  /// An animated GIF/APNG/WebP file whose frames replace the still image while the view exists.
  var animation: URL? = nil
  let dismiss: () -> Void

  func makeUIView(context: Context) -> ImageZoomScrollView {
    let view = ImageZoomScrollView(image: image, name: name, dismiss: dismiss)
    if let animation { view.animate(animation) }
    return view
  }

  func updateUIView(_ view: ImageZoomScrollView, context: Context) {
    view.close = dismiss
  }
}

final class ImageZoomScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  private let picture: AccessibleZoomImage
  private var viewport = CGSize.zero
  private var swipe: UIPanGestureRecognizer!
  var close: () -> Void
  private var fitted: Bool { zoomScale <= minimumZoomScale * 1.01 }
  /// Horizontal file paging may start only while the whole image fits and no zoom gesture is active.
  var pageable: Bool { fitted && !isZooming && pinchGestureRecognizer?.state != .changed }

  init(image: CGImage, name: String, dismiss: @escaping () -> Void) {
    picture = AccessibleZoomImage(image: UIImage(cgImage: image))
    close = dismiss
    super.init(frame: .zero)
    delegate = self
    contentInsetAdjustmentBehavior = .never
    showsHorizontalScrollIndicator = false
    showsVerticalScrollIndicator = false
    // A status-bar tap must not move a zoomed image.
    scrollsToTop = false
    bouncesZoom = false
    bounces = true
    addSubview(picture)
    let tap = StrictDoubleTapRecognizer(target: self, action: #selector(doubleTap(_:)))
    tap.numberOfTapsRequired = 2
    tap.scrollView = self
    addGestureRecognizer(tap)
    swipe = UIPanGestureRecognizer(target: self, action: #selector(swipeDown(_:)))
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

  /// ImageIO decodes one frame at a time, so a long animation never holds all its bitmaps.
  func animate(_ file: URL) {
    CGAnimateImageAtURLWithBlock(file as CFURL, nil) { [weak self] _, frame, stop in
      guard let self else { stop.pointee = true; return }
      picture.image = UIImage(cgImage: frame)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.height > 0 else { return }
    if viewport != bounds.size {
      let first = viewport == .zero
      // A zoomed image keeps its relative zoom and visible center when the viewport changes.
      let relative = first || fitted ? 1 : zoomScale / minimumZoomScale
      let center = picture.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: self)
      viewport = bounds.size
      minimumZoomScale = min(minimumZoomScale, 1)
      maximumZoomScale = max(maximumZoomScale, 1)
      zoomScale = 1
      picture.frame = CGRect(origin: .zero, size: picture.image!.size)
      let fit = ImageZoomGeometry.fit(image: picture.bounds.size, viewport: bounds.size)
      maximumZoomScale = max(1, fit * 5)
      minimumZoomScale = fit
      zoomScale = fit * min(relative, 5)
      maximumZoomScale = fit * 5
      contentSize = picture.frame.size
      centerImage()
      if relative == 1 {
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
      } else {
        let focus = CGPoint(x: center.x * zoomScale - bounds.width / 2, y: center.y * zoomScale - bounds.height / 2)
        contentOffset = CGPoint(
          x: min(max(focus.x, -contentInset.left), contentSize.width + contentInset.right - bounds.width),
          y: min(max(focus.y, -contentInset.top), contentSize.height + contentInset.bottom - bounds.height))
      }
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
    // Only the swipe-to-close recognizer is filtered; recognizers of enclosing views keep their own rules.
    guard gestureRecognizer === swipe else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
    let velocity = swipe.velocity(in: self)
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

/// UIKit's double tap accepts two quick nudges of up to ~10 points, so touching a zoomed image twice to adjust it
/// reset the zoom. Each tap here must stay nearly still and brief, and a touch that stops a moving image is not a tap.
final class StrictDoubleTapRecognizer: UITapGestureRecognizer {
  weak var scrollView: UIScrollView?
  private var start = CGPoint.zero
  private var began = Date.distantPast

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let scrollView, scrollView.isDecelerating || scrollView.isDragging || scrollView.isZooming {
      state = .failed
      return
    }
    start = touches.first?.location(in: view) ?? .zero
    began = Date()
    super.touchesBegan(touches, with: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    if let point = touches.first?.location(in: view), hypot(point.x - start.x, point.y - start.y) > 6 {
      state = .failed
      return
    }
    super.touchesMoved(touches, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if Date().timeIntervalSince(began) > 0.3 {
      state = .failed
      return
    }
    super.touchesEnded(touches, with: event)
  }
}

private final class AccessibleZoomImage: UIImageView {
  var zoom: (() -> Bool)?
  var fit: (() -> Bool)?
  var activate: (() -> Bool)?

  override func accessibilityActivate() -> Bool { activate?() ?? false }
  override func accessibilityIncrement() { _ = zoom?() }
  override func accessibilityDecrement() { _ = fit?() }
}
