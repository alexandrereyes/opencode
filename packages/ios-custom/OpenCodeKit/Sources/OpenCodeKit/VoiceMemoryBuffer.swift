import CryptoKit
import Foundation

public enum VoiceMemoryOperation: Codable, Sendable, Equatable, Identifiable {
  case turn(VoiceMemoryTurn), end(String)
  public var id: String { switch self { case .turn(let turn): turn.id; case .end(let id): "end:" + id } }
}

public struct VoiceMemorySnapshot: Codable, Sendable, Equatable {
  public var version = 1
  public var pending: [VoiceMemoryOperation] = []
  public var seenIDs: Set<String> = []
  public var context = VoiceMemoryContext()
  public init() {}
}

public enum VoiceMemoryBufferError: Error, LocalizedError {
  case invalidTurn, version, order
  public var errorDescription: String? {
    "Não foi possível atualizar o arquivo local da conversa por voz. Os dados pendentes foram preservados."
  }
}

/// One serial owner per server. An operation reaches the network only after its
/// atomic protected file replacement completes; passwords are never stored here.
public actor VoiceMemoryBuffer {
  public nonisolated let file: URL
  private var loaded: VoiceMemorySnapshot?
  public init(server: String, root: URL? = nil) {
    let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OpenCode/VoiceMemory", isDirectory: true)
    let name = SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined()
    file = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("global.json")
  }
  public func snapshot() throws -> VoiceMemorySnapshot {
    if let loaded { return loaded }
    guard FileManager.default.fileExists(atPath: file.path) else { loaded = .init(); return .init() }
    let value = try JSONDecoder().decode(VoiceMemorySnapshot.self, from: Data(contentsOf: file))
    guard value.version == 1 else { throw VoiceMemoryBufferError.version }
    loaded = value
    return value
  }
  public func append(_ turn: VoiceMemoryTurn) throws {
    guard !turn.id.isEmpty, turn.id.utf16.count <= 200, turn.text.utf16.count <= 64_000,
      turn.at.isFinite, turn.at >= 0 else { throw VoiceMemoryBufferError.invalidTurn }
    var value = try snapshot()
    guard value.seenIDs.insert(turn.id).inserted else { return }
    value.pending.append(.turn(turn))
    if !value.context.turns.contains(where: { $0.id == turn.id }) { value.context.turns.append(turn) }
    try save(value)
  }
  public func end(_ callID: String) throws {
    var value = try snapshot()
    let operation = VoiceMemoryOperation.end(callID)
    guard value.seenIDs.insert(operation.id).inserted else { return }
    value.pending.append(operation)
    try save(value)
  }
  public func acknowledge(_ ids: [String]) throws {
    var value = try snapshot()
    guard Array(value.pending.prefix(ids.count).map(\.id)) == ids else { throw VoiceMemoryBufferError.order }
    value.pending.removeFirst(ids.count)
    try save(value)
  }
  public func cache(_ context: VoiceMemoryContext, observedIDs: Set<String>? = nil) throws {
    var value = try snapshot()
    let arrived = observedIDs.map { ids in value.context.turns.filter { !ids.contains($0.id) } } ?? []
    value.context = context
    var seen = Set(context.turns.map(\.id))
    for turn in arrived where seen.insert(turn.id).inserted { value.context.turns.append(turn) }
    for case .turn(let turn) in value.pending where seen.insert(turn.id).inserted {
      value.context.turns.append(turn)
    }
    try save(value)
  }
  private func save(_ value: VoiceMemorySnapshot) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
    try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try JSONEncoder().encode(value).write(to: file, options: .atomic)
    #endif
    loaded = value
  }
}

public actor VoiceMemoryService {
  public let buffer: VoiceMemoryBuffer
  private let client: OpenCodeClient
  public private(set) var status: VoiceMemoryStatus = .offline
  private var supported: Bool?
  private var draining: Task<Bool, Never>?
  public init(client: OpenCodeClient, buffer: VoiceMemoryBuffer) { self.client = client; self.buffer = buffer }

  public func prepare() async -> VoiceMemoryContext? {
    do {
      guard try await probe(force: true) else { return nil }
      let observed = Set(try await buffer.snapshot().context.turns.map(\.id))
      let context = try await client.voiceMemoryContext()
      guard context.version == 2, context.scope == "global" else { supported = false; status = .unsupported; return nil }
      try await buffer.cache(context, observedIDs: observed)
      status = .available
      return try await buffer.snapshot().context
    } catch { unavailable(error); return nil }
  }
  public func flush() async -> Bool {
    if let draining { return await draining.value }
    let task = Task { await drain() }
    draining = task
    defer { draining = nil }
    return await task.value
  }
  public func cancel() async {
    draining?.cancel()
    _ = await draining?.value
  }
  private func probe(force: Bool = false) async throws -> Bool {
    if !force, let supported { return supported }
    let info = try await client.voiceMemoryInfo()
    supported = info.supported
    status = info.supported ? .available : .unsupported
    return info.supported
  }
  private func drain() async -> Bool {
    do {
      guard try await probe() else { return false }
      while !Task.isCancelled, let first = try await buffer.snapshot().pending.first {
        switch first {
        case .end:
          try await client.endVoiceMemory()
          try await buffer.acknowledge([first.id])
        case .turn:
          let pending = try await buffer.snapshot().pending
          let batch = pending.prefix(128).prefix { if case .turn = $0 { true } else { false } }
          let turns = batch.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
          try await client.appendVoiceMemory(turns)
          try await buffer.acknowledge(turns.map(\.id))
        }
      }
      return !Task.isCancelled
    } catch { unavailable(error); return false }
  }
  private func unavailable(_ error: any Error) {
    if case ClientError.rpc(let code) = error, ["rpc.unavailable", "rpc.method_not_found"].contains(code) {
      supported = false; status = .unsupported
    } else if case ClientError.http(404) = error {
      supported = false; status = .unsupported
    } else { supported = nil; status = .offline }
  }
}
