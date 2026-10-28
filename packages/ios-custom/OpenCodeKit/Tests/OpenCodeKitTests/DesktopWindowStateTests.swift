import Foundation
import Testing
@testable import OpenCodeKit

@Suite struct DesktopWindowStateTests {
  @Test func restorationIsIndependentForEachWindowAndServer() throws {
    let suite = "DesktopWindowStateTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = UUID(), second = UUID()
    let server = URL(string: "http://localhost:4205")!
    let otherServer = URL(string: "http://other.invalid")!
    var a = DesktopWindowState()
    a.selection = .init(sessionID: "parent", childID: "child", files: .init(folder: "/src", file: "main.swift"))
    a.contextWidth = 620
    a.sidebarVisible = false
    a.save(window: first, server: server, defaults: defaults)
    var b = DesktopWindowState()
    b.selection = .init(sessionID: "different")
    b.contextVisible = false
    b.save(window: second, server: server, defaults: defaults)
    #expect(DesktopWindowState.load(window: first, server: server, defaults: defaults) == a)
    #expect(DesktopWindowState.load(window: second, server: server, defaults: defaults) == b)
    #expect(DesktopWindowState.load(window: first, server: otherServer, defaults: defaults) == DesktopWindowState())
  }

  @Test func quoteNumbersNeverBecomeAuthoredText() {
    let text = "A 👩🏽‍💻 escreve café e Swift."
    let length = text.utf16.count
    let split = (text as NSString).range(of: "café").location
    let map = QuoteTextMap([.init(id: "last", number: 12, offset: length),
      .init(id: "first", number: 1, offset: split), .init(id: "overlap", number: 2, offset: split)])
    #expect(map.insertions.map(\.marker.id) == ["first", "overlap", "last"])
    #expect(map.original(NSRange(location: 0, length: length + 4)) == NSRange(location: 0, length: length))
    for insertion in map.insertions {
      #expect(map.original(insertion.range).length == 0)
    }
    let cafe = (text as NSString).range(of: "café")
    #expect(map.original(map.display(cafe)) == cafe)
    #expect(map.display(cafe).location == cafe.location + 2)
  }
}
