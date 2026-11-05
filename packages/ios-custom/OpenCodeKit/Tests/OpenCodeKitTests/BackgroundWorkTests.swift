import Foundation
import Testing

@testable import OpenCodeKit

/// A subagent whose model finished while its shells (or its own subagents) still run: listed with the live ones as
/// "Em segundo plano", its shells staying its own, and back among the finished ones once they end.
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func session(_ id: String, parent: String?, idle: Double, directory: String = "/repo", outcome: String = "succeeded")
  -> String
{
  #"{"id":"\#(id)","projectID":"p",\#(parent.map { #""parentID":"\#($0)","# } ?? "")"location":{"directory":"\#(directory)"},"outcome":"\#(outcome)","time":{"created":\#(idle - 500),"updated":\#(idle),"idle":\#(idle)}}"#
}

/// `root` has seven finished children, `c0` the oldest. Shells: `c0` owns three; `c1` none, but its child `g1`, in
/// another worktree, owns one. `other` is another family's root in the same folder with its own shell.
private func family(shells: Bool = true, failedC0: Bool = false) throws -> (members: [Session], entries: [NavigationEntry]) {
  let children = (0..<7).map { index in
    session("c\(index)", parent: "root", idle: Double(1_000 + index * 100),
      outcome: index == 0 && failedC0 ? "failed" : "succeeded")
  }
  let grandchild = session("g1", parent: "c1", idle: 1_150, directory: "/other-worktree")
  let members = try decode([Session].self, "[" + (children + [grandchild]).joined(separator: ",") + "]")
  var rows = [#"{"session":\#(session("root", parent: nil, idle: 2_000))}"#,
    #"{"session":\#(session("other", parent: nil, idle: 2_000)),"backgroundCount":1,"backgroundTitle":"bun dev"}"#]
  rows += children.enumerated().map { index, child in
    index == 0 && shells
      ? #"{"session":\#(child),"backgroundCount":3,"backgroundTitle":"python3 servico.py core"}"# : #"{"session":\#(child)}"#
  }
  rows.append(shells ? #"{"session":\#(grandchild),"backgroundCount":1}"# : #"{"session":\#(grandchild)}"#)
  return (members, try decode([NavigationEntry].self, "[" + rows.joined(separator: ",") + "]"))
}

private func subagents(
  _ members: [Session], background: [String: FamilyWork.Background], active: Set<String> = [],
  permissions: [PermissionRequest] = [], forms: [PendingForm] = []
) -> ContextColumn.Subagents {
  let work = ConversationProjection.work(
    ownerID: "root", viewedID: "root", messages: [], children: members, active: active, shells: [],
    background: Set(background.keys))
  return ContextColumn.subagents(
    work: work, rootID: "root", members: members, models: [], permissions: permissions, forms: forms, resources: [])
}

@Test func subagentsWithShellsBelowThemWorkInTheBackground() throws {
  let (members, entries) = try family()
  let ids = members.filter { $0.parentID == "root" }.map(\.id)
  let background = FamilyWork.background(ids, entries: entries, active: [])
  // Its own shells, and a grandchild's in another worktree; nothing from the other family in the same folder.
  #expect(background == [
    "c0": .init(shells: 3, title: "python3 servico.py core", agents: 0),
    "c1": .init(shells: 1, title: nil, agents: 0),
  ])
  #expect(background["c0"]?.label == "em segundo plano · 3 scripts · python3 servico.py core")
  #expect(background["c1"]?.label == "em segundo plano · 1 script")
  // A grandchild that executes keeps its parent's branch working; an executing child is simply running.
  let executing = FamilyWork.background(ids, entries: try family(shells: false).entries, active: ["g1", "c2"])
  #expect(executing == ["c1": .init(shells: 0, title: nil, agents: 1)])
  #expect(executing["c1"]?.label == "em segundo plano · 1 subagente trabalhando")
  // A session missing from the rows (archived, or not loaded) adds nothing.
  #expect(FamilyWork.background(["gone"], entries: entries, active: []).isEmpty)
}

@Test func backgroundSubagentsComeAfterRunningOnesAndAreNeverCollapsed() throws {
  let (members, entries) = try family()
  let background = FamilyWork.background(members.map(\.id), entries: entries, active: ["c3"])
  let list = subagents(members, background: background, active: ["c3"])
  // c3 executes; c0 and c1, the oldest, would be behind "+N concluídos" by their last run.
  #expect(list.shown.map(\.id) == ["c3", "c1", "c0", "c6", "c5"])
  #expect(list.shown.map(\.status) == [.running, .background, .background, .completed, .completed])
  #expect(list.hidden.map(\.id) == ["c4", "c2"])
  // "N agentes em execução" and the Mac's `ativos` count only the executing model.
  #expect(list.active == 1)
  let work = ConversationProjection.work(
    ownerID: "root", viewedID: "root", messages: [], children: members, active: ["c3"], shells: [],
    background: Set(background.keys))
  #expect(work.filter(\.running).map(\.id) == ["c3"])
  #expect(work.first { $0.id == "c0" }?.state.label == "Em segundo plano")
}

@Test func requestsOutrankAFailureAndAFailureOutranksShellsInTheBackground() throws {
  let (members, entries) = try family(failedC0: true)
  let background = FamilyWork.background(members.map(\.id), entries: entries, active: [])
  let permission = try decode(
    PermissionRequest.self, #"{"id":"per","sessionID":"g1","action":"shell","resources":["git push"]}"#)
  let list = subagents(members, background: background, permissions: [permission])
  // A grandchild's permission keeps its branch first, as asking; a failed child stopped with an error even while its
  // own shells still run, and those stay its own (`aSubagentsShellsStayOutOfItsParentsScripts`).
  #expect(list.shown.first?.id == "c1")
  #expect(list.shown.first?.status == .permission)
  #expect((list.shown + list.hidden).first { $0.id == "c0" }?.status == .failed)
  #expect(!list.shown.contains { $0.id == "c0" && $0.status.ongoing })
  let question = try decode(
    PendingForm.self, #"{"id":"que","sessionID":"c0","title":"Pergunta","fields":[],"metadata":{"kind":"question"}}"#)
  #expect(subagents(members, background: background, forms: [question]).shown.first { $0.id == "c0" }?.status == .question)
}

@Test func theLastShellEndingReturnsTheSubagentToTheFinishedOnes() throws {
  let members = try family().members
  // The Sessões rows after the server's next list: no background shell left.
  let ended = FamilyWork.background(members.map(\.id), entries: try family(shells: false).entries, active: [])
  #expect(ended.isEmpty)
  let list = subagents(members, background: ended)
  #expect(list.shown.map(\.id) == ["c6", "c5", "c4", "c3", "c2"])
  #expect(Set(list.hidden.map(\.id)) == ["c1", "c0"])
  #expect(list.hidden.allSatisfy { $0.status == .completed })
}

@Test func aSubagentsShellsStayOutOfItsParentsScripts() throws {
  let (members, entries) = try family()
  let shells = try decode([ShellInfo].self, #"""
    [{"id":"sh_1","status":"running","command":"python3 servico.py core","metadata":{"sessionID":"c0"},"time":{"started":10}},
     {"id":"sh_2","status":"running","command":"python3 servico.py lan","metadata":{"sessionID":"c0"},"time":{"started":10}}]
    """#)
  let background = FamilyWork.background(members.map(\.id), entries: entries, active: [])
  let root = ConversationProjection.work(
    ownerID: "root", viewedID: "root", messages: [], children: members, active: [], shells: shells,
    background: Set(background.keys))
  #expect(root.filter { $0.kind == .script }.isEmpty)
  #expect(root.first { $0.id == "c0" }?.state == .background)
  // Opening c0 lists them as its own scripts.
  let child = ConversationProjection.work(
    ownerID: "c0", viewedID: "c0", messages: [], children: members, active: [], shells: shells)
  #expect(child.filter { $0.kind == .script && $0.running }.map(\.id).sorted() == ["sh_1", "sh_2"])
}
