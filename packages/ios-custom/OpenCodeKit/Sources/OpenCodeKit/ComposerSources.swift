import Foundation

public struct ComposerCommand: Codable, Sendable {
  public let name: String
  public let description: String?
}
public struct ComposerSkill: Codable, Sendable {
  public let id: String
  public let name: String
  public let description: String?
  public let slash: Bool?
}
public struct ComposerReference: Codable, Sendable {
  public let name: String
  public let path: String
  public let description: String?
  public let hidden: Bool?
}
public struct ComposerFile: Codable, Sendable {
  public let path: String
  public let type: String
}
public struct ComposerSnippet: Codable, Sendable {
  public let id: String
  public let name: String
  public let aliases: [String]
  public let description: String
  public let content: String
  public let project: String?
}
public struct ComposerSuggestion: Sendable, Identifiable {
  public let section: String
  public let title: String
  public let subtitle: String
  public let icon: String
  public let token: ComposerToken
  public let aliases: [String]
  public var id: String { "\(token.kind.rawValue):\(token.id)" }
  public init(
    section: String, title: String, subtitle: String = "", icon: String, token: ComposerToken,
    aliases: [String] = []
  ) {
    self.section = section
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.token = token
    self.aliases = aliases
  }
}
public struct ComposerSources: Sendable {
  /// The server matches session titles with SQLite LIKE, which ignores case only for ASCII letters.
  /// With other cased letters (Ã, Í, Ç…), also search them lowered, uppercased and capitalized, so
  /// "SESSÃO" finds "Sessão" and "índice" finds "Índice". Accents are matched as typed.
  public static func caseVariants(_ query: String) -> [String] {
    guard query.unicodeScalars.contains(where: {
      !$0.isASCII && $0.properties.lowercaseMapping != $0.properties.uppercaseMapping
    }) else { return [query] }
    let lower = query.lowercased()
    var seen = Set<String>()
    return [query, lower, query.uppercased(), lower.prefix(1).uppercased() + lower.dropFirst()]
      .filter { seen.insert($0).inserted }
  }
  public var commands: [ComposerCommand] = []
  public var skills: [ComposerSkill] = []
  public var references: [ComposerReference] = []
  public var snippets: [ComposerSnippet] = []
  public init() {}
  public func newSessionDocument(_ document: ComposerDocument) -> ComposerDocument {
    guard document.text.hasPrefix("/"), document.validTokens.first?.start != 0,
      let word = document.text.split(whereSeparator: \.isWhitespace).first else { return document }
    let name = String(word.dropFirst())
    let local = ["compact", "btw"].contains(name)
    guard local || commands.contains(where: { $0.name == name && !["model", "agent"].contains(name) }) else { return document }
    return ComposerDocument(text: document.text, tokens: [
      .init(start: 0, end: word.utf16.count,
        token: .init(kind: .command, id: name, text: String(word), value: local ? "client" : "backend"))
    ] + document.tokens)
  }
  public func suggestions(
    _ trigger: ComposerTrigger, agents: [AgentInfo] = [],
    files: [ComposerFile] = [], sessions: [Session] = [], apps: [ComposerApp] = [],
    current: String = "", server: String = "", directory: String = "", project: String? = nil
  ) -> [ComposerSuggestion] {
    let query = normalize(trigger.query)
    let items = candidates(
      trigger.character, agents: agents, files: files, sessions: sessions, apps: apps,
      current: current, server: server, directory: directory, project: project
    )
    let ranked = items.enumerated().compactMap { index, item in
      rank(item, query: query).map { (item: item, rank: $0, index: index) }
    }
    return ranked.sorted { $0.rank == $1.rank ? $0.index < $1.index : $0.rank < $1.rank }.map(
      \.item)
  }
  private func rank(_ item: ComposerSuggestion, query: String) -> Int? {
    if query.isEmpty { return 0 }
    let basename =
      item.token.kind == .file ? [item.title.components(separatedBy: "/").last ?? ""] : []
    // Like the web, apps match only by name: every bundle ID or "Computer use" would match otherwise.
    let app = item.token.kind == .app
    let names = (app ? [item.title] : [item.token.id, String(item.token.text.dropFirst())] + item.aliases + basename)
      .map { normalize($0) }
    if names.contains(where: { $0.hasPrefix(query) }) { return 0 }
    if names.contains(where: { $0.contains(query) }) { return 1 }
    if !app && normalize(item.subtitle).contains(query) { return 2 }
    return nil
  }
  private func normalize(_ value: String) -> String { TextFolding.fold(value) }
  private func candidates(
    _ character: String, agents: [AgentInfo], files: [ComposerFile], sessions: [Session],
    apps: [ComposerApp], current: String, server: String, directory: String, project: String?
  ) -> [ComposerSuggestion] {
    switch character {
    case "!":
      // The token keeps the `@path` text the `@` panel used to insert, so the sent prompt is unchanged.
      return files.map {
        .init(
          section: "Arquivos", title: $0.path, icon: $0.type == "directory" ? "folder" : "doc",
          token: .init(
            kind: .file, id: $0.path, text: "@\($0.path)",
            value: (directory.hasSuffix("/") ? directory : directory + "/") + $0.path))
      }
    case "@":
      return sessions.filter {
          $0.id != current && $0.parentID == nil
        }.map {
          let title = $0.title ?? $0.id
          return .init(
            section: "Sessões", title: title, icon: "bubble",
            token:
              .init(
                kind: .session, id: $0.id, text: "@\(title)",
                detail: [
                  "id": .string($0.id), "title": .string(title), "server": .string(server),
                  "directory": .string($0.location.directory),
                ]))
        }
        + apps.map {
          .init(
            section: "Apps", title: $0.name,
            subtitle: $0.isSafariDevTools ? "Safari MCP" : "Computer use", icon: "desktopcomputer",
            token: $0.token)
        }
        + agents.filter {
          $0.hidden != true && $0.mode != "primary"
        }.map {
          .init(
            section: "Agentes", title: $0.name, icon: "agent",
            token:
              .init(kind: .agent, id: $0.id, text: "@\($0.name)"))
        }
        + references.filter {
          $0.hidden != true
        }.map {
          .init(
            section: "Referências", title: $0.name, subtitle: $0.description ?? "", icon: "folder",
            token: .init(kind: .reference, id: $0.name, text: "@\($0.name)", value: $0.path))
        }
    case "$":
      return skills.map {
        skill($0, prefix: "$")
      }
    case "#":
      var merged: [String: ComposerSnippet] = [:]
      for snippet in snippets where snippet.project == nil || snippet.project == project {
        let key = snippet.name.lowercased()
        if merged[key] == nil || snippet.project != nil { merged[key] = snippet }
      }
      return merged.values.sorted { $0.name < $1.name }.map {
        .init(
          section: "Snippets", title: "#\($0.name)", subtitle: $0.description, icon: "number",
          token: .init(kind: .snippet, id: $0.id, text: "#\($0.name)", value: $0.content),
          aliases: $0.aliases)
      }
    case "/":
      let local = [
        ("compact", "Resume a conversa para liberar contexto"),
        ("btw", "Pergunta paralela, sem salvar na conversa"),
        ("model", "Escolher modelo e esforço"),
        ("agent", "Escolher agente"),
      ]
      let names = Set(commands.map(\.name) + local.map(\.0))
      return commands.filter { item in
        !local.contains { $0.0 == item.name }
      }.map {
        .init(
          section: "Comandos", title: "/\($0.name)", subtitle: $0.description ?? "",
          icon: "slash.circle",
          token: .init(kind: .command, id: $0.name, text: "/\($0.name)", value: "backend"))
      }
        + local.map {
          .init(
            section: "Comandos", title: "/\($0.0)", subtitle: $0.1, icon: "slash.circle",
            token: .init(kind: .command, id: $0.0, text: "/\($0.0)", value: "client"))
        }
        + skills.filter {
          $0.slash == true && !names.contains($0.name)
        }
        .map { skill($0, prefix: "/") }
    default: return []
    }
  }
  private func skill(_ item: ComposerSkill, prefix: String) -> ComposerSuggestion {
    .init(
      section: "Skills", title: "\(prefix)\(item.name)", subtitle: item.description ?? "",
      icon: "sparkles",
      token: .init(kind: .skill, id: item.id, text: "\(prefix)\(item.name)"))
  }
}

extension OpenCodeClient {
  public func composerSources(directory: String) async throws -> ComposerSources {
    let query = [URLQueryItem(name: "location[directory]", value: directory)]
    async let commands: DataResponse<[ComposerCommand]> = get("/api/command", query: query)
    async let skills: DataResponse<[ComposerSkill]> = get("/api/skill", query: query)
    async let references: DataResponse<[ComposerReference]> = get("/api/reference", query: query)
    struct Snippets: Decodable { let items: [ComposerSnippet] }
    async let snippets: Snippets = rpc(
      "custom.snippets", "list", input: Empty(), directory: directory)
    var result = ComposerSources()
    result.commands = try await commands.data
    result.skills = try await skills.data
    result.references = try await references.data
    result.snippets = try await snippets.items
    return result
  }
  public func composerFiles(_ query: String, directory: String) async throws -> [ComposerFile] {
    let response: DataResponse<[ComposerFile]> = try await get(
      "/api/fs/find",
      query: [
        .init(name: "location[directory]", value: directory), .init(name: "query", value: query),
        .init(name: "limit", value: "20"),
      ])
    return response.data
  }
  public func composerSessions(_ search: String) async throws -> [Session] {
    let variants = ComposerSources.caseVariants(search)
    let lists = try await withThrowingTaskGroup(of: (Int, [Session]).self) { group in
      for (index, variant) in variants.enumerated() {
        group.addTask {
          let response: DataResponse<[Session]> = try await self.get(
            "/api/session",
            query: [
              .init(name: "parentID", value: "null"), .init(name: "order", value: "desc"),
              .init(name: "limit", value: variant.isEmpty ? "10" : "30"),
            ]
              + (variant.isEmpty ? [] : [.init(name: "search", value: variant)]))
          return (index, response.data)
        }
      }
      return try await group.reduce(into: [[Session]](repeating: [], count: variants.count)) {
        $0[$1.0] = $1.1
      }
    }
    guard lists.count > 1 else { return lists.first ?? [] }
    var seen = Set<String>()
    return lists.flatMap { $0 }.filter { seen.insert($0.id).inserted }
      .sorted { $0.time.updated > $1.time.updated }
  }
}
