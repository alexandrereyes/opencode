import Foundation
import Testing
@testable import OpenCodeKit

@Test func subagentTreeOnlyShowsOpenPathAndDisappearsOnReturn() throws {
  let sessions = try JSONDecoder().decode([Session].self, from: Data(#"""
  [
    {"id":"root","projectID":"p","location":{"directory":"/p"},"time":{"created":1,"updated":1}},
    {"id":"child","parentID":"root","projectID":"p","location":{"directory":"/p"},"time":{"created":1,"updated":1}},
    {"id":"sibling","parentID":"root","projectID":"p","location":{"directory":"/p"},"time":{"created":1,"updated":1}},
    {"id":"nested","parentID":"child","projectID":"p","location":{"directory":"/p"},"time":{"created":1,"updated":1}}
  ]
  """#.utf8))
  #expect(SubagentNavigation.path(root: "root", child: "nested", sessions: sessions).map(\.id) == ["child", "nested"])
  #expect(SubagentNavigation.path(root: "root", child: "child", sessions: sessions).map(\.id) == ["child"])
  #expect(SubagentNavigation.path(root: "root", child: nil, sessions: sessions).isEmpty)
  #expect(SubagentNavigation.path(root: "root", child: "root", sessions: sessions).isEmpty)
}
