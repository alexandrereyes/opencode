import Foundation
import Testing

@testable import OpenCodeKit

@Suite struct SessionListOrderTests {
  private func rows(_ ids: [String], active: Set<String> = []) throws -> [SessionRow] {
    let entries = try ids.enumerated().map { index, id in
      try JSONDecoder().decode(NavigationEntry.self, from: Data("""
        {"session":{"id":"\(id)","projectID":"project","title":"\(id)",
        "location":{"directory":"/repo"},"time":{"created":\(1000 + index),"updated":\(1000 + index)}}}
        """.utf8))
    }
    return SessionList.rows(entries: entries, projects: [], active: active, pins: [], notify: [],
      autoApprove: false, ranks: [:], chatRoot: nil)
  }

  @Test func orderAndSectionsWaitButRowsAreLive() throws {
    let before = try rows(["first", "second"], active: ["first"])
    let after = try rows(["new", "first", "second"])
    let now = Date(timeIntervalSince1970: 2)
    let initial = SessionListOrder(SessionSections.group(before, now: now))
    let desired = SessionListOrder(SessionSections.group(after, now: now))
    let held = initial.updating(to: desired, idle: false)
    #expect(held == initial)
    let visible = held.resolve(after)
    #expect(visible.first?.kind == .running)
    #expect(visible.first?.rows.first?.state != .running, "the status changed while placement stayed still")
    #expect(!visible.flatMap(\.rows).contains { $0.id == "new" })
    #expect(held.updating(to: desired, idle: true) == desired)
    #expect(desired.resolve(after).flatMap(\.rows).contains { $0.id == "new" })
  }

  @Test func deletionAndSelectionUseOnlyDisplayedSurvivors() throws {
    let now = Date(timeIntervalSince1970: 2)
    let initial = SessionListOrder(SessionSections.group(try rows(["a", "b"], active: ["a"]), now: now))
    let remaining = try rows(["b", "new"])
    let desired = SessionListOrder(SessionSections.group(remaining, now: now))
    let held = initial.updating(to: desired, idle: false)
    #expect(held.visibleIDs(collapsed: SessionSectionCollapse()) == ["b"])
    #expect(held.resolve(remaining).flatMap(\.rows).map(\.id) == ["b"])
    var collapse = SessionSectionCollapse()
    collapse.toggle(.today)
    #expect(held.visibleIDs(collapsed: collapse).isEmpty)
  }

  @Test func searchAndStateFiltersComposeWithoutChangingTheHostOrder() throws {
    let rows = try rows(["alpha", "alpine", "beta"], active: ["alpha"])
    let filtered = SessionListFilter(state: .running, query: "AL").rows(rows, label: { _ in nil })
    #expect(filtered.map(\.id) == ["alpha"])
    #expect(SessionListFilter(query: "  al  ").rows(rows, label: { _ in nil }).map(\.id)
      == rows.filter { $0.id.hasPrefix("al") }.map(\.id))
    #expect(SessionListFilter(project: SessionListFilter.chats).rows(rows, label: { _ in nil }).isEmpty)
  }

  @Test func leavingAStateFilterWaitsForIdleUnlikeDeletion() throws {
    let before = try rows(["a"], active: ["a"])
    let after = try rows(["a"])
    let initial = SessionListOrder(SessionSections.group(before, now: .now))
    let desired = SessionListOrder([])
    let held = initial.updating(to: desired, idle: false, available: ["a"])
    #expect(held == initial)
    #expect(held.resolve(after).first?.rows.first?.state != .running)
    #expect(held.updating(to: desired, idle: true, available: ["a"]).sections.isEmpty)
    #expect(held.updating(to: desired, idle: false, available: []).sections.isEmpty)
  }

  @Test func allAndChatsUseTheSameGroupingWithoutAMuteFilter() throws {
    var list = try rows(["chat", "repository"])
    let index = try #require(list.firstIndex { $0.id == "chat" })
    list[index].chat = true
    let all = SessionListFilter().rows(list, label: { _ in nil })
    #expect(all.count == 2)
    #expect(SessionSections.group(all, now: .now).flatMap(\.rows).map(\.id) == all.map(\.id))
    let chats = SessionListFilter(project: SessionListFilter.chats).rows(list, label: { _ in nil })
    #expect(chats.map(\.id) == ["chat"])
    #expect(!SessionFilter.allCases.map(\.rawValue).contains("Silenciadas"))
  }
}
