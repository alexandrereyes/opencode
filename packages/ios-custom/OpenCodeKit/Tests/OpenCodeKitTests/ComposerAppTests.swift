import Foundation
import Testing

@testable import OpenCodeKit

private let safari = ComposerApp(
  server: "codex-computer-use", name: "Safari", path: "/Applications/Safari.app/",
  bundleID: "com.apple.Safari", running: true)
private let devTools = ComposerApp(
  server: "safari-devtools", name: "Safari DevTools", bundleID: "mcp.safari-devtools", running: false)
private let notes = ComposerApp(
  server: "codex-computer-use", name: "Notes", bundleID: "com.apple.Notes", running: false)

@Test func appMentionsFilterByNameAfterSessions() throws {
  let trigger = try #require(ComposerTrigger.detect(in: .init(text: "@Saf"), cursor: 4))
  let items = ComposerSources().suggestions(
    trigger, files: [.init(path: "safe.md", type: "file")], apps: [devTools, safari, notes])
  // Files moved to `&`; `@` lists apps without them.
  #expect(items.map(\.title) == ["Safari DevTools", "Safari"])
  #expect(items.filter { $0.token.kind == .app }.map(\.subtitle) == ["Safari MCP", "Computer use"])
  #expect(items.last?.token.text == "@Safari")
  #expect(items.last?.section == "Apps")

  let all = try #require(ComposerTrigger.detect(in: .init(text: "@"), cursor: 1))
  #expect(ComposerSources().suggestions(all, apps: [safari, notes]).map(\.title) == ["Safari", "Notes"])
  // Bundle IDs and the "Computer use" subtitle do not match.
  for query in ["@apple", "@computer", "@codex"] {
    let trigger = try #require(ComposerTrigger.detect(in: .init(text: query), cursor: query.utf16.count))
    #expect(ComposerSources().suggestions(trigger, apps: [safari, notes]).isEmpty)
  }
}

@Test func appMentionUsesTheWebMetadataAndInstruction() throws {
  let token = safari.token
  let text = "Abra \(token.text) e \(devTools.token.text)"
  let first = ("Abra " as NSString).length
  let second = first + (token.text as NSString).length + 3
  let document = ComposerDocument(
    text: text,
    tokens: [
      .init(start: first, end: first + (token.text as NSString).length, token: token),
      .init(start: second, end: second + (devTools.token.text as NSString).length, token: devTools.token),
    ])
  let request = PromptRequest(
    document: document, delivery: .steer, agent: "build",
    model: ModelReference(id: "gpt-6-luna", providerID: "llm-proxy", variant: "low"))
  let apps = try #require(request.metadata["apps"]?.array)
  #expect(apps.count == 2)
  #expect(apps[0].object?["type"] == .string("app"))
  #expect(apps[0].object?["content"] == .string("@Safari"))
  #expect(apps[0].object?["start"] == .number(Double(first)))
  #expect(apps[0].object?["app"]?.object?["bundleID"] == .string("com.apple.Safari"))
  #expect(apps[0].object?["app"]?.object?["path"] == .string("/Applications/Safari.app/"))
  #expect(request.files == nil)
  #expect(
    request.text.contains(
      "Computer use app selected by the user: {\"bundleID\":\"com.apple.Safari\",\"name\":\"Safari\",\"path\":\"/Applications/Safari.app/\",\"running\":true,\"server\":\"codex-computer-use\"}. Use its bundleID as the app argument to codex-computer-use tools."
    ))
  #expect(request.text.contains("Safari DevTools selected by the user"))
  #expect(request.text.contains("do not use codex-computer-use"))

  // Web messages carry no composer tokens; their app metadata still restores the mention.
  let payload = try JSONDecoder().decode(
    InboxItem.Payload.self,
    from: JSONEncoder().encode([
      "text": JSONValue.string(request.text),
      "metadata": .object(["displayText": .string(text), "apps": .array(apps)]),
    ]))
  let restored = ComposerDocument(restoring: payload)
  #expect(restored.validTokens.map(\.token) == [token, devTools.token])
  #expect(ComposerDocument(parts: document.parts, fallback: "").validTokens.map(\.token) == [token, devTools.token])
}

private func begin(_ cache: inout ComposerAppCache, _ scope: ComposerAppScope, open: Bool, now: Date) -> Bool {
  cache.begin(scope, open: open, now: now)
}

@Test func appCacheListsAheadOfMentionAndRelistsWhenTheEnabledSetChanges() {
  let start = Date(timeIntervalSince1970: 1000)
  var cache = ComposerAppCache()
  let connected = ComposerAppScope(server: "s", directory: "/d", enabled: ["codex-computer-use", "blender"])
  #expect(connected.enabled == ["codex-computer-use"])
  #expect(begin(&cache, connected, open: false, now: start))
  #expect(!begin(&cache, connected, open: true, now: start))
  #expect(cache.apps(connected).isEmpty)
  cache.finish(connected, apps: [safari], now: start)
  #expect(cache.apps(connected) == [safari])
  #expect(!begin(&cache, connected, open: true, now: start.addingTimeInterval(59)))
  // A stale listing keeps answering while it is refreshed.
  #expect(begin(&cache, connected, open: true, now: start.addingTimeInterval(61)))
  #expect(cache.apps(connected) == [safari])
  cache.finish(connected, apps: nil, now: start.addingTimeInterval(62))
  #expect(cache.apps(connected) == [safari])
  #expect(!begin(&cache, connected, open: true, now: start.addingTimeInterval(65)))
  #expect(begin(&cache, connected, open: true, now: start.addingTimeInterval(67)))

  let both = ComposerAppScope(server: "s", directory: "/d", enabled: ["safari-devtools", "codex-computer-use"])
  #expect(both.enabled == ["codex-computer-use", "safari-devtools"])
  #expect(cache.apps(both).isEmpty)
  #expect(begin(&cache, both, open: false, now: start))
  cache.finish(connected, apps: [notes], now: start)
  cache.finish(both, apps: [devTools, safari], now: start)
  #expect(cache.apps(both) == [devTools, safari])
  #expect(cache.apps(connected).isEmpty)

  let none = ComposerAppScope(server: "s", directory: "/d", enabled: ["blender"])
  #expect(!begin(&cache, none, open: true, now: start))
  #expect(cache.apps(none).isEmpty)
  let unknown = ComposerAppScope(server: "s", directory: "/other", enabled: nil)
  #expect(!begin(&cache, unknown, open: false, now: start))
  #expect(begin(&cache, unknown, open: true, now: start))
}
