import AppKit
import SwiftUI

/// The web's `TextShimmer` (`packages/ui/src/typography/text-shimmer`) on a running subagent's title: the text in a
/// dimmer color, crossed by a soft band in the bright one about ten characters wide, left to right, every 1.2 s.
/// Core Animation moves the band (a gradient mask over the bright copy) in the render server: nothing in SwiftUI or
/// AppKit redraws while it runs, where a SwiftUI `repeatForever` would re-render the window every frame. Every
/// title passes on the same phase. The caller shows plain text with Reduzir Movimento and in `ImageRenderer`.
struct MacShimmerText: NSViewRepresentable {
  let text: String
  let font: NSFont
  let base: NSColor
  let peak: NSColor

  /// `text-shimmer.css`: `--text-shimmer-duration` and `--text-shimmer-spread` (in `ch`).
  static let period = 1.2
  static let spread = 5.2

  func makeNSView(context: Context) -> ShimmerView { ShimmerView() }

  func updateNSView(_ view: ShimmerView, context: Context) {
    view.update(text: text, font: font, base: base, peak: peak)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerView, context: Context) -> CGSize? {
    nsView.size(width: proposal.width)
  }

  final class ShimmerView: NSView {
    private let baseLine = Line()
    private let peakLine = Line()
    private let band = CAGradientLayer()
    private var font = NSFont.systemFont(ofSize: 13)
    private var lineHeight: CGFloat = 16
    private var swept: CGFloat = -1

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      addSubview(baseLine)
      addSubview(peakLine)
      peakLine.wantsLayer = true
      band.startPoint = CGPoint(x: 0, y: 0.5)
      band.endPoint = CGPoint(x: 1, y: 0.5)
      band.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    // Clicks and the context menu belong to the SwiftUI row around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String, font: NSFont, base: NSColor, peak: NSColor) {
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingTail
      func string(_ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
      }
      let next = string(base)
      guard next != baseLine.string || string(peak) != peakLine.string else { return }
      if font != self.font {
        self.font = font
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        swept = -1
        needsLayout = true
      }
      baseLine.string = next
      peakLine.string = string(peak)
      invalidateIntrinsicContentSize()
    }

    /// The text's width, up to what is offered (it truncates with an ellipsis beyond), at one line's height.
    func size(width proposed: CGFloat?) -> CGSize {
      let ideal = ceil(baseLine.string.size().width)
      return CGSize(width: min(proposed ?? ideal, ideal), height: lineHeight)
    }

    override func layout() {
      super.layout()
      baseLine.frame = bounds
      peakLine.frame = bounds
      if peakLine.layer?.mask !== band { peakLine.layer?.mask = band }
      guard bounds.width != swept else { return }
      swept = bounds.width
      restart()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      band.contentsScale = window?.backingScaleFactor ?? 2
      if window != nil, band.animation(forKey: "sweep") == nil { restart() }
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      band.contentsScale = window?.backingScaleFactor ?? 2
    }

    #if DEBUG
    /// Where the running pass is within its period (0 when it started on a multiple of it), for the checks.
    var phase: Double? {
      (band.animation(forKey: "sweep") as? CABasicAnimation).map {
        $0.beginTime.truncatingRemainder(dividingBy: MacShimmerText.period)
      }
    }

    /// Stops the band at `fraction` of its pass, for a still picture (an off-screen window does not animate);
    /// `nil` resumes it on the shared phase.
    func hold(at fraction: Double?) {
      guard let fraction else { return restart() }
      band.removeAnimation(forKey: "sweep")
      let gutter = self.gutter
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      band.position.x = -gutter + (bounds.width + 2 * gutter) * fraction
      CATransaction.commit()
    }
    #endif

    private var gutter: CGFloat {
      let character = ("0" as NSString).size(withAttributes: [.font: font]).width
      return character * (MacShimmerText.spread + 1)
    }

    /// The band's center runs from one gutter before the text to one after it, like the web's background position.
    private func restart() {
      let character = ("0" as NSString).size(withAttributes: [.font: font]).width
      let spread = character * MacShimmerText.spread
      let gutter = self.gutter
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      band.bounds = CGRect(x: 0, y: 0, width: spread * 2, height: max(bounds.height, lineHeight))
      band.position = CGPoint(x: -gutter, y: bounds.height / 2)
      CATransaction.commit()
      band.removeAnimation(forKey: "sweep")
      guard window != nil, bounds.width > 0 else { return }
      let sweep = CABasicAnimation(keyPath: "position.x")
      sweep.fromValue = -gutter
      sweep.toValue = bounds.width + gutter
      sweep.duration = MacShimmerText.period
      sweep.repeatCount = .infinity
      sweep.isRemovedOnCompletion = false
      // One phase for every title: each pass starts on a multiple of the period of the shared media clock.
      let now = CACurrentMediaTime()
      sweep.beginTime = now - now.truncatingRemainder(dividingBy: MacShimmerText.period)
      band.add(sweep, forKey: "sweep")
    }
  }

  /// One copy of the text, drawn by AppKit: a capture that draws the views (`cacheDisplay`) still shows the title.
  final class Line: NSView {
    var string = NSAttributedString() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
      string.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
  }
}

private struct MacStillCaptureKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// `ImageRenderer` draws only SwiftUI views: a still capture of the column shows the running titles as plain text.
  var macStillCapture: Bool {
    get { self[MacStillCaptureKey.self] }
    set { self[MacStillCaptureKey.self] = newValue }
  }
}
