import XCTest

@testable import OpenCode
@testable import OpenCodeKit

@MainActor final class TranscriptActivityTests: XCTestCase {
  func testSharedActivityDisclosuresInvalidateOnlyTheirOwnHeight() throws {
    let messages = try JSONDecoder().decode([ConversationMessage].self, from: Data(#"""
      [{"id":"a","type":"assistant","time":{"created":1,"completed":2},"content":[
        {"id":"read","type":"tool","name":"read","state":{"status":"completed","input":{"path":"/long/path/file.swift"}}},
        {"id":"edit","type":"tool","name":"edit","state":{"status":"completed","input":{"path":"/long/path/file.swift"},"metadata":{"files":[{"file":"/long/path/file.swift","patch":"+added","status":"modified","additions":1,"deletions":0}]}}}
      ]}]
      """#.utf8))
    let activity = ConversationActivity.project(messages)
    let row = try XCTUnwrap(activity.messages.flatMap(\.rows).first { $0.kind == .group })
    let read = try XCTUnwrap(row.items.first { $0.kind == .read })
    let edit = try XCTUnwrap(row.items.first { $0.kind == .files })
    let file = try XCTUnwrap(edit.files.first)
    var input = TranscriptProjection.Input(messages: activity.messages, marks: .init(messages, working: false),
      dividers: [], pending: [], permissions: [], questions: [], hasOlder: false, paging: false,
      expansion: [row.id: true], bubbles: { _ in false }, blocks: { _ in nil })
    let closed = try XCTUnwrap(TranscriptProjection.items(input).first { $0.id == "row:" + row.id })
    input.expansion["activity:read:" + read.id] = true
    let filenames = try XCTUnwrap(TranscriptProjection.items(input).first { $0.id == closed.id })
    XCTAssertNotEqual(closed, filenames)
    input.expansion["activity:file:\(edit.id):\(file.path)"] = true
    let diff = try XCTUnwrap(TranscriptProjection.items(input).first { $0.id == closed.id })
    XCTAssertNotEqual(filenames, diff)
    input.expansion["activity:file:another:/unrelated"] = true
    XCTAssertEqual(TranscriptProjection.items(input).first { $0.id == closed.id }, diff)
  }
}
