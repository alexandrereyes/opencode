import OpenCodeKit
import SwiftUI
import UIKit

/// The streamed screen for JPEG/PNG streams (and the fallback snapshot stream), aspect-fit.
struct ResourceFrameView: View {
  let model: ResourceViewerModel
  var body: some View {
    if let image = model.image {
      Image(uiImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
        .accessibilityIdentifier("resource-frame")
    } else {
      ProgressView().controlSize(.large).accessibilityIdentifier("resource-loading")
    }
  }
}

/// Transparent layer over the screen. In control, touches become normalized `touch` inputs (multi-touch, with a
/// touch indicator); otherwise a tap calls `onTap` (the shell toggles the controls). `contentSize` is the frame's
/// pixel size, so coordinates map to the aspect-fit image and touches in the letterbox are ignored.
struct ResourceTouchOverlay: UIViewRepresentable {
  let model: ResourceViewerModel
  var contentSize: CGSize?
  var indicator: UIColor
  var onTap: () -> Void

  func makeUIView(context: Context) -> TouchView {
    let view = TouchView()
    view.isMultipleTouchEnabled = true
    view.backgroundColor = .clear
    view.accessibilityIdentifier = "resource-touch"
    view.isAccessibilityElement = true
    view.accessibilityLabel = "Tela do recurso"
    // VoiceOver users in control touch the resource directly, as sighted users do.
    view.accessibilityTraits = .allowsDirectInteraction
    return view
  }
  func updateUIView(_ view: TouchView, context: Context) {
    view.model = model
    view.interactive = model.inControl
    view.contentSize = contentSize ?? model.image?.size ?? model.hello.map { CGSize(width: $0.width, height: $0.height) }
    view.indicatorColor = indicator
    view.onTap = onTap
  }

  final class TouchView: UIView {
    weak var model: ResourceViewerModel?
    var interactive = false
    var contentSize: CGSize?
    var indicatorColor = UIColor.systemOrange
    var onTap: () -> Void = {}
    private var pointers: [ObjectIdentifier: Int] = [:]
    private var dots: [ObjectIdentifier: CALayer] = [:]
    private var tapStart: CGPoint?

    /// The aspect-fit rect the frame occupies inside the view.
    var content: CGRect {
      guard let size = contentSize, size.width > 0, size.height > 0 else { return bounds }
      let scale = min(bounds.width / size.width, bounds.height / size.height)
      let fitted = CGSize(width: size.width * scale, height: size.height * scale)
      return CGRect(
        x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard interactive else {
        tapStart = touches.first?.location(in: self)
        return
      }
      let events = touches.compactMap { touch -> ResourceInput? in
        let free = Set(0..<10).subtracting(pointers.values).min() ?? 0
        pointers[ObjectIdentifier(touch)] = free
        showDot(touch)
        return input(touch, .began)
      }
      model?.send(events)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard interactive else { return }
      touches.forEach(moveDot)
      model?.send(touches.compactMap { input($0, .moved) })
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard interactive else {
        if let start = tapStart, let end = touches.first?.location(in: self), hypot(end.x - start.x, end.y - start.y) < 12 {
          onTap()
        }
        tapStart = nil
        return
      }
      finish(touches, .ended)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      tapStart = nil
      guard interactive else { return }
      finish(touches, .cancelled)
    }

    private func finish(_ touches: Set<UITouch>, _ phase: ResourceInput.Phase) {
      model?.send(touches.compactMap { input($0, phase) })
      touches.forEach { touch in
        pointers.removeValue(forKey: ObjectIdentifier(touch))
        dots.removeValue(forKey: ObjectIdentifier(touch))?.removeFromSuperlayer()
      }
    }

    private func input(_ touch: UITouch, _ phase: ResourceInput.Phase) -> ResourceInput? {
      guard let pointer = pointers[ObjectIdentifier(touch)] else { return nil }
      let rect = content
      let point = touch.location(in: self)
      let x = (point.x - rect.minX) / rect.width
      let y = (point.y - rect.minY) / rect.height
      // A touch that starts in the letterbox belongs to nothing; one that drifts out is clamped by the encoder.
      if phase == .began, !(0...1).contains(x) || !(0...1).contains(y) {
        pointers.removeValue(forKey: ObjectIdentifier(touch))
        dots.removeValue(forKey: ObjectIdentifier(touch))?.removeFromSuperlayer()
        return nil
      }
      return .touch(phase, x: x, y: y, pointer: pointer)
    }

    private func showDot(_ touch: UITouch) {
      let dot = CALayer()
      dot.bounds = CGRect(x: 0, y: 0, width: 36, height: 36)
      dot.cornerRadius = 18
      dot.backgroundColor = indicatorColor.withAlphaComponent(0.45).cgColor
      dot.borderColor = indicatorColor.withAlphaComponent(0.8).cgColor
      dot.borderWidth = 2
      dot.position = touch.location(in: self)
      layer.addSublayer(dot)
      dots[ObjectIdentifier(touch)] = dot
    }
    private func moveDot(_ touch: UITouch) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      dots[ObjectIdentifier(touch)]?.position = touch.location(in: self)
      CATransaction.commit()
    }
  }
}

/// A hidden text field that brings up the iPhone keyboard and forwards typing as `text`/`key` inputs. Kinds pick the
/// content type: Chrome sets `.password` on password fields so iOS offers saved passwords. Text is never logged.
struct ResourceKeyboard: UIViewRepresentable {
  let model: ResourceViewerModel
  @Binding var active: Bool
  var style = ResourceKeyboardStyle()

  func makeUIView(context: Context) -> Field {
    let field = Field()
    field.model = model
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.smartQuotesType = .no
    field.smartDashesType = .no
    field.accessibilityIdentifier = "resource-keyboard"
    field.alpha = 0.02
    return field
  }
  func updateUIView(_ field: Field, context: Context) {
    field.model = model
    let changed = field.textContentType != style.contentType || field.isSecureTextEntry != style.secure
      || field.keyboardType != style.keyboard
    field.textContentType = style.contentType
    field.isSecureTextEntry = style.secure
    field.keyboardType = style.keyboard
    field.returnKeyType = style.returnKey
    if changed, field.isFirstResponder { field.reloadInputViews() }
    field.onEnd = { active = false }
    if active, !field.isFirstResponder { field.becomeFirstResponder() }
    if !active, field.isFirstResponder { field.resignFirstResponder() }
  }

  final class Field: UITextField, UITextFieldDelegate {
    weak var model: ResourceViewerModel?
    var onEnd: () -> Void = {}
    override init(frame: CGRect) {
      super.init(frame: frame)
      delegate = self
      returnKeyType = .default
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func deleteBackward() {
      model?.send([.key("Backspace")])
    }
    // The field stays empty: every change is forwarded and discarded, so autofill inserts arrive whole.
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String)
      -> Bool
    {
      if !string.isEmpty { model?.send([.text(string)]) }
      return false
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      model?.send([.key("Enter")])
      return false
    }
    func textFieldDidEndEditing(_ textField: UITextField) { onEnd() }
  }
}

/// Traits of the hidden keyboard field. Kinds set `ResourceViewerModel.keyboardStyle`.
struct ResourceKeyboardStyle: Equatable {
  var contentType: UITextContentType?
  var keyboard: UIKeyboardType = .default
  var secure = false
  var returnKey: UIReturnKeyType = .default
}
