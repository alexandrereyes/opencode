#if DEBUG
import Darwin
import OSLog
import SwiftUI

struct ScrollFixtureDriver: UIViewRepresentable {
  func makeUIView(context: Context) -> Driver { Driver() }
  func updateUIView(_ view: Driver, context: Context) {}
  static func dismantleUIView(_ view: Driver, coordinator: ()) { view.stop() }

  final class Driver: UIView {
    private let signposter = OSSignposter(subsystem: "br.com.alexandrem.opencode", category: "PointsOfInterest")
    private var interval: OSSignpostIntervalState?
    private var link: CADisplayLink?
    private var startup: Task<Void, Never>?
    private weak var scroll: UIScrollView?
    private var started: CFTimeInterval = 0
    private var previous: CFTimeInterval = 0
    private var samples: [Double] = []
    private var startCPU: Double = 0
    private var startMainCPU: Double = 0
    private var origin: CGFloat = 0
    private var distance: CGFloat = 0

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil, ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureAutoScroll"),
        startup == nil, link == nil else { return }
      startup = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        guard let self else { return }
        for _ in 0..<200 {
          if let window, let scroll = findScroll(window) {
            self.scroll = scroll
            ScrollFixtures.scrollState?.cancelAnchor()
            startCPU = cpuTime()
            startMainCPU = mainThreadCPUTime()
            origin = scroll.contentOffset.y
            interval = signposter.beginInterval("FixtureScroll")
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            self.link = link
            link.add(to: .main, forMode: .common)
            return
          }
          do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
      }
    }

    private func findScroll(_ view: UIView) -> UIScrollView? {
      if let scroll = view as? UICollectionView, scroll.bounds.height > 200 { return scroll }
      return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }

    @objc private func tick(_ link: CADisplayLink) {
      guard let scroll else { stop(); return }
      if started == 0 { started = link.timestamp; previous = link.timestamp }
      if link.timestamp > previous { samples.append((link.timestamp - previous) * 1000) }
      previous = link.timestamp
      let elapsed = link.timestamp - started
      guard elapsed < 12 else { finish(); return }
      let top = -scroll.adjustedContentInset.top
      let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
      let phase = elapsed.truncatingRemainder(dividingBy: 6)
      let offset = origin + CGFloat(phase < 3 ? phase : 6 - phase) * 1440
      let target = min(bottom, max(top, offset))
      distance += abs(scroll.contentOffset.y - target)
      scroll.setContentOffset(
        CGPoint(x: 0, y: target), animated: false)
    }

    private func finish() {
      if let interval { signposter.endInterval("FixtureScroll", interval) }
      interval = nil
      let sorted = samples.sorted()
      let arguments = ProcessInfo.processInfo.arguments
      let run = arguments.firstIndex(of: "-OpenCodeFixtureRunID").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
      }
      let report: [String: Any] = [
        "runID": run ?? "",
        "mode": ScrollFixtures.mode ?? "", "frames": samples.count,
        "durationMS": samples.reduce(0, +), "cpuMS": (cpuTime() - startCPU) * 1000,
        "mainThreadCPU_MS": (mainThreadCPUTime() - startMainCPU) * 1000,
        "distancePoints": distance,
        "p50FrameMS": sorted.isEmpty ? 0 : sorted[sorted.count / 2],
        "p95FrameMS": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
        "maxFrameMS": sorted.last ?? 0,
        "stallRatio60Hz": samples.reduce(0) { $0 + max(0, $1 - 1000 / 60) } / max(1, samples.reduce(0, +)),
      ]
      if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          .write(to: url.appendingPathComponent("scroll-fixture-metrics.json"), options: .atomic)
      }
      stop()
    }

    private func cpuTime() -> Double {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func mainThreadCPUTime() -> Double {
      let thread = mach_thread_self()
      defer { mach_port_deallocate(mach_task_self_, thread) }
      var info = thread_basic_info()
      var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
      let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
      }
      guard status == KERN_SUCCESS else { return 0 }
      return Double(info.user_time.seconds + info.system_time.seconds)
        + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    func stop() {
      startup?.cancel()
      startup = nil
      link?.invalidate()
      link = nil
    }
  }
}
#endif
