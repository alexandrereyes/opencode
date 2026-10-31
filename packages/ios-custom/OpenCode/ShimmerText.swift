import SwiftUI
import UIKit

/// The web's `TextShimmer` on a running subagent's title in "Agentes e tarefas" (the Mac's `MacShimmerText`): the
/// text in a dimmer color, crossed by a soft band in the bright one about ten characters wide, left to right, every
/// 1.2 s. Core Animation moves the band (a gradient mask over the bright copy) in the render server, so nothing in
/// SwiftUI redraws while it runs, and every title passes on the same phase. Callers show plain text with Reduzir
/// Movimento.
struct ShimmerText: UIViewRepresentable {
  let text: String
  let font: UIFont
  let base: UIColor
  let peak: UIColor

  /// `text-shimmer.css`: `--text-shimmer-duration` and `--text-shimmer-spread` (in `ch`).
  static let period = 1.2
  static let spread = 5.2

  func makeUIView(context: Context) -> ShimmerView { ShimmerView() }

  func updateUIView(_ view: ShimmerView, context: Context) {
    view.update(text: text, font: font, base: base, peak: peak)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ShimmerView, context: Context) -> CGSize? {
    uiView.size(width: proposal.width)
  }

  final class ShimmerView: UIView {
    private let baseLabel = UILabel()
    private let peakLabel = UILabel()
    private let band = CAGradientLayer()
    private var swept: CGFloat = -1

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      for label in [baseLabel, peakLabel] {
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 1
        addSubview(label)
      }
      band.startPoint = CGPoint(x: 0, y: 0.5)
      band.endPoint = CGPoint(x: 1, y: 0.5)
      band.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
      peakLabel.layer.mask = band
      // Backgrounding removes running animations; the pass resumes on the shared phase.
      NotificationCenter.default.addObserver(self, selector: #selector(resume),
        name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    func update(text: String, font: UIFont, base: UIColor, peak: UIColor) {
      guard text != baseLabel.text || font != baseLabel.font || base != baseLabel.textColor
        || peak != peakLabel.textColor else { return }
      let resized = font != baseLabel.font
      for (label, color) in [(baseLabel, base), (peakLabel, peak)] {
        label.text = text
        label.font = font
        label.textColor = color
      }
      if resized { swept = -1 }
      invalidateIntrinsicContentSize()
      setNeedsLayout()
    }

    /// The text's width, up to what is offered (it truncates with an ellipsis beyond), at one line's height.
    func size(width proposed: CGFloat?) -> CGSize {
      let ideal = ceil(baseLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width)
      return CGSize(width: min(proposed ?? ideal, ideal), height: ceil(baseLabel.font?.lineHeight ?? 17))
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      baseLabel.frame = bounds
      peakLabel.frame = bounds
      guard bounds.width != swept else { return }
      swept = bounds.width
      restart()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil, band.animation(forKey: "sweep") == nil { restart() }
    }

    @objc private func resume() { restart() }

    #if DEBUG
    /// Whether the band is running, for the UI checks' captures.
    var sweeping: Bool { band.animation(forKey: "sweep") != nil }
    #endif

    /// The band's center runs from one gutter before the text to one after it, like the web's background position.
    private func restart() {
      let character = ("0" as NSString).size(withAttributes: [.font: baseLabel.font ?? UIFont.systemFont(ofSize: 13)]).width
      let spread = character * ShimmerText.spread
      let gutter = character * (ShimmerText.spread + 1)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      band.bounds = CGRect(x: 0, y: 0, width: spread * 2, height: bounds.height)
      band.position = CGPoint(x: -gutter, y: bounds.height / 2)
      CATransaction.commit()
      band.removeAnimation(forKey: "sweep")
      guard window != nil, bounds.width > 0 else { return }
      let sweep = CABasicAnimation(keyPath: "position.x")
      sweep.fromValue = -gutter
      sweep.toValue = bounds.width + gutter
      sweep.duration = ShimmerText.period
      sweep.repeatCount = .infinity
      sweep.isRemovedOnCompletion = false
      // One phase for every title: each pass starts on a multiple of the period of the shared media clock.
      let now = CACurrentMediaTime()
      sweep.beginTime = now - now.truncatingRemainder(dividingBy: ShimmerText.period)
      band.add(sweep, forKey: "sweep")
    }
  }
}
