import Foundation
import Testing

@testable import OpenCodeKit

private let safari = ComposerApp(
  server: "codex-computer-use", name: "Safari", bundleID: "com.apple.Safari", running: true)
private let notes = ComposerApp(
  server: "codex-computer-use", name: "Notes", bundleID: "com.apple.Notes", running: false)

@Test func everyTriggerIgnoresCaseAndKeepsPrefixMatchesFirst() throws {
  var source = ComposerSources()
  source.skills = [
    .init(id: "recommit", name: "recommit", description: nil, slash: nil),
    .init(id: "commit", name: "commit", description: nil, slash: nil),
  ]
  source.commands = [.init(name: "review", description: nil), .init(name: "commit", description: nil)]
  source.snippets = [
    .init(id: "push", name: "commit-push-pr", aliases: ["cpp"], description: "", content: "x", project: nil)
  ]
  func ids(_ text: String, agents: [AgentInfo] = [], apps: [ComposerApp] = []) throws -> [String] {
    let trigger = try #require(ComposerTrigger.detect(in: .init(text: text), cursor: text.utf16.count))
    return source.suggestions(trigger, agents: agents, apps: apps).map(\.token.id)
  }
  for query in ["$commit", "$Commit", "$COMMIT"] { #expect(try ids(query) == ["commit", "recommit"]) }
  for query in ["#commit", "#COMMIT", "#Commit", "#CPP"] { #expect(try ids(query) == ["push"]) }
  for query in ["/commit", "/COMMIT", "/Commit"] { #expect(try ids(query).first == "commit") }
  for query in ["@saf", "@SAF", "@Saf"] { #expect(try ids(query, apps: [safari, notes]) == [safari.token.id]) }
  let agents = try JSONDecoder().decode(
    [AgentInfo].self, from: Data(#"[{"id":"general","name":"general","mode":"subagent"}]"#.utf8))
  for query in ["@GENERAL", "@General"] { #expect(try ids(query, agents: agents) == ["general"]) }
}

@Test func sessionSearchAlsoAsksWithTheCaseOfNonASCIILettersChanged() {
  #expect(ComposerSources.caseVariants("Commit") == ["Commit"])
  #expect(ComposerSources.caseVariants("") == [""])
  #expect(ComposerSources.caseVariants("SESSÃO") == ["SESSÃO", "sessão", "Sessão"])
  #expect(ComposerSources.caseVariants("índice") == ["índice", "ÍNDICE", "Índice"])
}
