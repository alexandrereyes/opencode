import Foundation
import Observation

/// A saved text the composer inserts with `#name` and expands on send (`custom.snippets`; contract and rules:
/// `packages/plugin-app-custom/docs/snippets.md`). `project` absent: global.
public struct Snippet: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var description: String
  public var aliases: [String]
  public var content: String
  public var project: String?

  /// The order of the former `ComposerSnippet`'s memberwise initializer.
  public init(
    id: String = Snippet.newID(), name: String = "", aliases: [String] = [], description: String = "",
    content: String = "", project: String? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.aliases = aliases
    self.content = content
    self.project = project
  }

  /// The plugin takes any non-empty ID; the apps, like the former web, use a lowercase UUID.
  public static func newID() -> String { UUID().uuidString.lowercased() }
  /// Emitted by `save` and `remove` on any Location: every client reloads the whole catalog.
  public static let updatedEvent = "rpc.custom.snippets.updated"
}

/// The composer reads the same records.
public typealias ComposerSnippet = Snippet

// MARK: Rules

/// A problem the editor shows under a field while Alexandre types; the plugin refuses the same ones on `save`.
public struct SnippetIssue: Equatable, Sendable {
  public enum Field: Hashable, Sendable {
    case name
    case alias(String)
    case content
  }
  public let field: Field
  public let message: String
  public init(_ field: Field, _ message: String) {
    self.field = field
    self.message = message
  }
}

/// The plugin's rules (`src/snippets/rules.ts`): names and aliases have letters (accented ones too), digits, `-` and
/// `_`, and every one of them is unique in its scope (the global snippets, or one project's), ignoring case.
public enum SnippetRules {
  public static let formatHint = "Sem espaços nem #, @, $. Use letras, números, - e _."

  /// `^[\p{L}\p{M}\p{N}_-]+$`, like the plugin.
  public static func isHandle(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
      if scalar == "_" || scalar == "-" { return true }
      switch scalar.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
        .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
        return true
      default: return false
      }
    }
  }

  /// The comparison key of a handle: NFC, lowercased.
  public static func key(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }

  /// Every problem of `snippet` against `catalog`, in field order. `projects` names the scope in the messages.
  public static func issues(_ snippet: Snippet, in catalog: [Snippet], projects: [Project] = []) -> [SnippetIssue] {
    let place = place(snippet.project, projects: projects)
    let others = catalog.filter { $0.id != snippet.id && $0.project == snippet.project }
    func owner(_ value: String) -> Snippet? {
      others.first { ([$0.name] + $0.aliases).contains { key($0) == key(value) } }
    }
    var result: [SnippetIssue] = []
    if snippet.name.isEmpty {
      result.append(.init(.name, "Dê um nome ao snippet."))
    } else if !isHandle(snippet.name) {
      result.append(.init(.name, formatHint))
    } else if let other = owner(snippet.name) {
      result.append(.init(.name, key(other.name) == key(snippet.name)
        ? "Já existe #\(other.name) \(place)."
        : "“\(snippet.name)” já é atalho de #\(other.name) \(place)."))
    }
    var seen: Set<String> = [key(snippet.name)]
    for alias in snippet.aliases {
      if !isHandle(alias) {
        result.append(.init(.alias(alias), "O atalho “\(alias)” só pode ter letras, números, - e _."))
      } else if !seen.insert(key(alias)).inserted {
        result.append(.init(.alias(alias), "O atalho “\(alias)” repete o nome ou outro atalho."))
      } else if let other = owner(alias) {
        result.append(.init(.alias(alias), "O atalho “\(alias)” já é usado por #\(other.name) \(place)."))
      }
    }
    if snippet.content.allSatisfy(\.isWhitespace) {
      result.append(.init(.content, "O conteúdo não pode ficar vazio."))
    }
    return result
  }

  /// The global snippet a project snippet replaces in that project's `#`, if any.
  public static func overridden(_ snippet: Snippet, in catalog: [Snippet]) -> Snippet? {
    guard snippet.project != nil else { return nil }
    return catalog.first { $0.project == nil && $0.id != snippet.id && key($0.name) == key(snippet.name) }
  }

  /// "em opencode2", "nos globais" or, for a project the server no longer has, "neste projeto".
  public static func place(_ project: String?, projects: [Project]) -> String {
    guard let project else { return "nos globais" }
    return projects.first { $0.id == project }.map { "em \($0.displayName)" } ?? "neste projeto"
  }
}

// MARK: Server

/// `save` refused the snippet (`conflict` or `invalid`), with the editor's message for the field it names.
public struct SnippetSaveError: Error, LocalizedError, Equatable, Sendable {
  public let issue: SnippetIssue
  public var errorDescription: String? { issue.message }

  /// The `RpcError` body's `type` and `data`; nil for any other failure.
  static func decode(type: String, data: JSONValue?, snippet: Snippet, projects: [Project]) -> Self? {
    let fields = data?.object ?? [:]
    let place = SnippetRules.place(snippet.project, projects: projects)
    let value = fields["value"]?.string ?? snippet.name
    switch type {
    case "conflict":
      let existing = fields["existing"]?.string ?? snippet.name
      if fields["field"]?.string == "alias" {
        return .init(issue: .init(.alias(value), "O atalho “\(value)” já é usado por #\(existing) \(place)."))
      }
      return .init(issue: .init(.name, SnippetRules.key(existing) == SnippetRules.key(value)
        ? "Já existe #\(existing) \(place)."
        : "“\(value)” já é atalho de #\(existing) \(place)."))
    case "invalid":
      let duplicate = fields["reason"]?.string == "duplicate"
      if fields["field"]?.string == "aliases" {
        return .init(issue: .init(.alias(value), duplicate
          ? "O atalho “\(value)” repete o nome ou outro atalho."
          : "O atalho “\(value)” só pode ter letras, números, - e _."))
      }
      return .init(issue: .init(.name, SnippetRules.formatHint))
    default: return nil
    }
  }
}

extension OpenCodeClient {
  /// The whole catalog, every scope (any Location answers with the same one).
  public func snippets() async throws -> [Snippet] {
    struct Output: Decodable { let items: [Snippet] }
    let output: Output = try await rpc("custom.snippets", "list", input: Empty())
    return output.items
  }

  /// Creates or replaces by ID. Throws `SnippetSaveError` when the plugin refuses it.
  @discardableResult public func saveSnippet(_ snippet: Snippet, projects: [Project] = []) async throws -> Snippet {
    var request = request("/api/rpc/custom.snippets/save")
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(RPCInput(input: snippet))
    let (data, response) = try await exchange(request)
    struct Failure: Decodable {
      let _tag: String
      let type: String
      let data: JSONValue?
    }
    if (response as? HTTPURLResponse)?.statusCode == 400,
      let failure = try? JSONDecoder().decode(Failure.self, from: data), failure._tag == "RpcError",
      let error = SnippetSaveError.decode(type: failure.type, data: failure.data, snippet: snippet, projects: projects)
    {
      throw error
    }
    return try JSONDecoder().decode(RPCOutput<Snippet>.self, from: try checked(data, response)).output
  }

  /// Idempotent: an unknown ID succeeds.
  public func removeSnippet(_ id: String) async throws {
    struct Input: Encodable { let id: String }
    let _: JSONValue = try await rpc("custom.snippets", "remove", input: Input(id: id))
  }
}

// MARK: Catalog

/// The server's catalog for one connection, shared by Ajustes and every composer's `#`: it reloads on
/// `rpc.custom.snippets.updated` and after a reconnection (events sent while disconnected are lost).
@MainActor @Observable public final class SnippetCatalog {
  public private(set) var items: [Snippet] = []
  public private(set) var loaded = false
  public private(set) var loading = false
  /// The last load failed; `items` keeps what was known.
  public private(set) var failed = false
  /// Bumps on every change of `items`, so composers can tell their cached copy is stale.
  public private(set) var revision = 0
  @ObservationIgnored private let client: OpenCodeClient
  @ObservationIgnored private var again = false

  public init(client: OpenCodeClient) { self.client = client }

  /// Loads now; a call while loading runs one more load after it, so the last answer is never older than the call.
  public func load() async {
    guard !loading else {
      again = true
      return
    }
    loading = true
    defer { loading = false }
    repeat {
      again = false
      do {
        let next = try await client.snippets()
        failed = false
        loaded = true
        if next != items {
          items = next
          revision += 1
        }
      } catch {
        if !Task.isCancelled { failed = true }
      }
    } while again && !Task.isCancelled
  }

  public func loadIfNeeded() async {
    if !loaded { await load() }
  }

  /// Feeds a server event type; returns once a reload it caused has finished.
  public func receive(_ type: String) async {
    guard type == Snippet.updatedEvent, loaded || loading else { return }
    await load()
  }

  @discardableResult public func save(_ snippet: Snippet, projects: [Project] = []) async throws -> Snippet {
    let saved = try await client.saveSnippet(snippet, projects: projects)
    items = items.filter { $0.id != saved.id } + [saved]
    revision += 1
    return saved
  }

  public func remove(_ id: String) async throws {
    try await client.removeSnippet(id)
    guard items.contains(where: { $0.id == id }) else { return }
    items.removeAll { $0.id == id }
    revision += 1
  }

  #if DEBUG
  /// Fixtures without a server start from a known catalog.
  public func useFixture(_ value: [Snippet]) {
    items = value
    loaded = true
    revision += 1
  }
  #endif
}

// MARK: Library

/// Ajustes ▸ Snippets: which scopes the list shows.
public enum SnippetFilter: String, CaseIterable, Sendable {
  case all = "Todos"
  case global = "Globais"
  case projects = "Projetos"
}

public struct SnippetSection: Identifiable, Equatable, Sendable {
  public enum Scope: Hashable, Sendable {
    case global
    case project(Project)
    /// A project the server no longer lists: its snippets stay, under "Projeto removido".
    case removed(String)
  }
  public let scope: Scope
  public let items: [Snippet]
  public var id: String {
    switch scope {
    case .global: "global"
    case .project(let project): "project:" + project.id
    case .removed(let id): "removed:" + id
    }
  }
  public var title: String {
    switch scope {
    case .global: "Globais"
    case .project(let project): project.displayName
    case .removed: "Projeto removido"
    }
  }
}

public enum SnippetLibrary {
  /// Globais first, then each project by name, then removed projects; items by name. `query` matches the name,
  /// aliases and description, folded (case and accents).
  public static func sections(
    _ items: [Snippet], projects: [Project], filter: SnippetFilter = .all, query: String = ""
  ) -> [SnippetSection] {
    let words = TextFolding.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    let matching = items.filter { snippet in
      switch filter {
      case .global: guard snippet.project == nil else { return false }
      case .projects: guard snippet.project != nil else { return false }
      case .all: break
      }
      let text = TextFolding.fold(([snippet.name, snippet.description] + snippet.aliases).joined(separator: " "))
      return words.allSatisfy { text.contains($0) }
    }
    let sorted = { (list: [Snippet]) in
      list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    let known = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let grouped = Dictionary(grouping: matching.filter { $0.project != nil }, by: { $0.project ?? "" })
    let global = matching.filter { $0.project == nil }
    let present = grouped.keys.compactMap { known[$0] }
      .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    let removed = grouped.keys.filter { known[$0] == nil }.sorted()
    return (global.isEmpty ? [] : [SnippetSection(scope: .global, items: sorted(global))])
      + present.map { SnippetSection(scope: .project($0), items: sorted(grouped[$0.id] ?? [])) }
      + removed.map { SnippetSection(scope: .removed($0), items: sorted(grouped[$0] ?? [])) }
  }

  /// A copy in the same scope with a new ID and a free name (`revisar-copia`, `revisar-copia-2`…); aliases are
  /// dropped, as they would collide with the original's.
  public static func duplicate(_ snippet: Snippet, in catalog: [Snippet]) -> Snippet {
    Snippet(
      name: freeName(snippet.name + "-copia", project: snippet.project, in: catalog),
      description: snippet.description, content: snippet.content, project: snippet.project)
  }

  /// A new snippet with `content` (selected text, a sent message), its scope and a free name taken from its first
  /// words: "Revise o diff atual…" → `revise-o-diff`.
  public static func draft(content: String, project: String?, in catalog: [Snippet]) -> Snippet {
    let words = content.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(3)
      .map { $0.lowercased() }
    let base = words.isEmpty ? "snippet" : words.joined(separator: "-")
    return Snippet(name: freeName(String(base.prefix(40)), project: project, in: catalog), content: content,
      project: project)
  }

  /// `base`, or `base-2`, `base-3`… until no name or alias of the scope has it.
  public static func freeName(_ base: String, project: String?, in catalog: [Snippet]) -> String {
    let taken = Set(catalog.filter { $0.project == project }.flatMap { [$0.name] + $0.aliases }
      .map(SnippetRules.key))
    guard taken.contains(SnippetRules.key(base)) else { return base }
    return (2...).lazy.map { "\(base)-\($0)" }.first { !taken.contains(SnippetRules.key($0)) }!
  }
}
