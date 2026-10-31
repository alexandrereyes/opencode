import CryptoKit
import Foundation
import Observation

/// One question's unsent answer as `custom.question-drafts` stores it: the options marked, the free text and a
/// multiple choice's own added items.
public struct QuestionDraftField: Codable, Sendable, Equatable {
  public var selected: [String]
  public var text: String
  public var added: [String]
  public init(selected: [String] = [], text: String = "", added: [String] = []) {
    self.selected = selected
    self.text = text
    self.added = added
  }
}

/// A form's answers as the question card edits them (`values` like `QuestionReply`, `custom` the text waiting in a
/// multiple choice's own answer) and their translation to and from the server's fields.
public struct QuestionDraftState: Codable, Sendable, Equatable {
  public var values: [String: JSONValue] = [:]
  public var custom: [String: String] = [:]
  public init(values: [String: JSONValue] = [:], custom: [String: String] = [:]) {
    self.values = values
    self.custom = custom
  }

  public func field(_ field: PendingForm.Field) -> QuestionDraftField {
    let options = Set((field.options ?? []).map(\.value))
    if field.type == .multiselect {
      let items = (values[field.key]?.array ?? []).compactMap(\.string)
      return QuestionDraftField(selected: items.filter(options.contains), text: custom[field.key] ?? "",
        added: items.filter { !options.contains($0) })
    }
    guard let value = values[field.key]?.string else { return QuestionDraftField() }
    return options.contains(value) ? QuestionDraftField(selected: [value]) : QuestionDraftField(text: value)
  }

  public mutating func apply(_ draft: QuestionDraftField, to field: PendingForm.Field) {
    if field.type == .multiselect {
      let items = draft.selected + draft.added
      values[field.key] = items.isEmpty ? nil : .array(items.map(JSONValue.string))
      custom[field.key] = draft.text.isEmpty ? nil : draft.text
      return
    }
    let value = draft.selected.first ?? draft.text
    values[field.key] = value.isEmpty ? nil : .string(value)
  }
}

/// `custom.question-drafts` on the server: `nil` when nothing is stored.
public protocol QuestionDraftTransport: Sendable {
  func questionDraft(sessionID: String, requestID: String) async throws -> [String: QuestionDraftField]?
  func saveQuestionDraft(sessionID: String, requestID: String, fields: [String: QuestionDraftField], client: String)
    async throws
  func clearQuestionDraft(sessionID: String, requestID: String, client: String) async throws
}

extension OpenCodeClient: QuestionDraftTransport {
  private struct DraftTarget: Encodable { let sessionID: String; let requestID: String }
  public func questionDraft(sessionID: String, requestID: String) async throws -> [String: QuestionDraftField]? {
    struct Stored: Decodable { let fields: [String: QuestionDraftField] }
    struct Output: Decodable { let draft: Stored? }
    let output: Output = try await rpc("custom.question-drafts", "get",
      input: DraftTarget(sessionID: sessionID, requestID: requestID), timeout: 20)
    return output.draft?.fields
  }
  public func saveQuestionDraft(sessionID: String, requestID: String, fields: [String: QuestionDraftField],
    client: String) async throws
  {
    struct Input: Encodable { let sessionID: String; let requestID: String; let fields: [String: QuestionDraftField]
      let client: String }
    let _: JSONValue = try await rpc("custom.question-drafts", "save",
      input: Input(sessionID: sessionID, requestID: requestID, fields: fields, client: client), timeout: 20)
  }
  public func clearQuestionDraft(sessionID: String, requestID: String, client: String) async throws {
    struct Input: Encodable { let sessionID: String; let requestID: String; let client: String }
    let _: JSONValue = try await rpc("custom.question-drafts", "clear",
      input: Input(sessionID: sessionID, requestID: requestID, client: client), timeout: 20)
  }
}

public enum QuestionDraftEvent {
  public static let updated = "rpc.custom.question-drafts.updated"
}

/// The drafts this device knows, one file per form, kept until the form is answered or gone; files older than
/// `staleDays` (the server's limit too) are removed when the store opens.
public struct QuestionDraftStore: Sendable {
  public struct Entry: Codable, Sendable, Equatable {
    public var state: QuestionDraftState
    /// Questions changed here and not yet stored on the server (offline, or before the debounce).
    public var pending: Set<String>
    public var savedAt: Date
  }
  public static let staleDays = 14
  public let directory: URL
  public init(server: String, root: URL? = nil, now: Date = .now) {
    let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OpenCode/QuestionDrafts", isDirectory: true)
    let key = SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined()
    directory = root.appendingPathComponent(key, isDirectory: true)
    let stale = now.addingTimeInterval(-Double(Self.staleDays) * 86_400)
    for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
      guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: file)), entry.savedAt > stale
      else { try? FileManager.default.removeItem(at: file); continue }
    }
  }
  private func file(_ sessionID: String, _ requestID: String) -> URL {
    let name = SHA256.hash(data: Data((sessionID + "\u{0}" + requestID).utf8)).prefix(16)
      .map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(name + ".json")
  }
  public func load(_ sessionID: String, _ requestID: String) -> Entry? {
    try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: file(sessionID, requestID)))
  }
  public func save(_ entry: Entry, _ sessionID: String, _ requestID: String) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? JSONEncoder().encode(entry).write(to: file(sessionID, requestID), options: .atomic)
  }
  public func remove(_ sessionID: String, _ requestID: String) {
    try? FileManager.default.removeItem(at: file(sessionID, requestID))
  }
}

/// One pending form's draft, shared by the question card while it is on screen and kept by `QuestionDrafts` after it
/// leaves. Edits land locally at once (and on disk); options go to the server right away, text after `debounce`.
/// Offline or failed saves stay `pending` and go out on the next edit or reconnection. A change from another device
/// (or a server load) replaces every question except the one focused here and those with unsent edits here: what is
/// being typed on this device is never overwritten.
@MainActor @Observable public final class QuestionDraftSync {
  public private(set) var state: QuestionDraftState
  /// The question whose field has the keyboard (or the caret) here.
  public var focused: String?
  @ObservationIgnored public let form: PendingForm
  @ObservationIgnored private let transport: any QuestionDraftTransport
  @ObservationIgnored private let store: QuestionDraftStore
  @ObservationIgnored private let client: String
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private var pending: Set<String>
  @ObservationIgnored private var sending: Task<Void, Never>?
  @ObservationIgnored private var scheduled: Task<Void, Never>?
  /// The server has no `custom.question-drafts`: the draft stays on this device.
  @ObservationIgnored public private(set) var unsupported = false
  @ObservationIgnored private var cleared = false

  init(form: PendingForm, transport: any QuestionDraftTransport, store: QuestionDraftStore, client: String,
    debounce: Duration)
  {
    self.form = form
    self.transport = transport
    self.store = store
    self.client = client
    self.debounce = debounce
    let entry = store.load(form.sessionID, form.id)
    state = entry?.state ?? QuestionDraftState()
    pending = entry?.pending ?? []
  }

  /// A marked option (or anything that is not typing): saved now.
  public func choose(_ key: String, _ value: JSONValue?) {
    state.values[key] = value
    changed(key, immediate: true)
  }
  /// A question's own answer being typed (or dictated): saved after `debounce`.
  public func type(_ key: String, _ value: String) {
    state.values[key] = value.isEmpty ? nil : .string(value)
    changed(key, immediate: false)
  }
  /// A multiple choice's own answer being typed.
  public func typeCustom(_ key: String, _ value: String) {
    state.custom[key] = value.isEmpty ? nil : value
    changed(key, immediate: false)
  }
  /// A multiple choice's own answer added to its items.
  public func set(_ key: String, value: JSONValue?, custom: String?) {
    state.values[key] = value
    state.custom[key] = custom
    changed(key, immediate: true)
  }

  /// The server's draft: what it stores, merged under the rule above, then this device's unsent edits go out.
  public func load() async {
    guard !unsupported, !cleared else { return }
    do {
      merge(try await transport.questionDraft(sessionID: form.sessionID, requestID: form.id) ?? [:])
      await send()
    } catch { unsupportedIfMissing(error) }
  }
  /// `rpc.custom.question-drafts.updated` for this form.
  public func remote(cleared: Bool, client: String?) async {
    guard client != self.client else { return }
    if cleared { return forget() }
    await load()
  }
  /// The event stream is back: unsent edits go out and the other devices' changes come in.
  public func reconnected() async { await load() }
  /// Answered or gone: nothing of it stays, here or on the server.
  public func clear() async {
    forget()
    // A save still in flight would store the draft again after the clear.
    if let running = sending { await running.value }
    guard !unsupported else { return }
    try? await transport.clearQuestionDraft(sessionID: form.sessionID, requestID: form.id, client: client)
  }
  func forget() {
    cleared = true
    scheduled?.cancel()
    pending = []
    store.remove(form.sessionID, form.id)
  }

  private func changed(_ key: String, immediate: Bool) {
    guard !cleared else { return }
    pending.insert(key)
    persist()
    scheduled?.cancel()
    if immediate {
      scheduled = Task { [weak self] in await self?.send() }
      return
    }
    let delay = debounce
    scheduled = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      await self?.send()
    }
  }

  private func send() async {
    // One save at a time; edits made meanwhile go in the next one.
    while let running = sending { await running.value; if sending == running { sending = nil } }
    guard !unsupported, !cleared, !pending.isEmpty else { return }
    let keys = pending
    let snapshot = state
    let fields = Dictionary(uniqueKeysWithValues: form.fields.filter { keys.contains($0.key) }
      .map { ($0.key, snapshot.field($0)) })
    let task = Task { [self, transport, form, client] in
      do {
        try await transport.saveQuestionDraft(sessionID: form.sessionID, requestID: form.id, fields: fields,
          client: client)
        // Only what did not change again while it was being sent is settled.
        for key in keys where snapshot.field(of: key, in: form) == state.field(of: key, in: form) { pending.remove(key) }
        persist()
      } catch { unsupportedIfMissing(error) }
    }
    sending = task
    await task.value
    if sending == task { sending = nil }
  }

  private func merge(_ fields: [String: QuestionDraftField]) {
    var next = state
    for field in form.fields {
      guard let remote = fields[field.key], field.key != focused, !pending.contains(field.key) else { continue }
      next.apply(remote, to: field)
    }
    if next != state { state = next }
    persist()
  }

  private func persist() {
    guard !cleared else { return }
    if state == QuestionDraftState(), pending.isEmpty { return store.remove(form.sessionID, form.id) }
    store.save(.init(state: state, pending: pending, savedAt: .now), form.sessionID, form.id)
  }

  private func unsupportedIfMissing(_ error: any Error) {
    switch error {
    case ClientError.http(404), ClientError.rpc("rpc.unavailable"), ClientError.rpc("rpc.method_not_found"):
      unsupported = true
    default: break
    }
  }
}

private extension QuestionDraftState {
  func field(of key: String, in form: PendingForm) -> QuestionDraftField? {
    form.fields.first { $0.key == key }.map(field)
  }
}

/// Every pending form's draft of one server, so a card that leaves the screen (another session, the app closed)
/// finds its answers when it comes back.
@MainActor public final class QuestionDrafts {
  private var syncs: [String: QuestionDraftSync] = [:]
  private let transport: any QuestionDraftTransport
  private let store: QuestionDraftStore
  private let debounce: Duration
  /// Tells this device's own changes apart in `updated` events.
  public let client = UUID().uuidString

  public init(transport: any QuestionDraftTransport, store: QuestionDraftStore, debounce: Duration = .milliseconds(600)) {
    self.transport = transport
    self.store = store
    self.debounce = debounce
  }

  private static var shared: [String: QuestionDrafts] = [:]
  /// One per server for the app's lifetime.
  public static func shared(for client: OpenCodeClient) -> QuestionDrafts {
    let server = client.configuration.url.absoluteString
    if let drafts = shared[server] { return drafts }
    let drafts = QuestionDrafts(transport: client, store: QuestionDraftStore(server: server))
    shared[server] = drafts
    return drafts
  }

  public func sync(_ form: PendingForm) -> QuestionDraftSync {
    let key = form.sessionID + "\u{0}" + form.id
    if let sync = syncs[key] { return sync }
    let sync = QuestionDraftSync(form: form, transport: transport, store: store, client: client, debounce: debounce)
    syncs[key] = sync
    return sync
  }

  /// `rpc.custom.question-drafts.updated`.
  public func updated(sessionID: String, requestID: String, cleared: Bool, client: String?) async {
    guard let sync = syncs[sessionID + "\u{0}" + requestID] else {
      if cleared { store.remove(sessionID, requestID) }
      return
    }
    await sync.remote(cleared: cleared, client: client)
  }

  /// The event stream reconnected for this session.
  public func reconnected(sessionID: String) async {
    for sync in syncs.values where sync.form.sessionID == sessionID { await sync.reconnected() }
  }

  /// The session's pending forms: drafts of forms that are no longer pending (answered, dismissed, expired) go.
  public func retain(sessionID: String, pending: Set<String>) {
    for (key, sync) in syncs where sync.form.sessionID == sessionID && !pending.contains(sync.form.id) {
      sync.forget()
      syncs[key] = nil
    }
  }
}
