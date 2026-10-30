import Foundation
import Testing

@testable import OpenCodeKit

private let now = Date(timeIntervalSince1970: 2_000_000)
private let ms = now.timeIntervalSince1970 * 1000

private func phone(
  _ id: String, _ state: ResourceState, used: Double, device: String = "iPhone 17 Pro", activity: [ResourceActivity]? = nil
) -> SessionResource {
  SessionResource(
    id: "ios-simulator:" + id, kind: .iosSimulator, label: device, state: state,
    meta: ResourceMeta(kind: "ios-simulator", udid: id, device: device), lastUsedAt: ms - used * 1000,
    updatedAt: ms - used * 1000, activity: activity)
}

@Test func resourceStageOrdersLigadosByUseAndLeavesTheStoppedOnesAsChips() {
  let all = [
    phone("idle", .idle, used: 900),
    phone("live", .live, used: 200),
    phone("agent-old", .agent, used: 80),
    phone("stopped-old", .stopped, used: 2_700),
    phone("user", .user, used: 300),
    phone("agent-new", .agent, used: 5),
    phone("gone", .gone, used: 86_400),
    phone("stopped", .stopped, used: 120, device: "Apple Watch Series 11 46mm"),
  ]
  // In use now (Alexandre's control, then the agents' by latest use), ao vivo, livre.
  #expect(ResourceStage.on(all).map(\.meta.udid) == ["user", "agent-new", "agent-old", "live", "idle"])
  let off = ResourceStage.off(all)
  #expect(off.map(\.meta.udid) == ["stopped", "stopped-old", "gone"])
  #expect(off.map { ResourceStage.chip($0, now: now) } == [
    "Apple Watch Series 11 46mm · 2 min", "iPhone 17 Pro · 45 min", "iPhone 17 Pro · 1 d",
  ])
  let chips = ResourceStage.chips(off, limit: 2, all: false)
  #expect(chips.shown.count == 2 && chips.more == 1)
  #expect(ResourceStage.chips(off, limit: 2, all: true).shown.count == 3)
  #expect(ResourceStage.chips(off, limit: 3, all: false).more == 0)
}

@Test func resourceStageFollowsTheAgentUntilAlexandreChoosesOne() {
  let on = ResourceStage.on([
    phone("watch", .live, used: 180, device: "Apple Watch Ultra 3 49mm"),
    phone("iphone", .agent, used: 20),
    phone("chrome", .idle, used: 2_000),
  ])
  let ids = on.map(\.id)
  // Following, the resource an agent is using takes the stage.
  #expect(ResourceStage.pick(on, following: true, chosen: nil, current: ids[2], controlling: false) == "ios-simulator:iphone")
  // A command still running wins over a more recent use that ended.
  let running = [ResourceActivity(at: ms - 300_000, command: "maestro test flows/gravar.yaml", running: true)]
  let both = ResourceStage.on([phone("a", .agent, used: 1), phone("b", .agent, used: 60, activity: running)])
  #expect(ResourceStage.inUse(both)?.id == "ios-simulator:b")
  // Chosen by hand (following off): it stays, whatever the agent uses.
  #expect(ResourceStage.pick(on, following: false, chosen: "ios-simulator:watch", current: "ios-simulator:iphone",
    controlling: false) == "ios-simulator:watch")
  // Following with nobody using a resource keeps the current one.
  let quiet = ResourceStage.on([phone("watch", .live, used: 180), phone("chrome", .idle, used: 2_000)])
  #expect(ResourceStage.pick(quiet, following: true, chosen: nil, current: "ios-simulator:chrome", controlling: false)
    == "ios-simulator:chrome")
  // The chosen one went off: the first ligado replaces it, and following stays off (the caller keeps it).
  #expect(ResourceStage.pick(quiet, following: false, chosen: "ios-simulator:gone", current: nil, controlling: false)
    == "ios-simulator:watch")
  // In control on the stage, nothing replaces it.
  #expect(ResourceStage.pick(on, following: true, chosen: nil, current: "ios-simulator:chrome", controlling: true)
    == "ios-simulator:chrome")
  #expect(ResourceStage.pick([], following: true, chosen: nil, current: nil, controlling: false) == nil)
  let split = ResourceStage.split(on, stage: "ios-simulator:watch")
  #expect(split.stage?.meta.udid == "watch")
  #expect(split.others.map(\.meta.udid) == ["iphone", "chrome"])
}

@Test func resourceStageSaysWhoUsesItAndWhatItDid() {
  let activity = [
    ResourceActivity(at: ms - 4_000, command: "agent-device test flows/gravar.yaml", running: true),
    ResourceActivity(at: ms - 20_000, command: #"agent-device fill "Nome""#),
    ResourceActivity(at: ms - 41_000, command: "agent-device open Gravação"),
    ResourceActivity(at: ms - 400_000, command: "xcrun simctl boot X"),
  ]
  let used = phone("iphone", .agent, used: 4, activity: activity)
  #expect(ResourceStage.status(used, session: "App Mac", subagent: "Backend da Live Activity", now: now)
    == "Agente usando · App Mac — Backend da Live Activity")
  #expect(ResourceStage.status(used, session: "App Mac", subagent: nil, now: now) == "Agente usando · App Mac")
  #expect(ResourceStage.status(phone("w", .live, used: 180), session: nil, subagent: nil, now: now)
    == "Ao vivo · usado há 3 min")
  #expect(ResourceStage.status(phone("c", .idle, used: 9_000), session: nil, subagent: nil, now: now) == "Livre")
  #expect(ResourceStage.status(phone("u", .user, used: 9), session: "App Mac", subagent: nil, now: now)
    == "Você no controle")
  #expect(ResourceStage.history(used, now: now) == [
    "agora: agent-device test flows/gravar.yaml", #"há 20 s: agent-device fill "Nome""#,
    "há 41 s: agent-device open Gravação",
  ])
  #expect(ResourceStage.history(phone("x", .idle, used: 1), now: now).isEmpty)
}

@Test func resourceActivityDecodesAndOlderServersOmitIt() throws {
  let json = #"""
    [{"id":"ios-simulator:A","kind":"ios-simulator","label":"iPhone","state":"agent","meta":{"kind":"ios-simulator","udid":"A"},
      "discoveredAt":1,"lastUsedAt":2,"updatedAt":3,"live":{"stream":true,"input":true},
      "activity":[{"at":5,"command":"agent-device tap","sessionID":"ses_a","agent":"explore","running":true}]},
     {"id":"chrome:x","kind":"chrome","label":"x","state":"idle","meta":{"kind":"chrome","session":"x"},
      "discoveredAt":1,"lastUsedAt":2,"updatedAt":3,"live":{"stream":true,"input":true}}]
    """#
  let resources = try JSONDecoder().decode([SessionResource].self, from: Data(json.utf8))
  #expect(resources[0].activity == [ResourceActivity(at: 5, command: "agent-device tap", sessionID: "ses_a",
    agent: "explore", running: true)])
  #expect(resources[1].activity == nil)
}
