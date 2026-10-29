import Foundation
import Testing
@testable import OpenCodeKit

@Test func railReusesChipOrderAndCombinesIndicators() throws {
  let projects = try JSONDecoder().decode([Project].self, from: Data(#"[{"id":"a","canonical":"/a","sandboxes":[]},{"id":"b","canonical":"/b","sandboxes":[]},{"id":"c","canonical":"/c","sandboxes":[]}]"#.utf8))
  let entries = try JSONDecoder().decode([NavigationEntry].self, from: Data(#"""
  [
    {"session":{"id":"root","projectID":"a","location":{"directory":"/a"},"time":{"created":1,"updated":2,"idle":2,"viewed":0}},"questionAt":3},
    {"session":{"id":"child","parentID":"root","projectID":"a","location":{"directory":"/a"},"time":{"created":1,"updated":2}}},
    {"session":{"id":"unread","projectID":"a","location":{"directory":"/a"},"time":{"created":1,"updated":2,"idle":2,"viewed":0},"outcome":"succeeded"}},
    {"session":{"id":"quiet","projectID":"b","location":{"directory":"/b"},"time":{"created":1,"updated":1}}},
    {"session":{"id":"chat","projectID":"c","location":{"directory":"/chats/day/a"},"time":{"created":1,"updated":1}}}
  ]
  """#.utf8))
  let rows = SessionList.rows(entries: entries, projects: projects, active: ["child"], pins: [], notify: [], autoApprove: false, ranks: [:], chatRoot: "/chats")
  let chips = [ChipEntry(key: "b", name: "B", position: 0), ChipEntry(key: "a", name: "A", position: 1),
    ChipEntry(key: "c", name: "C", position: 2), ChipEntry(key: ChipManualOrder.chats, name: "Chats", position: 3)]
  let items = ProjectRail.items(rows: rows, chips: chips, active: ["child"])
  #expect(items.map(\.id) == [ChipManualOrder.chats] + SessionList.chipGroups(rows, chips: chips, chats: ChipManualOrder.chats).filter { $0.key != ChipManualOrder.chats }.map(\.key))
  let busy = try #require(items.first { $0.id == "a" })
  #expect(busy.count == 2)
  #expect(busy.group.running && busy.group.requests == 1 && busy.group.unread)
  #expect(items.first?.count == 1)
  #expect(items.first { $0.id == "c" }?.count == 0)
}

@Test func railDropUsesSavedRepositoryPositionNotVisualActivityPosition() throws {
  let manual = ChipManualOrder(projects: [("b", "/b"), ("a", "/a"), ("c", "/c")], chatsIndex: 1, showsChats: true)
  let intent = try #require(ProjectRail.drop("c", onto: "b", manual: manual))
  let data = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(intent))
  #expect(data.object?["directory"]?.string == "/c")
  #expect(data.object?["toIndex"]?.number == 0)
  #expect(ProjectRail.drop("b", onto: "b", manual: manual) == nil)
  #expect(ProjectRail.drop(ChipManualOrder.chats, onto: "b", manual: manual) == nil)
}
