import MediaPlayer
@testable import OpenCodeKit
import XCTest
@testable import OpenCode

/// The player against a scripted `custom.speech` server: real AVAudioPlayer playback of short WAV pieces.
@MainActor final class ReadAloudPlayerTests: XCTestCase {
  private final class Server: @unchecked Sendable {
    let lock = NSLock()
    var synthesized: [String] = []
    var infos = 0
    var failures: [String] = []
    var seconds = 0.6
    var charactersPerSecond = 12.0
    func respond(_ request: URLRequest) -> (Data, URLResponse) {
      lock.lock(); defer { lock.unlock() }
      let path = request.url?.path ?? ""
      func reply(_ status: Int, _ json: Any) -> (Data, URLResponse) {
        (try! JSONSerialization.data(withJSONObject: json),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
      }
      if path == "/api/rpc/custom.speech/info" {
        infos += 1
        return reply(200, ["output": ["model": "google/gemini-3.8-flash-lite-tts", "voice": "Kore", "maxCharacters": 2000,
          "charactersPerSecond": charactersPerSecond, "usdPerSecond": 0.00015]])
      }
      if path == "/api/rpc/custom.speech/synthesize" {
        if let type = failures.first {
          failures.removeFirst()
          return reply(400, ["_tag": "RpcError", "type": type, "message": "falha"])
        }
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [String: String]]
        synthesized.append(body["input"]!["text"]!)
        return reply(200, ["output": ["audio": Self.wav(seconds: seconds).base64EncodedString(), "mime": "audio/wav", "cached": false]])
      }
      return reply(404, [:])
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return synthesized }
    static func wav(seconds: Double) -> Data {
      let samples = Int(24_000 * seconds)
      var data = Data()
      func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
      data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2))
      data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
      append(UInt32(24_000)); append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16))
      data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2))
      for index in 0..<samples { append(Int16(sin(Double(index) * 2 * .pi * 440 / 24_000) * 800)) }
      return data
    }
  }

  private var defaults: UserDefaults!
  override func setUp() {
    defaults = UserDefaults(suiteName: "ReadAloudPlayerTests")
    defaults.removePersistentDomain(forName: "ReadAloudPlayerTests")
  }

  private func player(_ server: Server, pieces count: Int, characters: Int = 12) -> ReadAloudPlayer {
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:9")!)) { server.respond($0) }
    let pieces = (0..<count).map { ReadAloud.Piece(text: "Trecho \($0) " + String(repeating: "a", count: characters), block: $0) }
    return ReadAloudPlayer(title: "guia.md", pieces: pieces, client: client, defaults: defaults)
  }

  private func wait(_ message: String, timeout: TimeInterval = 10, until condition: () -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !condition() {
      guard Date.now < deadline else { return XCTFail("Timed out: \(message)") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testPlaysPiecesInOrderGeneratingOnlyAhead() async throws {
    let server = Server()
    let reader = player(server, pieces: 6)
    defer { reader.stop() }
    XCTAssertEqual(reader.total, 6.0 * 21 / 12, accuracy: 0.01, "estimate from the default rate before any audio")
    reader.play()
    XCTAssertEqual(reader.phase, .loading)
    try await wait("first piece playing") { reader.phase == .playing }
    try await wait("two pieces generated ahead") { server.texts.count == 3 }
    XCTAssertEqual(server.texts, ["Trecho 0 aaaaaaaaaaaa", "Trecho 1 aaaaaaaaaaaa", "Trecho 2 aaaaaaaaaaaa"])
    try await wait("second piece reached") { reader.position > 0.7 && reader.phase == .playing }
    try await wait("third piece prefetched in turn") { server.texts.count == 4 }
    // Real durations replace the estimate as pieces arrive.
    XCTAssertEqual(try XCTUnwrap(reader.timeline.durations[0]), 0.6, accuracy: 0.05)
    XCTAssertEqual(reader.total, 6 * 0.6, accuracy: 0.2)
    XCTAssertEqual(server.infos, 1)
  }

  func testPauseSeekAndSpeedKeepTheirPlace() async throws {
    let server = Server()
    server.seconds = 2
    let reader = player(server, pieces: 5)
    defer { reader.stop() }
    reader.play()
    try await wait("playing") { reader.phase == .playing && reader.position > 0.3 }
    reader.pause()
    let paused = reader.position
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(reader.phase, .paused)
    XCTAssertEqual(reader.position, paused, accuracy: 0.05)
    // Into piece 3 (its audio not yet generated) while paused: nothing plays until play.
    let target = reader.timeline.start(3) + reader.timeline.duration(3) / 2
    reader.seek(to: target)
    XCTAssertEqual(reader.position, target, accuracy: 0.01)
    XCTAssertEqual(reader.phase, .paused)
    reader.play()
    try await wait("piece 3 playing from its middle") { reader.phase == .playing }
    XCTAssertTrue(server.texts.contains("Trecho 3 aaaaaaaaaaaa"))
    XCTAssertEqual(reader.position, reader.timeline.start(3) + 1, accuracy: 0.3)
    XCTAssertEqual(reader.rate, 1)
    reader.cycleRate()
    XCTAssertEqual(reader.rate, 1.5)
    reader.cycleRate()
    XCTAssertEqual(reader.rate, 2)
    // The last choice is remembered by the next document.
    XCTAssertEqual(player(server, pieces: 1).rate, 2)
    reader.cycleRate()
    XCTAssertEqual(reader.rate, 1)
  }

  func testLongDocumentAsksBeforeGenerating() async throws {
    let server = Server()
    // 12 characters per second: 40 pieces of 1,500 characters are about 83 minutes.
    let reader = player(server, pieces: 40, characters: 1_490)
    defer { reader.stop() }
    reader.play()
    try await wait("cost prompt") { reader.confirmation != nil }
    let confirmation = try XCTUnwrap(reader.confirmation)
    XCTAssertGreaterThan(confirmation.seconds, ReadAloud.confirmationSeconds)
    XCTAssertEqual(confirmation.usd, confirmation.seconds * 0.00015, accuracy: 0.0001)
    XCTAssertEqual(reader.phase, .paused)
    XCTAssertTrue(server.texts.isEmpty, "nothing is generated before the answer")
    reader.confirm()
    try await wait("playing after confirming") { reader.phase == .playing }
    XCTAssertNil(reader.confirmation)
  }

  func testFailureOffersRetry() async throws {
    let server = Server()
    server.failures = ["unavailable"]
    let reader = player(server, pieces: 2)
    defer { reader.stop() }
    reader.play()
    try await wait("failed") { if case .failed = reader.phase { true } else { false } }
    XCTAssertEqual(reader.phase, .failed("Leitura indisponível: o servidor não tem uma chave do Vercel AI Gateway."))
    reader.retry()
    try await wait("recovered") { reader.phase == .playing }
  }

  func testStopReleasesTheLockScreenControls() async throws {
    let server = Server()
    let reader = player(server, pieces: 3)
    reader.play()
    try await wait("playing") { reader.phase == .playing }
    let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "guia.md")
    XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
    reader.stop()
    XCTAssertEqual(reader.phase, .idle)
    XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    let position = reader.position
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(reader.position, position, "nothing keeps playing after stop")
  }
}
