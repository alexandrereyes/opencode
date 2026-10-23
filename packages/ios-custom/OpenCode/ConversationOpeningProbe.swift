#if DEBUG
import OpenCodeKit
import SwiftUI

@MainActor enum ConversationOpeningMetrics {
  static var id: String?
  static var started = ContinuousClock.now
  static var values: [String: Double] = [:]
  static var enabled: Bool { ProcessInfo.processInfo.environment["OPENCODE_OPENING_TRACE"] == "1" }

  static func begin(_ id: String) {
    guard enabled else { return }
    self.id = id
    started = .now
    values = [:]
  }

  static func mark(_ stage: String, id: String) {
    guard enabled, self.id == id, values[stage] == nil else { return }
    let duration = started.duration(to: .now).components
    values[stage] = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    if stage == "frame" {
      print("OPENING_FRAME \(values)")
      if let data = try? JSONEncoder().encode(values) {
        try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "opening-metrics.json"))
      }
    }
  }
}

struct ConversationOpeningProbe: UIViewRepresentable {
  let id: String
  let ready: Bool
  func makeUIView(context: Context) -> Probe { Probe() }
  func updateUIView(_ view: Probe, context: Context) {
    view.id = id
    view.ready = ready
    view.start()
  }
  final class Probe: UIView {
    var id = ""
    var ready = false
    var link: CADisplayLink?
    override init(frame: CGRect) {
      super.init(frame: frame)
      isAccessibilityElement = true
      accessibilityIdentifier = "opening-metrics"
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() { start() }
    func start() {
      guard window != nil, ready, ConversationOpeningMetrics.enabled, link == nil,
        ConversationOpeningMetrics.values["frame"] == nil else { return }
      let link = CADisplayLink(target: self, selector: #selector(presentFrame))
      self.link = link
      link.add(to: .main, forMode: .common)
    }
    @objc private func presentFrame() {
      link?.invalidate()
      link = nil
      ConversationOpeningMetrics.mark("frame", id: id)
      accessibilityValue = String(data: (try? JSONEncoder().encode(ConversationOpeningMetrics.values)) ?? Data(), encoding: .utf8)
    }
  }
}
#endif
