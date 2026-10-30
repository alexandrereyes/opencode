import Foundation
import Testing

@testable import OpenCodeKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func session(
  _ id: String, parent: String?, cost: Double? = nil, created: Double = 1_000, idle: Double? = nil,
  outcome: String? = nil, context: String? = nil, tokens: String? = nil
) -> String {
  var fields = [
    #""id":"\#(id)""#, #""projectID":"p""#, #""location":{"directory":"/repo"}"#,
    #""time":{"created":\#(created),"updated":\#(idle ?? created)\#(idle.map { #","idle":\#($0)"# } ?? "")}"#,
  ]
  if let parent { fields.append(#""parentID":"\#(parent)""#) }
  if let cost { fields.append(#""cost":\#(cost)"#) }
  if let outcome { fields.append(#""outcome":"\#(outcome)""#) }
  if let context { fields.append(#""context":\#(context)"#) }
  if let tokens { fields.append(#""tokens":\#(tokens)"#) }
  return "{" + fields.joined(separator: ",") + "}"
}

private let family = """
  [\(session("root", parent: nil, cost: 14.36)),
   \(session("a", parent: "root", cost: 5, created: 5_000,
     context: #"{"id":"m1","tokens":{"input":1000,"output":500,"reasoning":0,"cache":{"read":98500,"write":0}},"model":{"id":"big","providerID":"p"}}"#,
     tokens: #"{"input":600,"output":0,"reasoning":0,"cache":{"read":5400,"write":0}}"#)),
   \(session("a1", parent: "a", cost: 2.27, created: 6_000)),
   \(session("b", parent: "root", cost: 4.6, created: 4_000)),
   \(session("c", parent: "root", cost: 0.24, created: 1_000, idle: 9_000, outcome: "succeeded")),
   \(session("d", parent: "root", cost: 1, created: 2_000, idle: 8_000, outcome: "succeeded")),
   \(session("e", parent: "root", cost: 1, created: 3_000, idle: 7_000, outcome: "failed")),
   \(session("f", parent: "root", cost: 1, created: 3_500, idle: 6_000, outcome: "succeeded"))]
  """

@Test func contextColumnCostsSplitTheSessionFromItsSubagents() throws {
  let members = try decode([Session].self, family)
  let root = members[0]
  let costs = ContextColumn.costs(session: root, family: nil, members: members)
  #expect(costs.session == 14.36)
  #expect(abs((costs.subagents ?? 0) - 15.11) < 0.0001)
  #expect(abs((costs.total ?? 0) - 29.47) < 0.0001)
  let snapshot = try decode(FamilySnapshot.self, #"{"count":7,"cost":63.89,"active":[],"forms":[],"permissions":[]}"#)
  #expect(ContextColumn.costs(session: root, family: snapshot, members: members).subagents == 63.89)
  // A subagent's cost includes the subagents it started.
  #expect(abs((ContextColumn.cost(of: "a", members: members) ?? 0) - 7.27) < 0.0001)
  #expect(ContextColumn.cost(of: "b", members: members) == 4.6)
  #expect(ContextColumn.costs(session: nil, family: nil, members: []).total == nil)
}

@Test func contextColumnFindsTheDirectSubagentOfADescendant() throws {
  let members = try decode([Session].self, family)
  #expect(ContextColumn.branch(of: "a1", rootID: "root", members: members) == "a")
  #expect(ContextColumn.branch(of: "a", rootID: "root", members: members) == "a")
  #expect(ContextColumn.branch(of: "root", rootID: "root", members: members) == nil)
  #expect(ContextColumn.branch(of: "unknown", rootID: "root", members: members) == nil)
}

@Test func contextColumnOrdersLiveSubagentsFirstAndCollapsesFinishedOnes() throws {
  let members = try decode([Session].self, family)
  let models = try decode([ModelInfo].self, #"[{"id":"big","providerID":"p","name":"Big","limit":{"context":1000000}}]"#)
  let permissions = try decode([PermissionRequest].self, #"[{"id":"per","sessionID":"a1","action":"shell","resources":["git push"]}]"#)
  let resources = try decode([SessionResource].self, #"""
    [{"id":"sim","kind":"ios-simulator","label":"iPhone","owner":{"sessionID":"b","rootSessionID":"root"},"state":"agent",
      "meta":{"kind":"ios-simulator","device":"iPhone 17 Pro"},"discoveredAt":0,"lastUsedAt":5,"updatedAt":5,"live":{"stream":true,"input":true}},
     {"id":"old","kind":"chrome","label":"Chrome","owner":{"sessionID":"b","rootSessionID":"root"},"state":"stopped",
      "meta":{"kind":"chrome","url":"http://localhost:4177/"},"discoveredAt":0,"lastUsedAt":4,"updatedAt":4,"live":{"stream":false,"input":false}}]
    """#)
  let work = ConversationProjection.work(
    ownerID: "root", viewedID: "root", messages: [], children: members, active: ["a", "b"], shells: [])
  let subagents = ContextColumn.subagents(
    work: work, rootID: "root", members: members, models: models, permissions: permissions, forms: [],
    resources: resources)
  // Live first (by latest start), then finished by last run; with two live rows, three finished stay visible.
  #expect(subagents.shown.map(\.id) == ["a", "b", "c", "d", "e"])
  #expect(subagents.hidden.map(\.id) == ["f"])
  #expect(subagents.total == 6)
  #expect(subagents.active == 2)
  let a = subagents.shown[0]
  // A grandchild's permission is asked on its subagent's row.
  #expect(a.status == .permission)
  #expect(a.permission?.id == "per")
  #expect(a.usage?.fraction == 0.1)
  #expect(a.cacheHit == 0.9)
  #expect(abs((a.cost ?? 0) - 7.27) < 0.0001)
  let b = subagents.shown[1]
  #expect(b.status == .running)
  #expect(b.usage == nil)
  #expect(b.resources.map(\.id) == ["sim"])
  #expect(subagents.shown[4].status == .failed)
  #expect(!ContextColumn.Status.completed.live)
}

@Test func contextColumnShowsAtLeastOneFinishedRowWhenFewAreLive() throws {
  let members = try decode([Session].self, family)
  let work = ConversationProjection.work(
    ownerID: "root", viewedID: "root", messages: [], children: members, active: ["a", "b", "c", "d"], shells: [])
  let subagents = ContextColumn.subagents(
    work: work, rootID: "root", members: members, models: [], permissions: [], forms: [], resources: [])
  #expect(subagents.shown.count == 5)
  #expect(subagents.active == 4)
  #expect(subagents.hidden.count == 1)
}

@Test func contextColumnSplitsResourcesInUseFromFreeAndStoppedOnes() throws {
  let resources = try decode([SessionResource].self, #"""
    [{"id":"stopped","kind":"chrome","label":"GitHub","owner":{"sessionID":"root","rootSessionID":"root"},"state":"stopped",
      "meta":{"kind":"chrome","url":"https://github.com/"},"discoveredAt":0,"lastUsedAt":9,"updatedAt":9,"live":{"stream":false,"input":false}},
     {"id":"free","kind":"android-emulator","label":"Pixel","state":"idle",
      "meta":{"kind":"android-emulator","avd":"Pixel_9"},"discoveredAt":0,"lastUsedAt":1,"updatedAt":1,"live":{"stream":true,"input":true}},
     {"id":"phone","kind":"ios-simulator","label":"iPhone","owner":{"sessionID":"a1","rootSessionID":"root"},"state":"agent",
      "meta":{"kind":"ios-simulator","device":"iPhone 17 Pro"},"discoveredAt":0,"lastUsedAt":3,"updatedAt":3,"live":{"stream":true,"input":true}},
     {"id":"web","kind":"chrome","label":"Web","owner":{"sessionID":"b","rootSessionID":"root"},"state":"user",
      "meta":{"kind":"chrome","url":"http://localhost:4177/sessions"},"discoveredAt":0,"lastUsedAt":8,"updatedAt":8,"live":{"stream":true,"input":true}},
     {"id":"pad","kind":"ios-simulator","label":"iPad Air","state":"idle",
      "meta":{"kind":"ios-simulator","name":"iPad Air"},"discoveredAt":0,"lastUsedAt":2,"updatedAt":2,"live":{"stream":true,"input":true}}]
    """#)
  let split = ContextColumn.resources(resources)
  #expect(split.inUse.map(\.id) == ["web", "phone"])
  #expect(split.others.map(\.id) == ["pad", "free", "stopped"])
  let members = try decode([Session].self, family)
  #expect(ContextColumn.user(of: resources[2], rootID: "root", members: members) == "a")
  #expect(ContextColumn.user(of: resources[3], rootID: "root", members: members) == "b")
  #expect(ContextColumn.user(of: resources[0], rootID: "root", members: members) == nil)
  #expect(ContextColumn.title(resources[2]) == "Simulador iOS · iPhone 17 Pro")
  #expect(ContextColumn.chip(resources[2]) == "iPhone 17 Pro")
  #expect(ContextColumn.chip(resources[3]) == "Chrome · localhost:4177")
  #expect(ContextColumn.title(resources[0]) == "Chrome · github.com")
  #expect(ContextColumn.title(resources[1]) == "Emulador Android · Pixel 9")
  #expect(ContextColumn.title(resources[4]) == "Simulador iOS · iPad Air")
}

@Test func contextColumnReadsTheDevServerPort() {
  #expect(ContextColumn.port("bun run dev --port 4177") == 4177)
  #expect(ContextColumn.port("vite --port=5173") == 5173)
  #expect(ContextColumn.port("PORT=3000 bun run start") == 3000)
  #expect(ContextColumn.port("python3 -m http.server -p 8080") == 8080)
  #expect(ContextColumn.port("npx serve http://localhost:4321") == 4321)
  #expect(ContextColumn.port("xcodebuild test") == nil)
  #expect(ContextColumn.port("sleep 301") == nil)
  #expect(ContextColumn.task("bun run dev --port 4177") == ("bun run dev", 4177))
  #expect(ContextColumn.task("PORT=3000 bun run start") == ("bun run start", 3000))
  #expect(ContextColumn.task("npx serve http://localhost:4321") == ("npx serve http://localhost:4321", 4321))
  #expect(ContextColumn.task("xcodebuild test") == ("xcodebuild test", nil))
}

@Test func contextColumnSaysHowOldTheLastFrameIs() {
  let now = Date(timeIntervalSince1970: 10_000)
  #expect(ContextColumn.ago(10_000_000 - 30_000, now: now) == "agora")
  #expect(ContextColumn.ago(10_000_000 - 3 * 60_000, now: now) == "há 3 min")
  #expect(ContextColumn.ago(10_000_000 - 125 * 60_000, now: now) == "há 2 h")
  #expect(ContextColumn.ago(10_000_000 - 3 * 1_440 * 60_000, now: now) == "há 3 d")
}

@Test func contextColumnFormatsPercentWithOneDecimal() {
  #expect(ContextColumn.percent(0.995) == "99,5%")
  #expect(ContextColumn.percent(0.0874) == "8,7%")
  #expect(ContextColumn.percent(1) == "100,0%")
}

/// 711,3k tokens, 99% of the reads from cache.
private func usage(limit: Double?) throws -> ContextUsage? {
  let tokens = try decode(TokenUsage.self, #"{"input":7100,"output":1000,"reasoning":0,"cache":{"read":703200,"write":0}}"#)
  return ContextUsage(tokens: tokens, limit: limit)
}

@Test func contextColumnMetricsLineKeepsContextCacheCostTimeAndProgressInOrder() throws {
  let metrics = ContextColumn.metrics(
    usage: try usage(limit: 1_000_000), cacheHit: 0.99, cost: 26.95, elapsed: "20m",
    progress: .init(done: 2, total: 4))
  #expect(metrics.map(\.kind) == [.context, .tokens, .cache, .cost, .elapsed, .progress])
  // Context without a decimal, cache with one.
  #expect(metrics.map(\.text) == ["71%", "711,3k / 1M", "99,0%", ContextUsage.money(26.95), "20m", "2/4"])
  #expect(metrics.allSatisfy { !$0.warning })
}

@Test func contextColumnMetricsLineDropsTheTokensWhenNarrow() throws {
  let metrics = ContextColumn.metrics(usage: try usage(limit: 1_000_000), cacheHit: 0.99, cost: 2_759.4, narrow: true)
  #expect(metrics.map(\.text) == ["71%", "99,0%", "US$ 2,8 mil"])
  #expect(ContextColumn.metrics(usage: try usage(limit: 1_000_000), cacheHit: nil, cost: 2_759.4).map(\.text)
    == ["71%", "711,3k / 1M", ContextUsage.money(2_759.4)])
}

@Test func contextColumnMetricsLineShowsOnlyTokensForAModelOutsideTheCatalog() throws {
  for narrow in [false, true] {
    let metrics = ContextColumn.metrics(usage: try usage(limit: nil), cacheHit: 0.606, cost: nil, narrow: narrow)
    #expect(metrics.map(\.kind) == [.tokens, .cache])
    #expect(metrics.map(\.text) == ["711,3k tokens", "60,6%"])
    // A cache hit below 80% is a warning.
    #expect(metrics.map(\.warning) == [false, true])
  }
  #expect(ContextColumn.metrics(usage: try usage(limit: 800_000), cacheHit: nil, cost: nil).first?.warning == true)
}

@Test func contextColumnMetricsLineLeavesOutWhatIsMissing() throws {
  // Before the first measured step, without a cost or a Progresso: nothing to show.
  #expect(ContextColumn.metrics(usage: nil, cacheHit: nil, cost: nil).isEmpty)
  #expect(ContextColumn.metrics(usage: nil, cacheHit: nil, cost: 1, elapsed: "2m", progress: nil).map(\.text)
    == [ContextUsage.money(1), "2m"])
  // An empty list is no Progresso.
  #expect(ContextColumn.metrics(usage: nil, cacheHit: nil, cost: nil, progress: .init(done: 0, total: 0)).isEmpty)
}

@Test func contextColumnPassesAChildsProgressToItsRow() throws {
  let members = try decode([Session].self, family)
  let work = ConversationProjection.work(
    ownerID: "root", viewedID: "root", messages: [], children: members, active: ["a", "b"], shells: [])
  let subagents = ContextColumn.subagents(
    work: work, rootID: "root", members: members, models: [], permissions: [], forms: [], resources: [],
    progress: ["a": .init(done: 2, total: 4), "c": .init(done: 1, total: 3)])
  #expect(subagents.shown.first { $0.id == "a" }?.progress?.label == "2/4")
  // Without data the row has none, and the line keeps no room for it.
  #expect(subagents.shown.first { $0.id == "b" }?.progress == nil)
  // Like Sessões, only while the child works.
  #expect(subagents.shown.first { $0.id == "c" }?.status == .completed)
  #expect(subagents.shown.first { $0.id == "c" }?.progress == nil)
}

/// A subagent opened in the middle column has its own family: the column then lists its subagents (the root's
/// grandchildren) and splits its own cost from theirs.
@Test func contextColumnFollowsAnOpenedSubagent() throws {
  let members = try decode([Session].self, family)
  let child = try #require(members.first { $0.id == "a" })
  let grandchildren = members.filter { $0.parentID == "a" }
  let work = ConversationProjection.work(
    ownerID: "a", viewedID: "a", messages: [], children: grandchildren, active: ["a1"], shells: [])
  let subagents = ContextColumn.subagents(
    work: work, rootID: "a", members: grandchildren, models: [], permissions: [], forms: [], resources: [])
  #expect(subagents.shown.map(\.id) == ["a1"])
  #expect(subagents.active == 1)
  let costs = ContextColumn.costs(session: child, family: nil, members: grandchildren)
  #expect(costs.session == 5)
  #expect(costs.subagents == 2.27)
}

@Test func contextColumnFiltersOnlyChangedFilesAndTheirFolders() throws {
  let changes = try decode([WorkingChange].self, #"""
    [{"file":"packages/ios-custom/OpenCode/SessionColumn/SessionRowView.swift","additions":81,"deletions":0,"status":"modified"},
     {"file":"packages/ios-custom/OpenCode/SessionColumn/SessionColumnHeader.swift","additions":12,"deletions":3,"status":"modified"},
     {"file":"README.md","additions":5,"deletions":0,"status":"added"}]
    """#)
  #expect(ContextColumn.summary(changes) == .init(additions: 98, deletions: 3, files: 3))
  let statuses = ContextColumn.statuses(changes, root: "/repo")
  #expect(statuses["/repo/README.md"] == .init(change: .added, additions: 5, deletions: 0))
  #expect(ContextColumn.changedFolders(statuses).isSuperset(of: [
    "/repo", "/repo/packages", "/repo/packages/ios-custom/OpenCode/SessionColumn",
  ]))
  let entries = [
    DirectoryEntry(name: "SessionRowView.swift", absolute: "/repo/packages/ios-custom/OpenCode/SessionColumn/SessionRowView.swift", kind: .file),
    DirectoryEntry(name: "SessionChips.swift", absolute: "/repo/packages/ios-custom/OpenCode/SessionColumn/SessionChips.swift", kind: .file),
    DirectoryEntry(name: "Components", absolute: "/repo/packages/ios-custom/OpenCode/SessionColumn/Components", kind: .directory),
    DirectoryEntry(name: "SessionColumnHeader.swift", absolute: "/repo/packages/ios-custom/OpenCode/SessionColumn/SessionColumnHeader.swift", kind: .file),
  ]
  #expect(ContextColumn.entries(entries, statuses: statuses, onlyChanged: false).map(\.name) == [
    "Components", "SessionChips.swift", "SessionColumnHeader.swift", "SessionRowView.swift",
  ])
  #expect(ContextColumn.entries(entries, statuses: statuses, onlyChanged: true).map(\.name) == [
    "SessionColumnHeader.swift", "SessionRowView.swift",
  ])
  #expect(ContextColumn.entries(entries, statuses: statuses, onlyChanged: false, order: .descending).map(\.name) == [
    "Components", "SessionRowView.swift", "SessionColumnHeader.swift", "SessionChips.swift",
  ])
  let root = [DirectoryEntry(name: "packages", absolute: "/repo/packages", kind: .directory),
    DirectoryEntry(name: "docs", absolute: "/repo/docs", kind: .directory)]
  #expect(ContextColumn.entries(root, statuses: statuses, onlyChanged: true).map(\.name) == ["packages"])
}

@Test func contextColumnBuildsTheBreadcrumbFromTheCheckout() {
  #expect(ContextColumn.breadcrumb("/Users/me/Worktrees/app/packages/ios-custom", root: "/Users/me/Worktrees/app") == [
    .init(name: "app", path: "/Users/me/Worktrees/app"),
    .init(name: "packages", path: "/Users/me/Worktrees/app/packages"),
    .init(name: "ios-custom", path: "/Users/me/Worktrees/app/packages/ios-custom"),
  ])
  #expect(ContextColumn.breadcrumb("/Users/me/Worktrees/app/", root: "/Users/me/Worktrees/app") == [
    .init(name: "app", path: "/Users/me/Worktrees/app"),
  ])
  #expect(ContextColumn.breadcrumb("/tmp/x", root: "/Users/me/Worktrees/app") == [
    .init(name: "/", path: "/"), .init(name: "tmp", path: "/tmp"), .init(name: "x", path: "/tmp/x"),
  ])
}

@Test func contextColumnPlansTheFileMergeComparisonAgainstHead() {
  let status = ContextColumn.FileStatus(change: .modified, additions: 1, deletions: 1)
  let plan = ContextColumn.fileMerge("/repo/My App/Sources/View.swift", root: "/repo", status: status)
  #expect(plan == .init(repository: "/repo", relative: "My App/Sources/View.swift", added: false))
  #expect(plan?.gitArguments == ["-C", "/repo", "show", "HEAD:My App/Sources/View.swift"])
  #expect(plan?.baseName == "View (HEAD).swift")
  #expect(ContextColumn.fileMerge("/repo/Makefile", root: "/repo/", status: nil)?.baseName == "Makefile (HEAD)")
  #expect(ContextColumn.fileMerge("/repo/new.md", root: "/repo", status: .init(change: .added, additions: 3, deletions: 0))?.added == true)
  #expect(ContextColumn.fileMerge("/elsewhere/file.swift", root: "/repo", status: status) == nil)
  #expect(ContextColumn.fileMerge("/repository/file.swift", root: "/repo", status: status) == nil)
}

@Test func contextColumnFencesASourceFileForTheHighlighter() throws {
  let source = try #require(ContextColumn.highlightSource("let a = \"```\"\nprint(a)", path: "/repo/View.swift"))
  #expect(source == "````swift\nlet a = \"```\"\nprint(a)\n````\n")
  let blocks = MarkdownBlocks.parse(source)
  #expect(blocks.count == 1)
  #expect(blocks.first?.kind == .code("swift"))
  #expect(blocks.first?.text.hasPrefix("let a = \"```\"\nprint(a)") == true)
  #expect(ContextColumn.highlightSource("plain", path: "/repo/notes") == nil)
  #expect(ContextColumn.highlightSource("x", path: "/repo/Makefile") == nil)
  #expect(MarkdownSyntax.keyword.role == .syntaxKeyword)
}

@Test func contextCheckoutNamesTheWorktreeFolderAndItsBranch() throws {
  let worktree = "/Users/a/Worktrees/abacato-v2-feat-qa-usuario-isolado"
  let vcs = { (current: String?) in
    try decode(VCSInfo.self, #"{"provider":"git","branch":{"#
      + (current.map { #""current":"\#($0)","# } ?? "") + #""default":"main"}}"#)
  }
  let located = { (directory: String, worktree: String, canonical: String, branch: String?) in
    try decode(LocatedDirectory.self, #"{"directory":"\#(directory)","worktree":"\#(worktree)","canonical":"\#(canonical)""#
      + (branch.map { #","branch":"\#($0)""# } ?? "") + "}")
  }

  // A linked worktree whose locate lost its branch (an unreadable worktree list): the core's VCS names it.
  let linked = ContextColumn.checkout(
    directory: worktree, located: try located(worktree, worktree, worktree, nil), vcs: try vcs("feat/qa-usuario-isolado"))
  #expect(linked == .init(name: "abacato-v2-feat-qa-usuario-isolado", help: worktree,
    branch: "feat/qa-usuario-isolado", branchHelp: "Branch feat/qa-usuario-isolado"))
  #expect(linked.branchText == "feat/qa-usuario-isolado")

  // The main checkout shows the repository's own folder; a session below the root names it in the tooltip.
  let main = ContextColumn.checkout(
    directory: "/Users/a/Dev/opencode2/packages/core",
    located: try located("/Users/a/Dev/opencode2/packages/core", "/Users/a/Dev/opencode2", "/Users/a/Dev/opencode2", "custom"),
    vcs: nil)
  #expect(main.name == "opencode2")
  #expect(main.help == "/Users/a/Dev/opencode2\nPasta da sessão: packages/core")
  #expect(main.branch == "custom")

  // A detached HEAD: "—", and the tooltip says why (no SHA: neither read carries the commit).
  let detached = ContextColumn.checkout(
    directory: worktree, located: try located(worktree, worktree, "/Users/a/Dev/abacato-v2", nil), vcs: try vcs(nil))
  #expect(detached.branch == nil && detached.branchText == "—")
  #expect(detached.branchHelp == "Sem branch: HEAD solto (detached)")
  #expect(detached.name == "abacato-v2-feat-qa-usuario-isolado")
  // The core's VCS wins over an older locate that still had a branch; before it names a provider, locate counts.
  #expect(ContextColumn.checkout(directory: worktree, located: try located(worktree, worktree, worktree, "velha"),
    vcs: try vcs(nil)).branch == nil)
  let loading = try decode(VCSInfo.self, #"{"branch":{}}"#)
  #expect(ContextColumn.checkout(directory: worktree, located: try located(worktree, worktree, worktree, "feat/x"),
    vcs: loading).branch == "feat/x")

  // Outside Git: the session's folder and "—"; with neither read, the branch is only unavailable.
  let plain = try decode(VCSInfo.self, #"{"branch":{}}"#)
  let outside = ContextColumn.checkout(directory: "/Users/a/Notas", located: nil, vcs: plain)
  #expect(outside == .init(name: "Notas", help: "/Users/a/Notas", branch: nil, branchHelp: "Pasta fora do Git"))
  #expect(ContextColumn.checkout(directory: "/Users/a/Notas", located: nil, vcs: nil).branchHelp == "Branch indisponível")
  #expect(ContextColumn.checkout(directory: nil, located: nil, vcs: nil).name == "—")

  // A long name stays whole (the view cuts it in the middle) and the tooltip keeps the full path.
  let long = "/Users/a/Worktrees/" + String(repeating: "worktree-com-nome-longo-", count: 4) + "fim"
  let named = ContextColumn.checkout(directory: long + "/", located: nil, vcs: try vcs("x"))
  #expect(named.name == String(repeating: "worktree-com-nome-longo-", count: 4) + "fim")
  #expect(named.help == long + "/")
}
