#if DEBUG
import Synchronization
import UIKit

/// The transcript's on-screen geometry, independent of how the transcript is implemented.
@MainActor protocol TranscriptGeometrySource: AnyObject {
  var geometryView: UIScrollView? { get }
  /// Rows that scroll with the content (pinned prompts excluded), relative to the visible area.
  var geometryRows: [String: CGRect] { get }
}

/// What the offline scroll driver needs from the transcript: a virtual finger.
@MainActor protocol TranscriptDriving: AnyObject {
  var simulatedTouch: Bool { get set }
  /// A real pan would start here; programmatic offsets do not.
  func userScrollBegan()
}

/// Response text view lifetimes and whole-text replacements, read by the streaming checks.
enum TranscriptCounters {
  static let created = Atomic<Int>(0)
  static let destroyed = Atomic<Int>(0)
  static let replaced = Atomic<Int>(0)
  static let appended = Atomic<Int>(0)
  static var values: [String: Int] {
    [
      "textViewsCreated": created.load(ordering: .relaxed),
      "textViewsDestroyed": destroyed.load(ordering: .relaxed),
      "textReplacements": replaced.load(ordering: .relaxed),
      "textAppends": appended.load(ordering: .relaxed),
    ]
  }
}

/// Records what the reader sees, one sample per displayed frame, from a navigation or scene event until the
/// transcript settles. An episode compares every frame that shows content with the passage the reader left
/// (`reference`) and with the passage it finally settles on, so a restoration that passes through another
/// passage counts even when its destination is right. Reports go to `Documents/transcript-trajectory.json`.
@MainActor final class TranscriptTrajectory {
  static let shared = TranscriptTrajectory()
  static let enabled = ProcessInfo.processInfo.arguments.contains("-OpenCodeTrajectory")
  weak var geometry: TranscriptGeometrySource?
  private(set) var episode: Episode?
  private var episodes: [[String: Any]] = []
  private var link: CADisplayLink?
  private var observers: [NSObjectProtocol] = []
  private var resigned: [String: CGRect]?

  final class Episode {
    let kind: String
    let reference: [String: CGRect]?
    let started: CFTimeInterval
    var samples: [(time: CFTimeInterval, rows: [String: CGRect])] = []
    var changed: CFTimeInterval
    init(kind: String, reference: [String: CGRect]?) {
      self.kind = kind
      self.reference = reference
      started = CACurrentMediaTime()
      changed = started
    }
  }

  func start() {
    guard Self.enabled, link == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    self.link = link
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          let shared = TranscriptTrajectory.shared
          shared.finish()
          shared.resigned = shared.rows
        }
      },
      center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          let shared = TranscriptTrajectory.shared
          shared.begin("background", reference: shared.resigned)
        }
      },
    ]
    begin("open", reference: nil)
  }

  /// Visible rows now; empty while no transcript is on screen.
  var rows: [String: CGRect] {
    // A hidden transcript shows nothing: its rows are not what the reader sees.
    guard let view = geometry?.geometryView, view.window != nil, !view.isHidden, view.alpha > 0.01 else { return [:] }
    let visible = CGRect(origin: .zero, size: view.bounds.size)
    return (geometry?.geometryRows ?? [:]).filter { $0.value.intersects(visible) && $0.value.height > 0 }
  }

  func begin(_ kind: String, reference: [String: CGRect]?) {
    finish()
    episode = Episode(kind: kind, reference: reference)
  }

  /// Waits until the current episode has settled and been reported.
  func settled() async {
    while episode != nil {
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
    }
  }

  @objc private func tick(_ link: CADisplayLink) {
    guard let episode else { return }
    let rows = rows
    if let previous = episode.samples.last?.rows,
      Set(previous.keys) != Set(rows.keys) || (Self.deviation(previous, rows) ?? .infinity) > 0.25
    {
      episode.changed = link.timestamp
    }
    episode.samples.append((link.timestamp, rows))
    let elapsed = link.timestamp - episode.started
    if (elapsed >= 2.5 && link.timestamp - episode.changed >= 1.5 && !rows.isEmpty) || elapsed >= 12 { finish() }
  }

  private func finish() {
    guard let episode else { return }
    self.episode = nil
    let content = episode.samples.filter { !$0.rows.isEmpty }
    let final = content.last?.rows ?? [:]
    func wrong(_ target: [String: CGRect]) -> Int {
      content.filter { (Self.deviation($0.rows, target) ?? .infinity) > 0.5 }.count
    }
    let steps = zip(content, content.dropFirst()).compactMap { Self.deviation($0.rows, $1.rows) }
    var report: [String: Any] = [
      "kind": episode.kind,
      "frames": episode.samples.count,
      "blankFrames": episode.samples.count - content.count,
      "contentFrames": content.count,
      "wrongFrames": wrong(final),
      "maxStepPoints": steps.max() ?? 0,
      "firstContentMS": content.first.map { ($0.time - episode.started) * 1000 } ?? -1,
      "settledMS": (episode.changed - episode.started) * 1000,
      "finalTop": Self.top(final),
    ]
    // The rows of the first wrong frame that differ, for diagnosis.
    if let first = content.first(where: { (Self.deviation($0.rows, episode.reference ?? final) ?? .infinity) > 0.5 }) {
      let target = episode.reference ?? final
      report["firstWrong"] = first.rows.compactMap { id, frame -> String? in
        guard let other = target[id], abs(other.minY - frame.minY) > 0.5 else { return nil }
        return "\(id) \(String(format: "%.1f→%.1f h%.1f→%.1f", frame.minY, other.minY, frame.height, other.height))"
      }.sorted().prefix(6).joined(separator: "; ")
      report["firstWrongMS"] = (first.time - episode.started) * 1000
    }
    if let reference = episode.reference {
      report["exitWrongFrames"] = wrong(reference)
      report["firstExitDeviation"] = content.first.map { Self.deviation($0.rows, reference) ?? -1 } ?? -1
      report["finalExitDeviation"] = Self.deviation(final, reference) ?? -1
      report["exitTop"] = Self.top(reference)
    }
    episodes.append(report)
    let arguments = ProcessInfo.processInfo.arguments
    let run = arguments.firstIndex(of: "-OpenCodeFixtureRunID").flatMap {
      arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
    } ?? ""
    if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
      let data = try? JSONSerialization.data(
        withJSONObject: ["runID": run, "episodes": episodes], options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: url.appendingPathComponent("transcript-trajectory.json"), options: .atomic)
    }
    NSLog("TRAJECTORY %@", String(describing: report))
  }

  /// The largest vertical difference between rows shown in both samples; nil when they share no row,
  /// that is, when they show different passages.
  static func deviation(_ a: [String: CGRect], _ b: [String: CGRect]) -> CGFloat? {
    let common = a.keys.filter { b[$0] != nil }
    guard !common.isEmpty else { return nil }
    return common.map { abs(a[$0]!.minY - b[$0]!.minY) }.max()
  }

  private static func top(_ rows: [String: CGRect]) -> String {
    guard let row = rows.min(by: { $0.value.minY < $1.value.minY }) else { return "" }
    return "\(row.key)@\(String(format: "%.2f", row.value.minY))"
  }
}
#endif
