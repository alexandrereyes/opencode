import Foundation
import XCTest

@testable import OpenCode
@testable import OpenCodeKit

private actor PreviewReads {
  private(set) var ids: [String] = []
  private var pending: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func response(_ request: URLRequest) async throws -> (Data, URLResponse) {
    struct Input: Decodable { struct Payload: Decodable { let sessionID: String }; let input: Payload }
    guard request.url?.path.hasSuffix("/custom.transcript/list") == true, let body = request.httpBody
    else { throw URLError(.unsupportedURL) }
    let input = try JSONDecoder().decode(Input.self, from: body)
    ids.append(input.input.sessionID)
    if !released { await withCheckedContinuation { pending.append($0) } }
    return (Data(#"{"output":{"data":[]}}"#.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }

  func release() {
    released = true
    pending.forEach { $0.resume() }
    pending = []
  }
}

@MainActor final class SessionPreviewTests: XCTestCase {
  func testHiddenRowsDoNotStartQueuedReadsOrReplayDirtyReads() async throws {
    let reads = PreviewReads()
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4181/preview-" + UUID().uuidString)!)
    let client = OpenCodeClient(configuration: configuration) { try await reads.response($0) }
    let store = SessionStore(configuration: configuration, client: client)
    let sessions = try (0..<5).map { index in
      try JSONDecoder().decode(Session.self, from: Data("""
        {"id":"session_\(index)","projectID":"global","location":{"directory":"/owned"},"time":{"created":1,"updated":1}}
        """.utf8))
    }
    sessions.forEach(store.show)
    let started = ContinuousClock.now
    while await reads.ids.count < 4, started.duration(to: .now) < .seconds(5) { await Task.yield() }
    let first = await reads.ids
    XCTAssertEqual(Set(first), Set(sessions.prefix(4).map(\.id)), "four concurrent reads, with the fifth queued")
    store.show(sessions[0]) // Marks a running read dirty.
    store.hide(sessions[0])
    store.hide(sessions[4]) // Was queued but never began.
    await reads.release()
    let completed = ContinuousClock.now
    while store.previews.count < 3, completed.duration(to: .now) < .seconds(5) { await Task.yield() }
    XCTAssertEqual(Set(store.previews.keys), Set(sessions[1...3].map(\.id)))
    let final = await reads.ids
    XCTAssertEqual(final.count, 4, "neither the hidden queue entry nor the dirty read starts again")
    await store.stop()
  }
}
