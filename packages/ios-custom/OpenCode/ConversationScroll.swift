import OpenCodeKit
import SwiftUI

@MainActor final class ConversationScrollState: NSObject {
  private let probes = NSMapTable<NSString, UIView>(
    keyOptions: .strongMemory, valueOptions: .weakMemory)
  private let headers = NSMapTable<UIView, UICollectionReusableView>(
    keyOptions: .weakMemory, valueOptions: .weakMemory)
  private let headerIDs = NSMapTable<UIView, NSString>(
    keyOptions: .weakMemory, valueOptions: .strongMemory)
  weak var view: UIScrollView?
  #if DEBUG
  /// The offline driver's virtual finger: programmatic offsets never report tracking or dragging.
  var simulatedTouch = false
  #endif
  /// A finger, fling or prompt jump currently owns the offset.
  var touching: Bool {
    #if DEBUG
    if simulatedTouch { return true }
    #endif
    return jumpLink != nil || view.map { $0.isTracking || $0.isDecelerating } == true
  }
  var nearBottom = true
  var following: Bool { plan.following }
  private(set) var tailSettled = false
  var pinned: Set<String> {
    Set(activeHeaders.map(\.id))
  }
  var anchor: (id: String, y: CGFloat)?
  /// Scrolls a row to the top by identity (the transcript's `ScrollViewReader`).
  var reveal: ((String) -> Void)?
  var readingAnchor: (id: String, offset: Double, viewportTop: Double?)?
  private var plan = ConversationScrollPlan()
  private var link: CADisplayLink?
  private var animation: UIViewPropertyAnimator?
  private var jump: (row: String, top: CGFloat, target: CGFloat, start: CFTimeInterval, eased: CGFloat)?
  private var jumpLink: CADisplayLink?
  private var jumpedAt: CFTimeInterval = 0
  private weak var observedView: UIScrollView?
  private var active = true
  #if DEBUG
  private(set) var tailAnimationCount = 0
  #endif
  var frames: [String: CGRect] {
    guard let view else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: probes.keyEnumerator().allObjects.compactMap { key in
        guard let key = key as? NSString, let probe = probes.object(forKey: key),
          probe.window != nil
        else { return nil }
        // A SwiftUI background representable can be zero-sized or inset inside its
        // hosting content. The recycled native cell owns the actual message bounds,
        // including a partially visible footer and the row's vertical padding.
        var parent = probe.superview
        while let current = parent {
          if let cell = current as? UICollectionReusableView {
            guard cell.bounds.height > 0 else { return nil }
            return (
              key as String,
              cell.convert(cell.bounds, to: view)
                .offsetBy(dx: 0, dy: -view.bounds.minY)
            )
          }
          if current === view { return nil }
          parent = current.superview
        }
        return nil
      })
  }
  private var activeHeaders: [(id: String, view: UICollectionReusableView)] {
    guard let view, view.contentOffset.y > -view.adjustedContentInset.top + 1 else { return [] }
    return headers.keyEnumerator().allObjects.compactMap { item in
      guard let probe = item as? UIView, probe.window != nil,
        let header = headers.object(forKey: probe), !header.isHidden,
        let id = headerIDs.object(forKey: probe)
      else { return nil }
      var parent = probe.superview
      while let current = parent, current !== header { parent = current.superview }
      guard parent === header else { return nil }
      let frame = header.convert(header.bounds, to: view).offsetBy(dx: 0, dy: -view.bounds.minY)
      return frame.minY <= 2 && frame.maxY > 0 ? (id as String, header) : nil
    }
  }
  var usableTop: CGFloat { usableTop(excluding: nil) }
  /// A prompt kept as the reading position rests at the top edge, where it becomes the active header.
  /// Measuring it below its own header would push it down until it is inline again, then back up.
  func usableTop(excluding id: String?) -> CGFloat {
    guard let view else { return 0 }
    return activeHeaders.filter { $0.id != id }.map {
      $0.view.convert($0.view.bounds, to: view).maxY - view.bounds.minY
    }.max() ?? 0
  }
  func registerHeader(_ probe: UIView, container: UICollectionReusableView, id: String) {
    headers.setObject(container, forKey: probe)
    headerIDs.setObject(id as NSString, forKey: probe)
  }
  func register(_ probe: UIView, id: String) {
    // The tail discovers empty Lists but must never become a message bookmark.
    if id != "bottom" { probes.setObject(probe, forKey: id as NSString) }
    if plan.pending { schedule() }
    #if DEBUG
    if ScrollFixtures.mode != nil {
      ScrollFixtures.scrollState = self
      TranscriptTrajectory.shared.geometry = self
    }
    #endif
  }
  func unregister(_ probe: UIView, id: String) {
    if probes.object(forKey: id as NSString) === probe {
      probes.removeObject(forKey: id as NSString)
    }
  }
  func capture(followTail: Bool) -> ReadingPosition.Target? {
    if followTail { return .followTail }
    // Measurement and restoration do not express a new reading intent. Keep the
    // logical anchor until a user scroll/selection cancels it, rather than replacing
    // it with a prefetched row during List's post-restoration layout passes.
    if let readingAnchor { return .message(id: readingAnchor.id, offset: readingAnchor.offset) }
    guard let view else { return nil }
    return ReadingCapture.target(
      followTail: followTail,
      frames: frames.filter { !pinned.contains($0.key) }.map {
        ReadingMessageFrame(id: $0.key, top: $0.value.minY, bottom: $0.value.maxY)
      }, usableTop: usableTop, viewportBottom: view.bounds.height)
  }
  func cancelAnchor() {
    stop()
    anchor = nil
    readingAnchor = nil
  }
  func stop() {
    plan.cancel()
    tailSettled = false
    link?.invalidate()
    link = nil
    animation?.stopAnimation(false)
    animation?.finishAnimation(at: .current)
    animation = nil
    endJump()
  }
  enum TurnJump { case unpinned, repeated, settled, scrolled, unmeasured }
  /// Brings a turn's first row just below its pinned prompt with one scroll, then holds it there as the
  /// reading anchor. A distant row is approached from one viewport away, so the animation never lays out
  /// the rows in between, and each frame aims at the row's live frame while the rows it passes measure.
  func revealTurn(prompt: String, row: String) -> TurnJump {
    // The prompt's text and the bubble around it both observe the same tap.
    guard CACurrentMediaTime() - jumpedAt > 0.4 else { return .repeated }
    guard active, let view, let header = activeHeaders.first(where: { $0.id == prompt })?.view
    else { return .unpinned }
    jumpedAt = CACurrentMediaTime()
    let top = header.convert(header.bounds, to: view).maxY - view.bounds.minY
    if let frame = frames[row], frame.minY >= top - 1 { return .settled }
    let origin = view.contentOffset.y
    stop()
    anchor = nil
    readingAnchor = nil
    if frames[row] == nil, let reveal {
      reveal(row)
      view.window?.layoutIfNeeded()
    }
    guard let frame = frames[row] else { return .unmeasured }
    readingAnchor = (row, 0, Double(top))
    let target = max(-view.adjustedContentInset.top, view.contentOffset.y + frame.minY - top)
    if UIAccessibility.isReduceMotionEnabled {
      view.setContentOffset(CGPoint(x: view.contentOffset.x, y: target), animated: false)
      correctAnchor()
      return .scrolled
    }
    let start = target + min(max(0, origin - target), view.bounds.height - top)
    view.setContentOffset(CGPoint(x: view.contentOffset.x, y: start), animated: false)
    jump = (row, top, target, CACurrentMediaTime(), 0)
    let link = CADisplayLink(target: self, selector: #selector(stepJump))
    jumpLink = link
    link.add(to: .main, forMode: .common)
    return .scrolled
  }
  @objc private func stepJump(_ link: CADisplayLink) {
    guard active, var jump, let view, view.window != nil else { stop(); return }
    guard !view.isTracking, !view.isDragging else { cancelAnchor(); return }
    let progress = min(1, (link.targetTimestamp - jump.start) / 0.35)
    let eased = 1 - pow(1 - progress, 3)
    if let frame = frames[jump.row] { jump.target = view.contentOffset.y + frame.minY - jump.top }
    let target = max(-view.adjustedContentInset.top, jump.target)
    // Cover this frame's share of the remaining distance, so a re-measured row only bends the curve.
    let y = view.contentOffset.y + (target - view.contentOffset.y) * (eased - jump.eased) / (1 - jump.eased)
    view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
    jump.eased = eased
    self.jump = jump
    guard progress >= 1 else { return }
    endJump()
    correctAnchor()
  }
  private func endJump() {
    jumpLink?.invalidate()
    jumpLink = nil
    jump = nil
  }
  func setVisible(_ visible: Bool) {
    active = visible
    if !visible { stop() }
  }
  func correctAnchor() {
    guard active, plan.following || anchor != nil || readingAnchor != nil else { return }
    if plan.following { tailSettled = false }
    plan.invalidate()
    schedule()
  }
  private func schedule() {
    guard active, link == nil, animation == nil, jumpLink == nil, let view, view.window != nil else { return }
    if observedView !== view {
      observedView?.panGestureRecognizer.removeTarget(self, action: #selector(dragged))
      view.panGestureRecognizer.addTarget(self, action: #selector(dragged))
      observedView = view
    }
    let link = CADisplayLink(target: self, selector: #selector(settle))
    self.link = link
    link.add(to: .main, forMode: .common)
  }
  @objc private func dragged() {
    if view?.panGestureRecognizer.state == .began { cancelAnchor() }
  }
  @objc func settle() {
    guard active, let view, view.window != nil else { stop(); return }
    guard !view.isDragging else { cancelAnchor(); return }
    #if DEBUG
    if simulatedTouch { cancelAnchor(); return }
    #endif
    if view.isTracking || view.isDecelerating { return }
    // Require a coherent native layout matching the previous display pass (the plan compares
    // consecutive samples). Repeated notifications retain the pending sample instead of starving a stream.
    guard let layout = measure(view) else { return }
    let target = max(
      -view.adjustedContentInset.top,
      min(layout.bottom, layout.height) - view.bounds.height + view.adjustedContentInset.bottom)
    guard let action = plan.consume(layout, interacting: false) else { return }
    link?.invalidate()
    link = nil
    if case .reading = action { applyCorrection(); return }
    if abs(view.contentOffset.y - target) <= 1 {
      tailSettled = tailMaterialized(view)
      if !tailSettled { correctAnchor() }
      return
    }
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics") {
      NSLog("FOLLOW tail state=%@ from=%.2f to=%.2f height=%.2f", String(describing: ObjectIdentifier(self)), view.contentOffset.y, target, view.contentSize.height)
    }
    #endif
    if case .tail(animated: true) = action, !UIAccessibility.isReduceMotionEnabled {
      #if DEBUG
      tailAnimationCount += 1
      #endif
      let animation = UIViewPropertyAnimator(duration: 0.28, curve: .easeOut) {
        view.contentOffset = CGPoint(x: view.contentOffset.x, y: target)
      }
      self.animation = animation
      animation.addCompletion { [weak self] _ in
        guard let self else { return }
        self.animation = nil
        correctAnchor()
      }
      animation.startAnimation()
      return
    }
    view.setContentOffset(CGPoint(x: view.contentOffset.x, y: target), animated: false)
    correctAnchor()
  }
  private func tailMaterialized(_ view: UIScrollView) -> Bool {
    guard let collection = view as? UICollectionView else { return true }
    let section = collection.numberOfSections - 1
    guard section >= 0, collection.numberOfItems(inSection: section) > 0 else { return false }
    return collection.cellForItem(at: IndexPath(item: collection.numberOfItems(inSection: section) - 1, section: section))?.window != nil
  }
  private func measure(_ view: UIScrollView) -> ConversationScrollPlan.Layout? {
    view.layoutIfNeeded()
    guard let collection = view as? UICollectionView else {
      return ConversationScrollPlan.Layout(
        height: view.contentSize.height, width: view.bounds.width, viewport: view.bounds.height,
        bottom: view.contentSize.height)
    }
    guard !collection.hasUncommittedUpdates, collection.numberOfSections > 0 else { return nil }
    let section = collection.numberOfSections - 1
    guard collection.numberOfItems(inSection: section) > 0,
      let bottom = collection.layoutAttributesForItem(at: IndexPath(item: collection.numberOfItems(inSection: section) - 1, section: section))?.frame.maxY
    else { return nil }
    return ConversationScrollPlan.Layout(
      height: view.contentSize.height, width: view.bounds.width, viewport: view.bounds.height, bottom: bottom)
  }
  private func applyCorrection() {
    guard let view, !view.isTracking, !view.isDragging, !view.isDecelerating, !touching else { return }
    let frames = frames
    let correction: CGFloat
    if let readingAnchor, let frame = frames[readingAnchor.id] {
      correction =
        frame.minY - (readingAnchor.viewportTop ?? usableTop(excluding: readingAnchor.id))
        + ReadingCapture.clampedOffset(readingAnchor.offset, height: frame.height)
    } else if let anchor, let frame = frames[anchor.id] {
      correction = frame.minY - anchor.y
    } else {
      return
    }
    let y = min(
      max(-view.adjustedContentInset.top, view.contentOffset.y + correction),
      max(
        -view.adjustedContentInset.top,
        view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom))
    if abs(view.contentOffset.y - y) > 0.75 {
      #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics") {
        NSLog("FOLLOW correction state=%@ from=%.2f to=%.2f", String(describing: ObjectIdentifier(self)), view.contentOffset.y, y)
      }
      #endif
      view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
    }
  }
  /// Applies a pending anchor before the frame is drawn: the transcript was just republished, so it is
  /// laid out now and corrected in the same transaction. Late measurements still settle as usual.
  func correctAnchorNow() {
    guard active, anchor != nil || readingAnchor != nil, let view, let window = view.window, !touching
    else { return }
    window.layoutIfNeeded()
    // A tall page can push the anchor out of the materialized rows; bring it back by identity first.
    if let id = anchor?.id ?? readingAnchor?.id, frames[id] == nil, let reveal {
      reveal(id)
      window.layoutIfNeeded()
    }
    applyCorrection()
    correctAnchor()
  }
  /// Corrects a history-page anchor from the layout that just changed, without waiting for the
  /// display link: List re-estimates the inserted rows for several passes after a prepend.
  func holdHistoryAnchor() {
    guard active, anchor != nil, readingAnchor == nil, !plan.following, !touching else { return }
    applyCorrection()
  }
  func followToEnd(animated: Bool = false) {
    guard active else { return }
    endJump()
    tailSettled = false
    anchor = nil
    readingAnchor = nil
    plan.follow(animated: animated)
    schedule()
  }
}

#if DEBUG
extension ConversationScrollState: TranscriptGeometry {
  var geometryView: UIScrollView? { view }
  var geometryRows: [String: CGRect] {
    let pinned = pinned
    return frames.filter { !pinned.contains($0.key) }
  }
}
#endif

struct ConversationRowProbe: UIViewRepresentable {
  let state: ConversationScrollState
  let id: String
  let color: UIColor
  func makeUIView(context: Context) -> Probe { Probe(state: state, id: id) }
  func updateUIView(_ view: Probe, context: Context) {
    // List can recycle this UIKit instance for a different message without another makeUIView.
    if view.id != id || view.state !== state {
      view.state.unregister(view, id: view.id)
      view.id = id
      view.state = state
    }
    view.attach()
    state.view?.backgroundColor = color
  }
  final class Probe: UIView {
    var state: ConversationScrollState
    var id: String
    init(state: ConversationScrollState, id: String) {
      self.state = state
      self.id = id
      super.init(frame: .zero)
      isOpaque = false
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      state.unregister(self, id: id)
      attach()
    }
    func attach() {
      guard window != nil else { return }
      var parent = superview
      while let current = parent {
        if let scroll = current as? UIScrollView {
          state.view = scroll
          state.register(self, id: id)
          return
        }
        parent = current.superview
      }
    }
  }
}
