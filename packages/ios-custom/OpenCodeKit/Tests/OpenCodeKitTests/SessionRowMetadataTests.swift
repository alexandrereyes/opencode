import Foundation
import Testing

@testable import OpenCodeKit

@Test(arguments: [
  (-1000.0, "0s", "Agora mesmo"), (0, "0s", "Agora mesmo"),
  (999, "0s", "Agora mesmo"), (1000, "1s", "há 1 segundo"),
  (59_999, "59s", "há 59 segundos"), (60_000, "1m", "há 1 minuto"),
  (119_999, "1m", "há 1 minuto"), (120_000, "2m", "há 2 minutos"),
  (3_599_999, "59m", "há 59 minutos"), (3_600_000, "1h", "há 1 hora"),
  (7_200_000, "2h", "há 2 horas"), (86_399_999, "23h", "há 23 horas"),
  (86_400_000, "1d", "há 1 dia"), (172_800_000, "2d", "há 2 dias"),
  (31_536_000_000, "365d", "há 365 dias"),
]) func rowRelativeTimeMatchesPWASidebar(elapsed: Double, label: String, spoken: String) {
  let now = Date(timeIntervalSince1970: 1_792_584_000)
  let value = SessionList.relativeTime(now.timeIntervalSince1970 * 1000 - elapsed, now: now)
  #expect(value.label == label)
  #expect(value.accessibilityLabel == spoken)
}

@Test func relativeTimeRejectsInvalidDatesAndUsesAnInjectedClock() {
  for invalid in [Double.nan, .infinity, -.infinity, 8_640_000_000_000_001] {
    #expect(SessionList.relativeTime(invalid).label.isEmpty)
  }
  #expect(SessionList.relativeTime(0, now: Date(timeIntervalSince1970: 42)).label == "42s")
  #expect(SessionList.relativeTime(0, now: Date(timeIntervalSince1970: 60)).label == "1m")
}

@Test func rowTimeUsesLastMessageOrCreationNeverMetadataOrOrdering() throws {
  for message in ["", ",\"messageAt\":42000"] {
    let entry = try JSONDecoder().decode(
      NavigationEntry.self,
      from: Data(
        """
        {"session":{"id":"ses_row","projectID":"p","location":{"directory":"/repo"},
        "time":{"created":1000,"updated":999000,"idle":998000,"viewed":997000}}\(message)}
        """.utf8))
    let row = try #require(
      SessionList.rows(
        entries: [entry], projects: [], active: [], pins: [], notify: [], autoApprove: false,
        ranks: ["ses_row": 123456], chatRoot: nil
      ).first)
    #expect(row.interactionAt == (message.isEmpty ? 1000 : 42000))
  }
}

@Test(arguments: [
  ("/Users/server", "/Users/server", "~", "…/Users/server"),
  ("/Users/server/", "/Users/server/", "~", "…/Users/server"),
  ("/Users/server/Worktrees/feat-x", "/Users/server/", "~/Worktrees/feat-x", "…/Worktrees/feat-x"),
  ("/Users/server/Dev/opencode2", "/Users/server", "~/Dev/opencode2", "…/Dev/opencode2"),
  ("/Users/server-two/repo", "/Users/server", "…/server-two/repo", "…/server-two/repo"),
  ("/outside/Users/server/repo", "/Users/server", "…/server/repo", "…/server/repo"),
  (
    "/private/var/folders/tmp/repos/ios-conversation", "/Users/server", "…/repos/ios-conversation",
    "…/repos/ios-conversation"
  ),
  (
    "/private/var/folders/tmp/abacato-v2-worktrees/neon-mountain/", "/Users/server",
    "…/abacato-v2-worktrees/neon-mountain", "…/abacato-v2-worktrees/neon-mountain"
  ),
  ("/repo", "", "…/repo", "…/repo"),
  ("/", "/Users/server", "…", "…"),
  ("", "/Users/server", "…", "…"),
  (
    "/Users/server/árvore/" + String(repeating: "diretório-", count: 40), "/Users/server",
    "~/árvore/" + String(repeating: "diretório-", count: 40),
    "…/árvore/" + String(repeating: "diretório-", count: 40)
  ),
]) func rowPathsKeepHomeAndOnlyTwoOutsideComponentsForTruncation(
  path: String, home: String, expected: String, unresolved: String
) {
  #expect(SessionDirectoryLabel.abbreviate(path, home: home) == expected)
  #expect(SessionDirectoryLabel.abbreviate(path, home: nil) == unresolved)
}

private actor DirectoryProbe {
  var requests: [URLRequest] = []
  var failed = false
  var branch = "main"
  func fail() { failed = true }
  func changeBranch() { branch = "feat/updated" }
  func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    #expect(request.httpMethod == "POST")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == nil)
    let home = request.url!.path.hasSuffix("/home")
    let payload =
      home
      ? "{\"output\":{\"path\":\"/home/server\"}}"
      : """
      {"output":[
      {"directory":"/home/server/repo","worktree":"/home/server/repo","canonical":"/home/server/repo","branch":"\(branch)"},
      {"directory":"/home/server/tree/src","worktree":"/home/server/tree","canonical":"/home/server/repo","branch":"feat/x"},
      {"directory":"/home/server/detached","worktree":"/home/server/detached","canonical":"/home/server/repo","branch":"HEAD"},
      {"directory":"/home/server/root-detached","worktree":"/home/server/root-detached","canonical":"/home/server/root-detached"}]}
      """
    return (
      Data((failed ? "unavailable" : payload).utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: failed ? 503 : 200, httpVersion: nil, headerFields: nil)!
    )
  }
}

@Test func directoryCacheBatchesHundredsOfRowsAndRefreshesOncePerReload() async throws {
  let probe = DirectoryProbe()
  let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) {
    try await probe.respond($0)
  }
  let directories = (0..<500).map { "/home/server/\($0 % 2 == 0 ? "repo" : "tree/src")" }
  let cache = await SessionDirectoryCache().refreshed(directories, using: client)
  let root = try #require(cache.label(directory: "/home/server/repo", chatRoot: nil))
  #expect(root.path == "~/repo" && root.branch == "main")
  #expect(root.accessibilityLabel == "Diretório ~/repo, branch main")
  #expect(cache.label(directory: "/home/server/tree/src", chatRoot: nil)?.branch == "feat/x")
  #expect(cache.label(directory: "/home/server/detached", chatRoot: nil)?.branch == "detached")
  #expect(cache.label(directory: "/home/server/root-detached", chatRoot: nil)?.branch == nil)
  let nonGit = try #require(cache.label(directory: "/home/server/notes", chatRoot: nil))
  #expect(nonGit.path == "~/notes" && nonGit.branch == nil)
  #expect(cache.label(directory: "/chats", chatRoot: "/chats") == nil)
  #expect(cache.label(directory: "/chats/person", chatRoot: "/chats") == nil)
  #expect(cache.label(directory: "/chats-other", chatRoot: "/chats") != nil)
  for directory in directories { _ = cache.label(directory: directory, chatRoot: nil) }
  let first = await probe.requests
  #expect(first.count == 2)
  let locate = try #require(first.first { $0.url!.path.hasSuffix("/locate") })
  let input = try JSONDecoder().decode(JSONValue.self, from: locate.httpBody!)
  #expect(
    input.object?["input"]?.object?["directories"]?.array == [
      .string("/home/server/repo"), .string("/home/server/tree/src"),
    ])
  await probe.changeBranch()
  let refreshed = await cache.refreshed(directories, using: client)
  #expect(refreshed.label(directory: "/home/server/repo", chatRoot: nil)?.branch == "feat/updated")
  #expect(await probe.requests.count == 3)
  await probe.fail()
  let failed = await refreshed.refreshed(directories, using: client)
  #expect(failed.label(directory: "/home/server/repo", chatRoot: nil)?.path == "~/repo")
  #expect(failed.label(directory: "/home/server/repo", chatRoot: nil)?.branch == nil)
  #expect(await probe.requests.count == 4)
}

@Test func absentDirectoryRPCsKeepPathAndAnEmptyListSkipsLocate() async {
  let probe = DirectoryProbe()
  await probe.fail()
  let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) {
    try await probe.respond($0)
  }
  let cache = await SessionDirectoryCache().refreshed([], using: client)
  #expect(await probe.requests.count == 1)
  #expect(cache.label(directory: "/home/server/repo", chatRoot: nil)?.path == "…/server/repo")
  #expect(cache.label(directory: "/home/server/repo", chatRoot: nil)?.branch == nil)
}
