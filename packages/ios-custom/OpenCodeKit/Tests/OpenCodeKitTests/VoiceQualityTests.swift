import Foundation
import Testing

@testable import OpenCodeKit

struct VoiceQualityTests {
  private static let headset = VoiceAudioRoute(inputs: ["BluetoothHFP"], outputs: ["BluetoothHFP"], sampleRate: 16_000)
  private static let builtIn = VoiceAudioRoute(inputs: ["MicrophoneBuiltIn"], outputs: ["Speaker"], sampleRate: 48_000)

  /// Cumulative counters of one link at `at`, 48 kHz audio and 20 ms packets.
  private func sample(_ at: TimeInterval, received: Double, lost: Double = 0, played: Double, concealed: Double = 0,
    silent: Double = 0, inserted: Double = 0, removed: Double = 0, events: Double = 0, delay: Double = 0,
    jitter: Double, sent: Double, remoteLost: Double = 0, rtt: Double, route: VoiceAudioRoute? = nil,
    path: String? = nil) -> VoiceQualitySample {
    var value = VoiceQualitySample(at: at, route: route)
    value.packetsReceived = received; value.packetsLost = lost; value.totalSamplesReceived = played
    value.concealedSamples = concealed; value.silentConcealedSamples = silent
    value.insertedSamplesForDeceleration = inserted; value.removedSamplesForAcceleration = removed
    value.concealmentEvents = events; value.jitterBufferDelay = delay; value.jitterBufferEmittedCount = played
    value.jitter = jitter; value.packetsSent = sent; value.remotePacketsLost = remoteLost; value.roundTripTime = rtt
    value.path = path
    return value
  }

  @Test func readsTheStatisticsLibWebRTCReportsWithoutAddresses() {
    let statistics: [String: (type: String, values: [String: Any])] = [
      "IT01A": ("inbound-rtp", ["kind": "audio", "packetsReceived": 500, "packetsLost": 5, "jitter": 0.012,
        "concealedSamples": 4_800, "silentConcealedSamples": 960, "totalSamplesReceived": 480_000, "concealmentEvents": 3,
        "insertedSamplesForDeceleration": 1_200, "removedSamplesForAcceleration": 2_400, "jitterBufferDelay": 28_800.5,
        "jitterBufferEmittedCount": 480_000]),
      "IT01V": ("inbound-rtp", ["kind": "video", "packetsReceived": 9_999]),
      "OT01A": ("outbound-rtp", ["kind": "audio", "packetsSent": 490]),
      "RI01A": ("remote-inbound-rtp", ["kind": "audio", "packetsLost": 2, "fractionLost": 0.01, "roundTripTime": 0.09]),
      "T01": ("transport", ["selectedCandidatePairId": "CP1"]),
      "CP0": ("candidate-pair", ["nominated": true, "state": "succeeded", "currentRoundTripTime": 0.5, "localCandidateId": "L0"]),
      "CP1": ("candidate-pair", ["nominated": true, "state": "succeeded", "currentRoundTripTime": 0.085, "localCandidateId": "L1"]),
      "L0": ("local-candidate", ["candidateType": "host", "protocol": "udp", "networkAdapterType": "wifi"]),
      "L1": ("local-candidate", ["candidateType": "srflx", "protocol": "udp", "networkAdapterType": "cellular5g",
        "address": "203.0.113.7", "ip": "203.0.113.7", "port": 51_000]),
    ]
    let read = VoiceQualitySample(at: 12, statistics: statistics, route: Self.headset)
    #expect(read.packetsReceived == 500 && read.packetsLost == 5 && read.jitter == 0.012)
    #expect(read.concealedSamples == 4_800 && read.silentConcealedSamples == 960 && read.totalSamplesReceived == 480_000)
    #expect(read.concealmentEvents == 3 && read.insertedSamplesForDeceleration == 1_200)
    #expect(read.removedSamplesForAcceleration == 2_400)
    #expect(read.jitterBufferDelay == 28_800.5 && read.jitterBufferEmittedCount == 480_000)
    #expect(read.packetsSent == 490 && read.remotePacketsLost == 2 && read.remoteFractionLost == 0.01)
    #expect(read.remoteRoundTripTime == 0.09)
    // The transport's selected pair, not another nominated one.
    #expect(read.roundTripTime == 0.085)
    #expect(read.path == "srflx/udp/cellular5g")
    #expect(read.route == Self.headset)

    // Without the transport's pick, the nominated pair that succeeded; an older `networkType`; `mediaType` for kind.
    let older = VoiceQualitySample(at: 1, statistics: [
      "IT": ("inbound-rtp", ["mediaType": "audio", "packetsReceived": 7]),
      "CP": ("candidate-pair", ["nominated": true, "state": "succeeded", "currentRoundTripTime": 0.2, "localCandidateId": "L"]),
      "L": ("local-candidate", ["candidateType": "relay", "protocol": "udp", "networkType": "wifi"]),
    ])
    #expect(older.packetsReceived == 7 && older.roundTripTime == 0.2 && older.path == "relay/udp/wifi")

    // A report before media flows: nothing, and not a counter sample.
    let empty = VoiceQualitySample(at: 1, statistics: ["IT": ("inbound-rtp", ["kind": "audio", "jitter": Double.nan])])
    #expect(empty == VoiceQualitySample(at: 1))
    #expect(!empty.counts)
  }

  @Test func sumsWindowsAcrossLinksAndFindsTheWorst() throws {
    var meter = VoiceQualityMeter()
    #expect(meter.summary == nil)
    meter.add(sample(100, received: 0, played: 0, jitter: 0.002, sent: 0, rtt: 0.08, route: Self.headset,
      path: "srflx/udp/cellular"))
    meter.add(sample(105, received: 250, played: 240_000, concealed: 2_400, inserted: 2_400, events: 2, delay: 14_400,
      jitter: 0.012, sent: 250, rtt: 0.08, route: Self.headset))
    // 4% lost, 4% concealed (a third of it silent), 2% compressed, 45 ms of jitter, 2% of his voice lost.
    meter.add(sample(110, received: 490, lost: 10, played: 480_000, concealed: 16_800, silent: 4_800, inserted: 2_400,
      removed: 4_800, events: 6, delay: 38_400, jitter: 0.045, sent: 500, remoteLost: 5, rtt: 0.2))
    // The call was rebuilt: the new link counts from zero.
    meter.restart()
    meter.add(sample(130, received: 20, played: 19_200, delay: 960, jitter: 0.005, sent: 20, rtt: 0.1,
      route: Self.builtIn, path: "host/udp/wifi"))
    meter.add(sample(135, received: 270, played: 259_200, delay: 12_960, jitter: 0.008, sent: 270, rtt: 0.1))

    let quality = try #require(meter.summary)
    #expect(quality.seconds == 15 && quality.windows == 3 && quality.badWindows == 1 && quality.links == 2)
    #expect(quality.lossInPct == 1.33 && quality.lossOutPct == 0.67)
    #expect(quality.concealedPct == 1.67 && quality.concealmentEvents == 6)
    #expect(quality.stretchedPct == 0.33 && quality.compressedPct == 0.67)
    #expect(quality.jitterMs == 21.7 && quality.jitterMaxMs == 45)
    #expect(quality.bufferMs == 70)
    #expect(quality.rttMs == 112 && quality.rttMaxMs == 200)
    #expect(quality.worst == .init(atSeconds: 10, cause: "loss_in", concealedPct: 4, lossInPct: 4, lossOutPct: 2,
      jitterMs: 45))
    #expect(quality.routes == [Self.headset, Self.builtIn] && quality.routeChanges == 1)
    #expect(quality.paths == ["srflx/udp/cellular", "host/udp/wifi"])
  }

  /// Counters that go back mean a new link even when nobody said so; the window across them is not counted.
  @Test func countersThatGoBackStartABaseline() throws {
    var meter = VoiceQualityMeter()
    meter.add(sample(0, received: 0, played: 0, jitter: 0.01, sent: 0, rtt: 0.1))
    meter.add(sample(5, received: 250, played: 240_000, jitter: 0.01, sent: 250, rtt: 0.1))
    meter.add(sample(10, received: 30, played: 28_800, jitter: 0.01, sent: 30, rtt: 0.1))
    meter.add(sample(15, received: 280, lost: 50, played: 268_800, concealed: 24_000, jitter: 0.01, sent: 280, rtt: 0.1))
    let quality = try #require(meter.summary)
    #expect(quality.windows == 2 && quality.links == 2 && quality.seconds == 10)
    #expect(quality.badWindows == 1 && quality.worst?.cause == "loss_in" && quality.worst?.atSeconds == 15)
    #expect(quality.lossInPct == 9.09 && quality.concealedPct == 5)
  }

  /// A report without the inbound audio or the server's RTCP reports leaves those measures out instead of zero.
  @Test func missingFieldsStayMissing() throws {
    var meter = VoiceQualityMeter()
    for at in [0.0, 5] {
      var value = VoiceQualitySample(at: at)
      value.packetsSent = at * 50
      value.remoteFractionLost = at == 0 ? nil : 0.05
      meter.add(value)
    }
    let quality = try #require(meter.summary)
    #expect(quality.windows == 1 && quality.badWindows == 1)
    #expect(quality.lossInPct == nil && quality.concealedPct == nil && quality.concealmentEvents == nil)
    #expect(quality.stretchedPct == nil && quality.jitterMs == nil && quality.bufferMs == nil && quality.rttMs == nil)
    // Without RTCP loss counts, the fraction the server's last report gave.
    #expect(quality.lossOutPct == 5 && quality.worst?.cause == "loss_out")
    #expect(quality.routes.isEmpty && quality.paths.isEmpty)

    // A route without any counters still says what the call used.
    var routed = VoiceQualityMeter()
    routed.add(VoiceQualitySample(at: 0, route: Self.headset))
    routed.add(VoiceQualitySample(at: 1, route: Self.headset))
    routed.add(VoiceQualitySample(at: 2, route: Self.builtIn))
    routed.add(VoiceQualitySample(at: 3, route: Self.headset))
    let audio = try #require(routed.summary)
    #expect(audio.windows == 0 && audio.links == 0 && audio.worst == nil)
    #expect(audio.routes == [Self.builtIn, Self.headset] && audio.routeChanges == 2)
  }

  @Test func routesKeepPortNamesAndAPlausibleRate() {
    let route = VoiceAudioRoute(inputs: ["Bluetooth HFP", ""], outputs: ["A", "B", "C", "D", "E"], sampleRate: .nan)
    #expect(route.inputs == ["BluetoothHFP"] && route.outputs == ["A", "B", "C", "D"] && route.sampleRate == nil)
    #expect(VoiceAudioRoute(inputs: [], outputs: [], sampleRate: 15_999.6).sampleRate == 16_000)
    #expect(VoiceAudioRoute(inputs: [], outputs: [], sampleRate: 1e30).sampleRate == nil)
  }

  /// The fixture the plugin's schema test decodes too (`test/voice.test.ts`): what the app sends is what the server
  /// accepts and logs.
  @Test func reportWithQualityMatchesTheServerContract() throws {
    struct Batch: Codable { let events: [VoiceDiagnostic] }
    let url = try #require(Bundle.module.url(forResource: "voice-diagnostic-quality", withExtension: "json"))
    let data = try Data(contentsOf: url)
    let batch = try JSONDecoder().decode(Batch.self, from: data)
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(batch))
      == JSONDecoder().decode(JSONValue.self, from: data))
    let fixture = try #require(batch.events.first?.quality)
    #expect(fixture.routes.first?.sampleRate == 16_000 && fixture.worst?.cause == "concealed")

    var meter = VoiceQualityMeter()
    meter.add(sample(0, received: 0, played: 0, jitter: 0.01, sent: 0, rtt: 0.1, route: Self.headset, path: "srflx/udp/cellular"))
    meter.add(sample(5, received: 250, lost: 1, played: 240_000, concealed: 9_600, jitter: 0.01, sent: 250, rtt: 0.1))
    let report = VoiceDiagnostic(kind: .ended, reason: .userEnd, build: "b", at: Date(timeIntervalSince1970: 1),
      call: nil, connectedSeconds: 5, phase: "listening", recovering: false, events: VoiceEventTrail(),
      app: .init(state: .background, locked: true), audio: nil, network: nil, quality: meter.summary)
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(report)).object?["quality"]?.object
    let expected = try JSONDecoder().decode(JSONValue.self, from: data).object?["events"]?.array?.first?.object?["quality"]?.object
    let keys = try Set(#require(encoded).keys), contract = try Set(#require(expected).keys)
    #expect(keys.isSubset(of: contract))
    #expect(encoded?["concealedPct"] == .number(4))
    #expect(try JSONDecoder().decode(VoiceDiagnostic.self, from: JSONEncoder().encode(report)) == report)
  }
}
