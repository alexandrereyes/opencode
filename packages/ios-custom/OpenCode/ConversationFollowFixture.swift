#if DEBUG
import OpenCodeKit
import SwiftUI

/// Grows the newest rows while recording the transcript's offset at display cadence, not XCTest's much slower
/// UI snapshots. Growth never scrolls: the offset must not change while the content height does.
struct ConversationFollowFixture: UIViewRepresentable {
  let store: ConversationStore
  let color: UIColor
  let view: () -> UIScrollView?
  func makeUIView(context: Context) -> Driver { Driver(store: store, view: view) }
  func updateUIView(_ view: Driver, context: Context) { view.setTitleColor(color, for: .normal) }
  static func dismantleUIView(_ view: Driver, coordinator: ()) { view.stop() }

  final class Driver: UIButton {
    private let store: ConversationStore
    private let scrollView: () -> UIScrollView?
    private var task: Task<Void, Never>?
    private var link: CADisplayLink?
    private var offsets: [Double] = []
    private var heights: [Double] = []
    private var iteration = 0
    init(store: ConversationStore, view: @escaping () -> UIScrollView?) {
      self.store = store
      scrollView = view
      super.init(frame: .zero)
      setTitle("Testar crescimento", for: .normal)
      accessibilityIdentifier = "follow-fixture"
      accessibilityValue = "ready"
      addAction(UIAction { [weak self] _ in self?.start() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { nil }
    private func start() {
      guard task == nil else { return }
      accessibilityValue = "running"
      offsets = []
      heights = []
      let link = CADisplayLink(target: self, selector: #selector(sample))
      self.link = link
      link.add(to: .main, forMode: .common)
      task = Task { @MainActor [weak self] in
        guard let self else { return }
        for _ in 0..<24 {
          store.growScrollFixture(iteration)
          iteration += 1
          do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
        finish()
      }
    }
    @objc private func sample() {
      // Display-link callbacks precede the layout of that frame; sample what it committed.
      Task { @MainActor [weak self] in
        guard let self, link != nil, let view = scrollView() else { return }
        offsets.append(view.contentOffset.y)
        heights.append(view.contentSize.height)
      }
    }
    private func finish() {
      link?.invalidate()
      link = nil
      guard let view = scrollView() else { return }
      let report: [String: Double] = [
        "backward": zip(offsets, offsets.dropFirst()).map { max(0, $0 - $1) }.max() ?? 0,
        "forward": zip(offsets, offsets.dropFirst()).map { max(0, $1 - $0) }.max() ?? 0,
        "advance": (offsets.last ?? 0) - (offsets.first ?? 0),
        "heightChanges": Double(zip(heights, heights.dropFirst()).filter { abs($0 - $1) > 1 }.count),
        "samples": Double(offsets.count),
        "below": view.contentSize.height - view.bounds.height - view.contentOffset.y,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
        let json = String(data: data, encoding: .utf8)
      {
        accessibilityValue = json
        NSLog("FOLLOW fixture %@", json)
      }
      task = nil
    }
    func stop() {
      task?.cancel()
      task = nil
      link?.invalidate()
      link = nil
    }
  }
}
#endif
