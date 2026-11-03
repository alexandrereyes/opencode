import Foundation

/// The audio route of a call on the iPhone: the port types (`BluetoothHFP`, `MicrophoneBuiltIn`, `Speaker`…) and the
/// session's hardware sample rate. Bluetooth HFP runs at 8 kHz (narrowband) or 16 kHz (wideband).
public struct VoiceAudioRoute: Codable, Equatable, Sendable {
  public let inputs: [String]
  public let outputs: [String]
  public let sampleRate: Int?

  public init(inputs: [String], outputs: [String], sampleRate: Double?) {
    self.inputs = Self.ports(inputs); self.outputs = Self.ports(outputs)
    self.sampleRate = sampleRate.flatMap { $0.isFinite && $0 >= 1 && $0 < 1_000_000 ? Int($0.rounded()) : nil }
  }
  private static func ports(_ names: [String]) -> [String] {
    Array(names.map(VoiceDiagnosticName.label).filter { !$0.isEmpty }.prefix(4))
  }
}

/// One reading of a link's WebRTC statistics (`RTCPeerConnection.statistics`, as libwebrtc M147 names them) and of
/// the audio route. Counters are cumulative since the link started; a field the report lacked is `nil`.
public struct VoiceQualitySample: Equatable, Sendable {
  /// Monotonic seconds (`systemUptime`) when it was read.
  public var at: TimeInterval
  /// `inbound-rtp` (audio): what Alexandre hears.
  public var packetsReceived: Double?
  public var packetsLost: Double?
  /// Interarrival jitter in seconds, libwebrtc's running estimate when read.
  public var jitter: Double?
  public var concealedSamples: Double?
  public var silentConcealedSamples: Double?
  public var totalSamplesReceived: Double?
  public var concealmentEvents: Double?
  public var insertedSamplesForDeceleration: Double?
  public var removedSamplesForAcceleration: Double?
  /// Seconds, summed over every sample the jitter buffer emitted (`jitterBufferEmittedCount`).
  public var jitterBufferDelay: Double?
  public var jitterBufferEmittedCount: Double?
  /// `outbound-rtp` and `remote-inbound-rtp` (audio): what GPT Live gets of his voice, as its RTCP reports say.
  public var packetsSent: Double?
  public var remotePacketsLost: Double?
  public var remoteFractionLost: Double?
  public var remoteRoundTripTime: Double?
  /// The selected candidate pair's `currentRoundTripTime`, in seconds.
  public var roundTripTime: Double?
  /// That pair's local candidate as `type/protocol/network` (`srflx/udp/cellular`), never its address.
  public var path: String?
  public var route: VoiceAudioRoute?

  public init(at: TimeInterval, route: VoiceAudioRoute? = nil) { self.at = at; self.route = route }

  /// Reads a statistics report given as each statistic's `type` and `values` by its ID.
  public init(at: TimeInterval, statistics: [String: (type: String, values: [String: Any])], route: VoiceAudioRoute? = nil) {
    self.init(at: at, route: route)
    let audio = { (type: String) -> [String: Any] in
      statistics.values.first { $0.type == type && ($0.values["kind"] ?? $0.values["mediaType"]) as? String == "audio" }?
        .values ?? [:]
    }
    let inbound = audio("inbound-rtp"), outbound = audio("outbound-rtp"), remote = audio("remote-inbound-rtp")
    packetsReceived = Self.number(inbound["packetsReceived"]); packetsLost = Self.number(inbound["packetsLost"])
    jitter = Self.number(inbound["jitter"])
    concealedSamples = Self.number(inbound["concealedSamples"])
    silentConcealedSamples = Self.number(inbound["silentConcealedSamples"])
    totalSamplesReceived = Self.number(inbound["totalSamplesReceived"])
    concealmentEvents = Self.number(inbound["concealmentEvents"])
    insertedSamplesForDeceleration = Self.number(inbound["insertedSamplesForDeceleration"])
    removedSamplesForAcceleration = Self.number(inbound["removedSamplesForAcceleration"])
    jitterBufferDelay = Self.number(inbound["jitterBufferDelay"])
    jitterBufferEmittedCount = Self.number(inbound["jitterBufferEmittedCount"])
    packetsSent = Self.number(outbound["packetsSent"])
    remotePacketsLost = Self.number(remote["packetsLost"]); remoteFractionLost = Self.number(remote["fractionLost"])
    remoteRoundTripTime = Self.number(remote["roundTripTime"])
    let selected = (statistics.values.first { $0.type == "transport" }?.values["selectedCandidatePairId"] as? String)
      .flatMap { statistics[$0]?.values }
    let pair = selected ?? statistics.values.first {
      $0.type == "candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue == true
        && $0.values["state"] as? String == "succeeded"
    }?.values
    roundTripTime = Self.number(pair?["currentRoundTripTime"])
    if let id = pair?["localCandidateId"] as? String, let local = statistics[id]?.values {
      let network = local["networkAdapterType"] ?? local["networkType"]
      let parts = [local["candidateType"], local["protocol"], network].compactMap { $0 as? String }
      path = parts.isEmpty ? nil : String(VoiceDiagnosticName.code(parts.joined(separator: "/")).prefix(64))
    }
  }

  private static func number(_ value: Any?) -> Double? {
    guard let value = (value as? NSNumber)?.doubleValue, value.isFinite else { return nil }
    return value
  }
  /// Whether it carries the link's counters, not only the route.
  var counts: Bool { packetsReceived != nil || totalSamplesReceived != nil || packetsSent != nil }
}

/// A call's audio quality, summed from its links' samples: numbers and short labels only, sent with the diagnostic
/// report of the call's end (`ended`, `lost`, `failed`). Percentages are 0–100; times in milliseconds; `nil` where the
/// statistics never had the field.
public struct VoiceQuality: Codable, Equatable, Sendable {
  /// The window that went worst: seconds since the call's first sample, the measure furthest past its limit (`cause`:
  /// `concealed`, `loss_in`, `loss_out`, `jitter`) and its numbers.
  public struct Worst: Codable, Equatable, Sendable {
    public let atSeconds: Double
    public let cause: String
    public let concealedPct: Double?
    public let lossInPct: Double?
    public let lossOutPct: Double?
    public let jitterMs: Double?
  }
  public let seconds: Double
  public let windows: Int
  public let badWindows: Int
  public let links: Int
  public let lossInPct: Double?
  public let lossOutPct: Double?
  /// Played audio NetEq synthesized (not silence or comfort noise), and how many times it started doing so.
  public let concealedPct: Double?
  public let concealmentEvents: Int?
  /// Played audio NetEq added to slow down (stretched) or removed to catch up (compressed).
  public let stretchedPct: Double?
  public let compressedPct: Double?
  public let jitterMs: Double?
  public let jitterMaxMs: Double?
  /// Mean time a sample spent in the jitter buffer.
  public let bufferMs: Double?
  public let rttMs: Double?
  public let rttMaxMs: Double?
  public let worst: Worst?
  /// The last four distinct routes, and how many times the route changed.
  public let routes: [VoiceAudioRoute]
  public let routeChanges: Int
  /// The last four distinct local candidates the media used (`type/protocol/network`).
  public let paths: [String]
}

/// Sums a call's samples (`VoiceQualitySample`): two consecutive samples of one link make a window, about `interval`
/// long. Pure, so it is tested without WebRTC.
public struct VoiceQualityMeter: Sendable {
  /// How often the transport reads the statistics while a link is connected.
  public static let interval: TimeInterval = 5
  /// A window is bad past any of these: the concealed share of what played, packet loss either way, jitter in seconds.
  public static let limits = (concealed: 0.03, loss: 0.02, jitter: 0.030)

  private struct Window {
    let at: TimeInterval
    let concealed: Double?, lossIn: Double?, lossOut: Double?, jitter: Double?
    /// The measure furthest past its limit, and how far (1 is at the limit).
    var cause: (name: String, score: Double)? {
      let limits = VoiceQualityMeter.limits
      return [("concealed", concealed.map { $0 / limits.concealed }), ("loss_in", lossIn.map { $0 / limits.loss }),
       ("loss_out", lossOut.map { $0 / limits.loss }), ("jitter", jitter.map { $0 / limits.jitter })]
        .compactMap { name, score in score.map { (name, $0) } }
        .max { $0.1 < $1.1 }
    }
  }

  private var previous: VoiceQualitySample?
  private var first: TimeInterval?
  private var links = 0, windows = 0, bad = 0, seconds = 0.0
  private var received = 0.0, lost = 0.0, sent = 0.0, remoteLost = 0.0, fractions: [Double] = []
  private var played = 0.0, concealed = 0.0, inserted = 0.0, removed = 0.0, events = 0.0, delay = 0.0, emitted = 0.0
  private var jitters: [Double] = [], rtts: [Double] = []
  private var worst: Window?
  private var routes: [VoiceAudioRoute] = [], route: VoiceAudioRoute?, routeChanges = 0
  private var paths: [String] = []

  public init() {}

  /// A new link: its counters start from zero.
  public mutating func restart() { previous = nil }

  public mutating func add(_ sample: VoiceQualitySample) {
    if let next = sample.route {
      if let route, route != next { routeChanges += 1 }
      route = next; routes = Array((routes.filter { $0 != next } + [next]).suffix(4))
    }
    if let path = sample.path { paths = Array((paths.filter { $0 != path } + [path]).suffix(4)) }
    guard sample.counts else { return }
    first = first ?? sample.at
    if let rtt = sample.roundTripTime ?? sample.remoteRoundTripTime { rtts.append(rtt) }
    defer { previous = sample }
    // A link's first sample, or counters that went back (a new link nobody announced), is a baseline.
    guard let previous, sample.at > previous.at,
      !Self.counters.contains(where: { (Self.delta(previous, sample, $0) ?? 0) < 0 }) else { links += 1; return }
    let delta = { (key: KeyPath<VoiceQualitySample, Double?>) in Self.delta(previous, sample, key) }
    let inbound = delta(\.packetsReceived), missing = delta(\.packetsLost).map { max(0, $0) }
    let outbound = delta(\.packetsSent), missed = delta(\.remotePacketsLost).map { max(0, $0) }
    let output = delta(\.totalSamplesReceived)
    let synthesized = delta(\.concealedSamples).map { max(0, $0 - max(0, delta(\.silentConcealedSamples) ?? 0)) }
    if let inbound { received += inbound; lost += missing ?? 0 }
    // Without the server's RTCP reports there is no loss to set against what was sent.
    if let outbound, let missed { sent += outbound; remoteLost += missed }
    else if let fraction = sample.remoteFractionLost { fractions.append(fraction) }
    if let output {
      played += output; concealed += synthesized ?? 0
      inserted += max(0, delta(\.insertedSamplesForDeceleration) ?? 0)
      removed += max(0, delta(\.removedSamplesForAcceleration) ?? 0)
      events += max(0, delta(\.concealmentEvents) ?? 0)
    }
    delay += max(0, delta(\.jitterBufferDelay) ?? 0); emitted += max(0, delta(\.jitterBufferEmittedCount) ?? 0)
    if let jitter = sample.jitter { jitters.append(jitter) }
    let window = Window(at: sample.at, concealed: Self.ratio(synthesized, output),
      lossIn: Self.ratio(missing, inbound.map { $0 + (missing ?? 0) }),
      lossOut: Self.ratio(missed, outbound) ?? sample.remoteFractionLost, jitter: sample.jitter)
    windows += 1; seconds += sample.at - previous.at
    if let cause = window.cause {
      if cause.score > 1 { bad += 1 }
      if cause.score > (worst?.cause?.score ?? 0) { worst = window }
    }
  }
  /// Counters that only grow on one link.
  private static var counters: [KeyPath<VoiceQualitySample, Double?>] {
    [\.packetsReceived, \.totalSamplesReceived, \.packetsSent, \.jitterBufferEmittedCount]
  }

  public var summary: VoiceQuality? {
    guard windows > 0 || !routes.isEmpty || !paths.isEmpty else { return nil }
    let pct = { (ratio: Double) in Self.round(ratio * 100, 2) }
    let ms = { (seconds: Double) in Self.round(seconds * 1000, 1) }
    let mean = { (values: [Double]) in values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    return VoiceQuality(seconds: Self.round(seconds, 1), windows: windows, badWindows: bad, links: links,
      lossInPct: Self.ratio(lost, received + lost).map(pct),
      lossOutPct: (Self.ratio(remoteLost, sent) ?? mean(fractions)).map(pct),
      concealedPct: Self.ratio(concealed, played).map(pct), concealmentEvents: played > 0 ? Int(events) : nil,
      stretchedPct: Self.ratio(inserted, played).map(pct), compressedPct: Self.ratio(removed, played).map(pct),
      jitterMs: mean(jitters).map(ms), jitterMaxMs: jitters.max().map(ms),
      bufferMs: Self.ratio(delay, emitted).map(ms), rttMs: mean(rtts).map(ms), rttMaxMs: rtts.max().map(ms),
      worst: worst.flatMap { window in window.cause.map { cause in
        VoiceQuality.Worst(atSeconds: Self.round(window.at - (first ?? window.at), 1), cause: cause.name,
          concealedPct: window.concealed.map(pct), lossInPct: window.lossIn.map(pct),
          lossOutPct: window.lossOut.map(pct), jitterMs: window.jitter.map(ms))
      } },
      routes: routes, routeChanges: routeChanges, paths: paths)
  }

  private static func delta(_ before: VoiceQualitySample, _ after: VoiceQualitySample,
    _ key: KeyPath<VoiceQualitySample, Double?>) -> Double? {
    guard let now = after[keyPath: key], let then = before[keyPath: key] else { return nil }
    return now - then
  }
  private static func ratio(_ part: Double?, _ whole: Double?) -> Double? {
    guard let part, let whole, whole > 0 else { return nil }
    return part / whole
  }
  private static func round(_ value: Double, _ places: Int) -> Double {
    let scale = pow(10, Double(places))
    return (max(0, value) * scale).rounded() / scale
  }
}
