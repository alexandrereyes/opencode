#if DEBUG
import Darwin
import OSLog
import SwiftUI

/// Identical measurement harness for shipped and candidate scroll owners; never starts a server.
struct ScrollGrowthMeasurement: UIViewRepresentable {
  let store: ConversationStore
  let state: ConversationScrollState
  func makeUIView(context: Context) -> Driver { Driver(store: store, state: state) }
  func updateUIView(_ view: Driver, context: Context) {}
  static func dismantleUIView(_ view: Driver, coordinator: ()) { view.stop() }

  final class Driver: UIButton {
    private let store: ConversationStore
    private let scrollState: ConversationScrollState
    private let signposter = OSSignposter(subsystem: "br.com.alexandrem.opencode", category: "PointsOfInterest")
    private var interval: OSSignpostIntervalState?
    private var task: Task<Void, Never>?
    private var link: CADisplayLink?
    private var frames: [Double] = []
    private var offsets: [Double] = []
    private var previous: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var cpu: Double = 0
    init(store: ConversationStore, state: ConversationScrollState) {
      self.store = store
      scrollState = state
      super.init(frame: .zero)
      accessibilityIdentifier = "growth-measurement"
      accessibilityValue = "ready"
      setTitle("Medir crescimento", for: .normal)
      addAction(UIAction { [weak self] _ in self?.start() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil, ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureAutoGrowth") else { return }
      task = Task { @MainActor [weak self] in
        let arguments = ProcessInfo.processInfo.arguments
        let delay = arguments.firstIndex(of: "-OpenCodeFixtureGrowthDelay").flatMap {
          arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil
        } ?? 3
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        self?.task = nil
        self?.start()
      }
    }
    private func start() {
      guard task == nil else { return }
      frames = []
      offsets = []
      previous = 0
      started = CACurrentMediaTime()
      cpu = cpuTime()
      accessibilityValue = "running"
      interval = signposter.beginInterval("FixtureGrowth")
      let link = CADisplayLink(target: self, selector: #selector(sample(_:)))
      self.link = link
      link.add(to: .main, forMode: .common)
      task = Task { @MainActor [weak self] in
        guard let self else { return }
        for iteration in 0..<60 {
          store.growScrollFixture(iteration)
          do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
        finish()
      }
    }
    @objc private func sample(_ link: CADisplayLink) {
      if previous > 0 { frames.append((link.timestamp - previous) * 1000) }
      previous = link.timestamp
      if let view = scrollState.view { offsets.append(view.contentOffset.y) }
    }
    private func finish() {
      if let interval { signposter.endInterval("FixtureGrowth", interval) }
      interval = nil
      let sorted = frames.sorted()
      let elapsed = CACurrentMediaTime() - started
      let report: [String: Double] = [
        "cpuMS": (cpuTime() - cpu) * 1000, "durationMS": elapsed * 1000,
        "fps": Double(frames.count) / max(0.001, frames.reduce(0, +) / 1000),
        "p95FrameMS": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
        "maxFrameMS": sorted.last ?? 0,
        "backward": zip(offsets, offsets.dropFirst()).map { max(0, $0 - $1) }.max() ?? 0,
        "advance": (offsets.last ?? 0) - (offsets.first ?? 0),
      ]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
        let json = String(data: data, encoding: .utf8)
      {
        accessibilityValue = json
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
          try? data.write(to: url.appendingPathComponent("scroll-growth-metrics.json"), options: .atomic)
        }
      }
      stop()
    }
    private func cpuTime() -> Double {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
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
