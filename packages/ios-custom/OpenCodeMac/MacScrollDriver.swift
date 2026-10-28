#if DEBUG
import AppKit
import OpenCodeKit
import QuartzCore

/// The iPhone's scroll driver on the Mac transcript (`-OpenCodeScrollFixture conversation` with
/// `-OpenCodeMacScrollReport <file.json>`): for 12 seconds it moves the transcript the way a reader would and
/// records every displayed frame, then writes the report and quits.
///
/// - `-OpenCodeFixtureScrollUp`: 1,500 pt/s upward, like a trackpad swipe through never-measured history;
/// - `-OpenCodeFixtureFlings`: 0.9 s of that motion, then 0.5 s at rest;
/// - `-OpenCodeFixtureHold`: never moves (streaming while following, or while reading mid-history);
/// - otherwise it reads down and up through 3,000 points around the opening place.
///
/// The report counts frame intervals (p50/p95/max, over 33/50/100 ms), main-thread CPU, the unrequested on-screen
/// movement of rows visible in consecutive frames, frames whose rows were all replaced (an uncorrected prepend),
/// and the final distance from the end.
@MainActor final class MacScrollDriver: NSObject {
  static var shared: MacScrollDriver?
  private let controller: MacTranscriptController
  private let output: String?
  private var link: CADisplayLink?
  private var start: CFTimeInterval = 0
  private var last: CFTimeInterval = 0
  private var intervals: [Double] = []
  private var rows: [String: CGRect] = [:]
  private var offset: CGFloat = 0
  private var origin: CGFloat = 0
  private var jumpMax: CGFloat = 0
  private var jumpTotal: CGFloat = 0
  private var moved = 0
  private var replaced = 0
  private var backward: CGFloat = 0
  private var growing: CGFloat = 0
  private var cpuStart = 0.0
  private let mode: String
  private let duration = 12.0

  static func start(_ controller: MacTranscriptController) {
    let arguments = ProcessInfo.processInfo.arguments
    let output = ScrollFixtures.argument("-OpenCodeMacScrollReport")
    guard shared == nil, output != nil || arguments.contains("-OpenCodeFixtureScrollUp")
      || arguments.contains("-OpenCodeFixtureFlings") else { return }
    let driver = MacScrollDriver(controller: controller, output: output)
    shared = driver
    if output != nil, let window = controller.view.window {
      // Off-screen at a fixed size (the stage-3 mocks' by default), so runs compare and never sit under the pointer.
      let size = ScrollFixtures.argument("-OpenCodeMacCaptureSize")?.split(separator: "x").compactMap { Double($0) }
      window.setFrame(NSRect(x: -4000, y: 40, width: size?.first ?? 1269, height: size?.last ?? 794), display: true)
    }
    Task { @MainActor in
      // The transcript opens first; measuring starts once it is shown and settled.
      try? await Task.sleep(for: .seconds(2))
      driver.begin()
    }
  }

  private init(controller: MacTranscriptController, output: String?) {
    self.controller = controller
    self.output = output
    let arguments = ProcessInfo.processInfo.arguments
    mode = arguments.contains("-OpenCodeFixtureScrollUp") ? "up"
      : arguments.contains("-OpenCodeFixtureFlings") ? "flings"
      : arguments.contains("-OpenCodeFixtureHold") ? "hold" : "read"
  }

  private func begin() {
    let scroll = controller.scrollViewForDriver
    origin = scroll.contentView.bounds.minY
    offset = origin
    rows = controller.visibleRows
    cpuStart = Self.mainThreadCPU()
    let link = scroll.displayLink(target: self, selector: #selector(frame(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
    start = CACurrentMediaTime()
    last = start
    // A locked screen displays nothing, so the display link never fires: a 60 Hz timer drives instead and draws
    // the window on each tick, so the work of every frame still delays the next one.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard let self, self.intervals.isEmpty, self.link != nil else { return }
      self.link?.invalidate()
      self.link = nil
      self.clock = "timer"
      self.start = CACurrentMediaTime()
      self.last = self.start
      let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.tick()
          self?.controller.view.window?.displayIfNeeded()
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }
  }
  private var timer: Timer?
  private var clock = "display"

  @objc private func frame(_ link: CADisplayLink) { tick() }

  private func tick() {
    let now = CACurrentMediaTime()
    intervals.append((now - last) * 1000)
    let dt = now - last
    last = now
    let elapsed = now - start
    // Rows that stayed on screen since the previous frame moved only by what was requested.
    let current = controller.visibleRows
    let scroll = controller.scrollViewForDriver
    let actual = scroll.contentView.bounds.minY
    // What the driver asked for since the rows were recorded; anything else on screen moved by itself.
    let requested = intended
    let shared = Set(current.keys).intersection(rows.keys)
    if !rows.isEmpty, !current.isEmpty, shared.isEmpty, abs(requested) < 200 { replaced += 1 }
    var worst: CGFloat = 0
    for id in shared {
      let movement = abs((current[id]!.minY - rows[id]!.minY) + requested)
      // The row that changed height is the answer the reader watches grow; it is reported on its own.
      if abs(current[id]!.height - rows[id]!.height) > 0.5 {
        growing = max(growing, movement)
        continue
      }
      worst = max(worst, movement)
    }
    if worst > 20, ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics") {
      for id in shared where abs((current[id]!.minY - rows[id]!.minY) + requested) > 20 {
        macTrace(String(format: "jump %@ %.1f -> %.1f requested=%.1f actual=%.1f", id, rows[id]!.minY,
          current[id]!.minY, requested, actual))
      }
    }
    if worst > 0.5 {
      moved += 1
      jumpTotal += worst
      jumpMax = max(jumpMax, worst)
    }
    if mode == "hold", actual < offset - 0.5 { backward = max(backward, offset - actual) }
    rows = current
    origin = actual
    offset = actual
    intended = 0
    guard elapsed < duration else { return finish() }
    let step = CGFloat(1500 * dt)
    switch mode {
    case "up":
      controller.simulateScroll(by: -step)
    case "flings":
      if elapsed.truncatingRemainder(dividingBy: 1.4) < 0.9 { controller.simulateScroll(by: -step) } else {
        controller.simulateRest()
      }
    case "hold":
      break
    default:
      let phase = elapsed.truncatingRemainder(dividingBy: 4)
      controller.simulateScroll(by: phase < 2 ? step : -step)
    }
    offset = scroll.contentView.bounds.minY
    intended = mode == "hold" ? 0 : controller.lastSimulatedDelta
  }
  private var intended: CGFloat = 0

  private func finish() {
    link?.invalidate()
    link = nil
    timer?.invalidate()
    timer = nil
    controller.simulateRest()
    let sorted = intervals.dropFirst().sorted()
    func percentile(_ value: Double) -> Double {
      sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * value))]
    }
    let report: [String: Any] = [
      "mode": mode, "clock": clock,
      "frames": intervals.count,
      "p50FrameMS": percentile(0.5), "p95FrameMS": percentile(0.95), "maxFrameMS": sorted.last ?? 0,
      "over33": sorted.filter { $0 > 33.4 }.count, "over50": sorted.filter { $0 > 50 }.count,
      "over100": sorted.filter { $0 > 100 }.count,
      "mainThreadCPU_MS": (Self.mainThreadCPU() - cpuStart) * 1000,
      "jumpMaxPoints": jumpMax, "jumpTotalPoints": jumpTotal, "movedFrames": moved, "replacedFrames": replaced,
      "backwardPoints": backward, "growingShiftMaxPoints": growing, "tailGapPoints": controller.distanceToLatest,
      "messages": controller.store.messages.count, "items": controller.items.count,
    ]
    guard let output else { return }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: URL(fileURLWithPath: output))
    }
    NSApp.terminate(nil)
  }

  /// User and system time of the main thread, in seconds.
  static func mainThreadCPU() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let thread = pthread_mach_thread_np(pthread_self())
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return 0 }
    return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
      + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
  }
}
#endif
