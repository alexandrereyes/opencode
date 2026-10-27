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
    private let mode: Mode = {
      let arguments = ProcessInfo.processInfo.arguments
      return arguments.contains("-OpenCodeFixtureHold") ? .hold
        : arguments.contains("-OpenCodeFixtureFlings") ? .flings
        : arguments.contains("-OpenCodeFixtureScrollUp") ? .up : .oscillate
    }()
    private var rows: [String: CGRect] = [:]
    private var applied: CGFloat = 0
    private var jumps: [CGFloat] = []
    private var lastOffset: CGFloat?
    private var backward: CGFloat = 0
    private var replaced = 0
    private var moved = 0
    private var growingShift: CGFloat = 0
    private var counters: [String: Int] = [:]
    /// `oscillate` replays absolute offsets; `up` moves like a finger through unmeasured history;
    /// `flings` alternates 0.9 s of that touch with 0.5 s at rest, when held history pages are admitted;
    /// `hold` never scrolls, so following and streaming own every offset change.
    private enum Mode { case oscillate, up, flings, hold }

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
            if mode != .hold { ScrollFixtures.driving?.userScrollBegan() }
            startCPU = cpuTime()
            startMainCPU = mainThreadCPUTime()
            counters = TranscriptCounters.values
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
      // Unrequested on-screen movement of the visible rows (prepends, self-sizing, corrections, following).
      // A row that changed height still counts by its top edge: it is the response the reader is watching grow.
      let state = ScrollFixtures.driving
      let current = TranscriptTrajectory.shared.geometry?.geometryRows ?? [:]
      let viewport = CGRect(origin: .zero, size: scroll.bounds.size)
      var growing: [CGFloat] = []
      let moves = current.compactMap { id, frame in
        // Only rows on screen in both samples: List parks prefetched cells far outside the viewport
        // and lays them out lazily, and a recycled probe briefly reports another message's cell.
        rows[id].flatMap { previous -> CGFloat? in
          guard previous.intersects(viewport), frame.intersects(viewport) else { return nil }
          let move = frame.minY - previous.minY + applied
          if abs(previous.height - frame.height) > 0.5 { growing.append(abs(move)) }
          return move
        }
      }.sorted()
      if !moves.isEmpty {
        jumps.append(abs(moves[moves.count / 2]))
        if abs(moves[moves.count / 2]) > 0.5 {
          moved += 1
          if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics") {
            NSLog("DRIVER moved %.1f applied=%.1f offset=%.1f rows=%@", moves[moves.count / 2], applied,
              scroll.contentOffset.y, current.keys.sorted().prefix(4).joined(separator: ","))
          }
        }
      }
      growingShift = max(growingShift, growing.max() ?? 0)
      // A small scroll step that shows none of the previous rows replaced the content (an uncorrected prepend).
      let shown = { (frames: [String: CGRect]) in Set(frames.filter { $0.value.intersects(viewport) }.keys) }
      let before = shown(rows)
      let after = shown(current)
      if !before.isEmpty, !after.isEmpty, before.isDisjoint(with: after), abs(applied) < viewport.height / 2 { replaced += 1 }
      rows = current
      if let lastOffset { backward = max(backward, lastOffset - scroll.contentOffset.y) }
      lastOffset = scroll.contentOffset.y
      let interval = CGFloat(samples.last ?? 0) / 1000
      let target: CGFloat
      switch mode {
      case .hold: applied = 0; return
      case .flings where elapsed.truncatingRemainder(dividingBy: 1.4) >= 0.9:
        state?.simulatedTouch = false
        applied = 0
        return
      case .flings:
        // Each fling begins a new pan, which cancels anchors; resting admits held pages.
        if state?.simulatedTouch == false { state?.userScrollBegan() }
        state?.simulatedTouch = true
        target = max(top, scroll.contentOffset.y - 1500 * interval)
      case .up:
        // A real pan begins here; programmatic offsets do not.
        state?.userScrollBegan()
        target = max(top, scroll.contentOffset.y - 1500 * interval)
      case .oscillate:
        let phase = elapsed.truncatingRemainder(dividingBy: 6)
        target = min(bottom, max(top, origin + CGFloat(phase < 3 ? phase : 6 - phase) * 1440))
      }
      distance += abs(scroll.contentOffset.y - target)
      applied = target - scroll.contentOffset.y
      lastOffset = target
      scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    private func finish() {
      if let interval { signposter.endInterval("FixtureScroll", interval) }
      interval = nil
      let sorted = samples.sorted()
      let arguments = ProcessInfo.processInfo.arguments
      let run = arguments.firstIndex(of: "-OpenCodeFixtureRunID").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
      }
      var report: [String: Any] = [
        "runID": run ?? "",
        "movedFrames": moved, "growingShiftMaxPoints": growingShift,
        "mode": ScrollFixtures.mode ?? "", "frames": samples.count,
        "durationMS": samples.reduce(0, +), "cpuMS": (cpuTime() - startCPU) * 1000,
        "mainThreadCPU_MS": (mainThreadCPUTime() - startMainCPU) * 1000,
        "distancePoints": distance,
        "p50FrameMS": sorted.isEmpty ? 0 : sorted[sorted.count / 2],
        "p95FrameMS": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
        "maxFrameMS": sorted.last ?? 0,
        "over33": samples.filter { $0 > 33.4 }.count, "over50": samples.filter { $0 > 50 }.count,
        "over100": samples.filter { $0 > 100 }.count,
        "jumpMaxPoints": jumps.max() ?? 0, "jumpTotalPoints": jumps.reduce(0, +),
        "backwardPoints": backward, "replacedFrames": replaced,
        "tailGapPoints": scroll.map { max(0, $0.contentSize.height + $0.adjustedContentInset.bottom - $0.bounds.height - $0.contentOffset.y) } ?? 0,
        "stallRatio60Hz": samples.reduce(0) { $0 + max(0, $1 - 1000 / 60) } / max(1, samples.reduce(0, +)),
      ]
      for (key, value) in TranscriptCounters.values { report[key] = value - (counters[key] ?? 0) }
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
      ScrollFixtures.driving?.simulatedTouch = false
      startup?.cancel()
      startup = nil
      link?.invalidate()
      link = nil
    }
  }
}
#endif
