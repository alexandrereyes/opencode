import OpenCodeKit
import SwiftUI

@MainActor final class ConversationScrollState {
  private let probes = NSMapTable<NSString, UIView>(
    keyOptions: .strongMemory, valueOptions: .weakMemory)
  private let headers = NSMapTable<UIView, UICollectionReusableView>(
    keyOptions: .weakMemory, valueOptions: .weakMemory)
  private let headerIDs = NSMapTable<UIView, NSString>(
    keyOptions: .weakMemory, valueOptions: .strongMemory)
  weak var view: UIScrollView?
  var nearBottom = true
  var pinned: Set<String> {
    Set(activeHeaders.map(\.id))
  }
  var anchor: (id: String, y: CGFloat)?
  var readingAnchor: (id: String, offset: Double, viewportTop: Double?)?
  private var correctionPending = false
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
  var usableTop: CGFloat {
    guard let view else { return 0 }
    return activeHeaders.map {
      $0.view.convert($0.view.bounds, to: view).maxY - view.bounds.minY
    }.max() ?? 0
  }
  func registerHeader(_ probe: UIView, container: UICollectionReusableView, id: String) {
    headers.setObject(container, forKey: probe)
    headerIDs.setObject(id as NSString, forKey: probe)
  }
  func register(_ probe: UIView, id: String) { probes.setObject(probe, forKey: id as NSString) }
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
    anchor = nil
    readingAnchor = nil
  }
  func correctAnchor() {
    guard !correctionPending, anchor != nil || readingAnchor != nil else { return }
    correctionPending = true
    // Never mutate List's contentOffset inside its geometry/observation transaction.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(16))
      guard let self else { return }
      correctionPending = false
      applyCorrection()
    }
  }
  private func applyCorrection() {
    guard let view, !view.isTracking, !view.isDragging, !view.isDecelerating else { return }
    let frames = frames
    let correction: CGFloat
    if let readingAnchor, let frame = frames[readingAnchor.id] {
      correction =
        frame.minY - (readingAnchor.viewportTop ?? usableTop)
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
      view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
    }
  }
  func followToEnd() {
    guard let view else { return }
    let y = max(
      -view.adjustedContentInset.top,
      view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
    if abs(view.contentOffset.y - y) > 1 {
      view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
    }
  }
}

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
