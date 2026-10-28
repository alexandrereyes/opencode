import Foundation
import Testing

@testable import OpenCodeKit

/// The Mac app's adjustment round (A1–A20): the pure rules behind its new controls.
@Suite struct MacAdjustmentsTests {
  @Test func compactCostKeepsCentsBelowAThousandAndNeverEllipsizes() {
    #expect(ContextUsage.compactMoney(260.85) == ContextUsage.money(260.85))
    #expect(ContextUsage.compactMoney(999.99) == ContextUsage.money(999.99))
    #expect(ContextUsage.compactMoney(2_759.40) == "US$ 2,8 mil")
    #expect(ContextUsage.compactMoney(2_700) == "US$ 2,7 mil")
    #expect(ContextUsage.compactMoney(7_441.40) == "US$ 7,4 mil")
    #expect(ContextUsage.compactMoney(1_000) == "US$ 1 mil")
    #expect(ContextUsage.compactMoney(260_412) == "US$ 260,4 mil")
    #expect(ContextUsage.compactMoney(999_960) == "US$ 1 mi")
    #expect(ContextUsage.compactMoney(1_250_000) == "US$ 1,3 mi")
    #expect(ContextUsage.compactMoney(nil) == "—")
    #expect(!ContextUsage.compactMoney(123_456_789).contains("…"))
  }

  @Test func commandNumbersFollowTheColumnAndSkipCollapsedSections() throws {
    func row(_ id: String) throws -> SessionRow {
      let entry = try JSONDecoder().decode(NavigationEntry.self, from: Data("""
        {"session":{"id":"\(id)","projectID":"p","title":"\(id)","location":{"directory":"/repo"},
         "time":{"created":1,"updated":1}},"messageAt":1}
        """.utf8))
      return try #require(SessionList.rows(entries: [entry], projects: [], active: [], pins: [], muted: [],
        autoApprove: false, ranks: [:], chatRoot: nil).first)
    }
    let sections = [
      SessionSection(kind: .running, rows: [try row("a"), try row("b")]),
      SessionSection(kind: .pinned, rows: [try row("c")]),
      SessionSection(kind: .today, rows: try (1...8).map { try row("t\($0)") }),
      SessionSection(kind: .older, rows: [try row("old")]),
    ]
    var collapse = SessionSectionCollapse()
    #expect(SessionNavigation.numbered(sections, collapse: collapse).map(\.id)
      == ["a", "b", "c", "t1", "t2", "t3", "t4", "t5", "t6"])
    collapse.toggle(.pinned)
    #expect(SessionNavigation.numbered(sections, collapse: collapse).map(\.id)
      == ["a", "b", "t1", "t2", "t3", "t4", "t5", "t6", "t7"])
    collapse.toggle(.today)
    collapse.toggle(.older)
    // "Anteriores" starts collapsed; opened, its rows count like any other.
    #expect(SessionNavigation.numbered(sections, collapse: collapse).map(\.id) == ["a", "b", "old"])
    #expect(SessionNavigation.numbered([], collapse: collapse).isEmpty)
  }

  @Test func archivedSearchFoldsCaseAndAccentsOverTitleProjectAndPath() throws {
    func session(_ id: String, _ title: String, _ directory: String) throws -> Session {
      try JSONDecoder().decode(Session.self, from: Data("""
        {"id":"\(id)","projectID":"p_\(id)","title":"\(title)","location":{"directory":"\(directory)"},
         "time":{"created":1,"updated":1,"archived":2}}
        """.utf8))
    }
    let sessions = [
      try session("a", "Revisão da Sessão mestra", "/Users/a/Dev/opencode2"),
      try session("b", "Capturas", "/Users/a/Worktrees/hidden-pixel/android"),
      try session("c", "Live Activity", "/Users/a/Dev/abacato-v2"),
    ]
    let projects = ["p_a": "opencode2", "p_b": "hidden-pixel", "p_c": "Abacatô"]
    func search(_ query: String) -> [String] {
      ArchivedSessionSearch.filter(sessions, query: query, project: { projects[$0.projectID] },
        path: { "~" + $0.location.directory.dropFirst("/Users/a".count) }).map(\.id)
    }
    #expect(search("") == ["a", "b", "c"])
    #expect(search("   ") == ["a", "b", "c"])
    #expect(search("SESSAO") == ["a"])
    #expect(search("revisao mestra") == ["a"])
    #expect(search("abacato") == ["c"])
    #expect(search("hidden-pixel/android") == ["b"])
    #expect(search("~/dev") == ["a", "c"])
    #expect(search("nada disso") == [])
    #expect(TextFolding.fold("Ação Ü") == "acao u")
  }

  @Test func contextWidthIsRememberedForNewWindowsAndBoundedByTheWindow() throws {
    let suite = "MacAdjustmentsTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let server = URL(string: "http://127.0.0.1:4209")!
    #expect(DesktopWindowState.load(window: UUID(), server: server, defaults: defaults).contextWidth == 520)
    DesktopWindowState.rememberContextWidth(980, defaults: defaults)
    // A new window (or every window after a quit that closed them) opens at the last chosen width.
    #expect(DesktopWindowState.load(window: UUID(), server: server, defaults: defaults).contextWidth == 980)
    // A restored window keeps its own width.
    let window = UUID()
    var state = DesktopWindowState()
    state.contextWidth = 640
    state.save(window: window, server: server, defaults: defaults)
    #expect(DesktopWindowState.load(window: window, server: server, defaults: defaults).contextWidth == 640)
    DesktopWindowState.rememberContextWidth(120, defaults: defaults)
    #expect(DesktopWindowState.load(window: UUID(), server: server, defaults: defaults).contextWidth == 520)

    // A wide window lets Contexto take 60% of it; a narrower one stops where the chat would go below 460 pt.
    #expect(DesktopWindowState.contextWidthRange(detail: 2_230, window: 2_560, chatMinimum: 460) == 400...1_536)
    #expect(DesktopWindowState.contextWidthRange(detail: 1_170, window: 1_500, chatMinimum: 460) == 400...709)
    #expect(DesktopWindowState.contextWidthRange(detail: 861, window: 1_191, chatMinimum: 460) == 400...400)
  }

  @Test func filesShowTheAbsolutePathTruncatedInTheMiddle() {
    let crumbs = ContextColumn.absoluteBreadcrumb("/Users/alexandremartins/Worktrees/hidden-pixel/android")
    #expect(crumbs.map(\.name) == ["/", "Users", "alexandremartins", "Worktrees", "hidden-pixel", "android"])
    #expect(crumbs.map(\.path) == ["/", "/Users", "/Users/alexandremartins", "/Users/alexandremartins/Worktrees",
      "/Users/alexandremartins/Worktrees/hidden-pixel", "/Users/alexandremartins/Worktrees/hidden-pixel/android"])
    #expect(ContextColumn.absoluteBreadcrumb("/").map(\.name) == ["/"])
    #expect(ContextColumn.middleElided(crumbs, keep: 5).map { $0?.name } == crumbs.map(\.name))
    #expect(ContextColumn.middleElided(crumbs, keep: 2).map { $0?.name } == ["/", nil, "hidden-pixel", "android"])
    #expect(ContextColumn.middleElided(crumbs, keep: 1).map { $0?.name } == ["/", nil, "android"])
  }

  @Test func subagentRowsNameTheirAgentAndLatestModel() throws {
    let models = try JSONDecoder().decode([ModelInfo].self, from: Data("""
      [{"id":"astra-6-ultrafast","providerID":"llm-proxy","name":"Astra 6 - ultrafast","limit":{"context":1000000}}]
      """.utf8))
    let agents = try JSONDecoder().decode([AgentInfo].self, from: Data("""
      [{"id":"astraxhighultra","name":"astraxhighultra","mode":"subagent"}]
      """.utf8))
    func work(agent: String?, model: ModelReference?) -> SessionWork {
      SessionWork(id: "w", kind: .agent, sessionID: "ses_w", shellID: nil, toolID: nil, agent: agent, title: "Worker",
        state: .running, activity: 1, started: 1, duration: nil, model: model)
    }
    let astra = ModelReference(id: "astra-6-ultrafast", providerID: "llm-proxy", variant: "xhigh")
    #expect(ContextColumn.runLabel(work(agent: "astraxhighultra", model: astra), agents: agents, models: models)
      == "astraxhighultra · Astra 6 - ultrafast · xhigh")
    #expect(ContextColumn.runLabel(work(agent: "explore", model: ModelReference(id: "luna", providerID: "x",
      variant: "default")), agents: agents, models: models) == "explore · luna")
    #expect(ContextColumn.runLabel(work(agent: nil, model: nil), agents: agents, models: models) == nil)
  }

  @Test func rightOptionTapsHoldsAndStepsAsideAsAModifier() {
    var key = DictationKeyGesture()
    // A tap while idle starts hands-free; the next tap (while recording) stops.
    key.press(recording: false, otherModifiers: false)
    #expect(key.down && key.release() == .start && !key.down)
    key.press(recording: true, otherModifiers: false)
    #expect(key.held() == .none)
    #expect(key.release() == .finish)
    // Held past the delay: records at once and stops on release.
    key.press(recording: false, otherModifiers: false)
    #expect(key.held() == .begin)
    #expect(key.release() == .release)
    // ⌥ + a key before the delay: nothing at all.
    key.press(recording: false, otherModifiers: false)
    #expect(key.interrupted() == .none && key.held() == .none && key.release() == .none)
    // ⌥ + a key after the hold started a recording: that recording is discarded.
    key.press(recording: false, otherModifiers: false)
    #expect(key.held() == .begin && key.interrupted() == .discard && key.release() == .none)
    // Pressed together with ⌘, ⌃, ⇧ or the left ⌥: a shortcut, never dictation.
    key.press(recording: false, otherModifiers: true)
    #expect(key.held() == .none && key.release() == .none)
    #expect(DictationKeyGesture.keyCode == 61)
  }

  @Test func modelChoicesResolveProvidersOnceAndKeepTheCatalogOrder() throws {
    let models = try JSONDecoder().decode([ModelInfo].self, from: Data("""
      [{"id":"terra","providerID":"vercel","name":"GPT-6.1 Terra","variants":[{"id":"low"},{"id":"max"}],"limit":{"context":1}},
       {"id":"off","providerID":"vercel","name":"Off","enabled":false,"limit":{"context":1}},
       {"id":"flint","providerID":"personal","name":"Flint 40B Free","limit":{"context":1}}]
      """.utf8))
    let rows = ModelChoices.rows(models, providers: [ProviderInfo(id: "vercel", name: "Vercel AI Gateway")])
    #expect(rows.map(\.name) == ["GPT-6.1 Terra", "Flint 40B Free"])
    #expect(rows.map(\.provider) == ["Vercel AI Gateway", "personal"])
    #expect(rows[0].variants == ["low", "max"])
    let selected = ModelReference(id: "terra", providerID: "vercel", variant: "max")
    #expect(rows[0].selected(selected) && rows[0].selected(selected, variant: "max"))
    #expect(!rows[0].selected(selected, variant: "low") && !rows[1].selected(selected))
    #expect(rows[0].selected(ModelReference(id: "terra", providerID: "vercel"), variant: "default"))
    #expect(rows[1].reference(variant: nil) == ModelReference(id: "flint", providerID: "personal"))
  }
}
