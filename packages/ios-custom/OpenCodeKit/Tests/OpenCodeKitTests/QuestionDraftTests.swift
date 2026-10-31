import Foundation
import Testing
@testable import OpenCodeKit

/// `custom.question-drafts` in memory, with a switch for being offline and one for an older server without it.
actor FakeQuestionDraftServer: QuestionDraftTransport {
  var drafts: [String: [String: QuestionDraftField]] = [:]
  var saves: [[String: QuestionDraftField]] = []
  var clears = 0
  var offline = false
  var missing = false
  func set(offline: Bool) { self.offline = offline }
  func set(missing: Bool) { self.missing = missing }
  func store(_ fields: [String: QuestionDraftField], for requestID: String) { drafts[requestID] = fields }
  private func check() throws {
    if missing { throw ClientError.rpc("rpc.unavailable") }
    if offline { throw URLError(.notConnectedToInternet) }
  }
  func questionDraft(sessionID: String, requestID: String) async throws -> [String: QuestionDraftField]? {
    try check()
    return drafts[requestID]
  }
  func saveQuestionDraft(sessionID: String, requestID: String, fields: [String: QuestionDraftField], client: String)
    async throws
  {
    try check()
    saves.append(fields)
    drafts[requestID, default: [:]].merge(fields) { $1 }
  }
  func clearQuestionDraft(sessionID: String, requestID: String, client: String) async throws {
    try check()
    clears += 1
    drafts[requestID] = nil
  }
}

@MainActor struct QuestionDraftTests {
  let form = try! JSONDecoder().decode(PendingForm.self, from: Data(#"""
    {"id":"frm_q","sessionID":"ses_q","title":"Questions","fields":[
      {"key":"voz","type":"string","options":[{"value":"marin","label":"marin"},{"value":"cedar","label":"cedar"}],"custom":true},
      {"key":"nota","type":"string"},
      {"key":"itens","type":"multiselect","options":[{"value":"mac","label":"Mac"}],"custom":true}
    ]}
    """#.utf8))

  private func setup() -> (FakeQuestionDraftServer, QuestionDraftStore, QuestionDrafts) {
    let server = FakeQuestionDraftServer()
    let store = QuestionDraftStore(server: "test", root: FileManager.default.temporaryDirectory
      .appending(path: "question-drafts-\(UUID().uuidString)"))
    return (server, store, QuestionDrafts(transport: server, store: store, debounce: .milliseconds(30)))
  }
  private func settle() async throws { try await Task.sleep(for: .milliseconds(120)) }
  /// Polls until `condition` holds (2 s at most): saves run on their own tasks.
  private func eventually(_ condition: () async -> Bool) async throws -> Bool {
    for _ in 0..<200 {
      if await condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test func fieldsTranslateBothWays() {
    var state = QuestionDraftState()
    state.values = ["voz": .string("marin"), "nota": .string("livre"),
      "itens": .array([.string("mac"), .string("watch")])]
    state.custom = ["itens": "tv"]
    #expect(state.field(form.fields[0]) == QuestionDraftField(selected: ["marin"]))
    #expect(state.field(form.fields[1]) == QuestionDraftField(text: "livre"))
    #expect(state.field(form.fields[2]) == QuestionDraftField(selected: ["mac"], text: "tv", added: ["watch"]))
    var back = QuestionDraftState()
    for field in form.fields { back.apply(state.field(field), to: field) }
    #expect(back == state)
  }

  @Test func optionsSaveAtOnceTextAfterTheDebounceAndTheDraftComesBackFromTheServer() async throws {
    let (server, store, drafts) = setup()
    let sync = drafts.sync(form)
    sync.choose("voz", .string("marin"))
    #expect(try await eventually { await server.saves.count == 1 })
    sync.type("nota", "o")
    sync.type("nota", "ok")
    #expect(try await eventually { await server.saves.count == 2 })
    try await settle()
    #expect(await server.saves.map { $0.keys.sorted() } == [["voz"], ["nota"]])
    // Another run of the app (or another session and back) reads it from the server and from this device's file.
    let fresh = QuestionDrafts(transport: server, store: store, debounce: .milliseconds(30)).sync(form)
    #expect(fresh.state.values["nota"] == .string("ok"))
    let other = QuestionDrafts(transport: server,
      store: QuestionDraftStore(server: "other", root: store.directory.deletingLastPathComponent()),
      debounce: .milliseconds(30)).sync(form)
    #expect(other.state.values.isEmpty)
    await other.load()
    #expect(other.state.values == ["voz": .string("marin"), "nota": .string("ok")])
  }

  @Test func anotherDevicesChangeSparesTheFocusedAndTheUnsentQuestions() async throws {
    let (server, _, drafts) = setup()
    let sync = drafts.sync(form)
    sync.focused = "nota"
    sync.type("nota", "digitando")
    await server.set(offline: true)
    sync.choose("itens", .array([.string("mac")]))
    try await settle()
    await server.store(["voz": QuestionDraftField(selected: ["cedar"]), "nota": QuestionDraftField(text: "do Mac"),
      "itens": QuestionDraftField()], for: form.id)
    await server.set(offline: false)
    await drafts.updated(sessionID: form.sessionID, requestID: form.id, cleared: false, client: "mac")
    #expect(sync.state.values["voz"] == .string("cedar"))
    #expect(sync.state.values["nota"] == .string("digitando"), "the focused question is not overwritten")
    #expect(sync.state.values["itens"] == .array([.string("mac")]), "an unsent edit is not overwritten")
    // Its own echo changes nothing.
    await server.store(["voz": QuestionDraftField(selected: ["marin"])], for: form.id)
    await drafts.updated(sessionID: form.sessionID, requestID: form.id, cleared: false, client: drafts.client)
    #expect(sync.state.values["voz"] == .string("cedar"))
    // Without the focus, the next change applies to every question that was already sent.
    sync.focused = nil
    try await settle()
    await server.store(["nota": QuestionDraftField(text: "final")], for: form.id)
    await drafts.updated(sessionID: form.sessionID, requestID: form.id, cleared: false, client: "mac")
    #expect(sync.state.values["nota"] == .string("final"))
  }

  @Test func offlineEditsStayOnThisDeviceAndGoOutOnReconnection() async throws {
    let (server, store, drafts) = setup()
    await server.set(offline: true)
    let sync = drafts.sync(form)
    sync.choose("voz", .string("cedar"))
    sync.typeCustom("itens", "tv")
    try await settle()
    #expect(await server.saves.isEmpty)
    #expect(store.load(form.sessionID, form.id)?.pending == ["voz", "itens"])
    await server.set(offline: false)
    await drafts.reconnected(sessionID: form.sessionID)
    #expect(await server.drafts[form.id]?["voz"] == QuestionDraftField(selected: ["cedar"]))
    #expect(await server.drafts[form.id]?["itens"] == QuestionDraftField(text: "tv"))
    #expect(store.load(form.sessionID, form.id)?.pending.isEmpty == true)
  }

  @Test func answeringOrLosingTheFormClearsTheDraftHereAndOnTheServer() async throws {
    let (server, store, drafts) = setup()
    let sync = drafts.sync(form)
    sync.choose("voz", .string("marin"))
    await sync.clear()
    #expect(await server.drafts[form.id] == nil)
    #expect(store.load(form.sessionID, form.id) == nil)
    // Answered on another device: the event clears it here.
    let again = QuestionDrafts(transport: server, store: store, debounce: .milliseconds(30))
    again.sync(form).choose("nota", .string("x"))
    try await settle()
    await again.updated(sessionID: form.sessionID, requestID: form.id, cleared: true, client: "mac")
    #expect(store.load(form.sessionID, form.id) == nil)
    // No longer pending (dismissed, expired): its draft goes when the session's forms are known.
    let third = QuestionDrafts(transport: server, store: store, debounce: .milliseconds(30))
    third.sync(form).choose("nota", .string("y"))
    third.retain(sessionID: form.sessionID, pending: [])
    #expect(store.load(form.sessionID, form.id) == nil)
  }

  @Test func anOlderServerKeepsTheDraftOnThisDeviceOnly() async throws {
    let (server, store, drafts) = setup()
    await server.set(missing: true)
    let sync = drafts.sync(form)
    await sync.load()
    #expect(sync.unsupported)
    sync.choose("voz", .string("marin"))
    try await settle()
    #expect(await server.saves.isEmpty)
    #expect(QuestionDrafts(transport: server, store: store).sync(form).state.values["voz"] == .string("marin"))
  }
}
