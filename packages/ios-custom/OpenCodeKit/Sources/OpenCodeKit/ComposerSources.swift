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
  public var id: String { "\(token.kind.rawValue):\(token.id)" }
  public init(
    section: String, title: String, subtitle: String = "", icon: String, token: ComposerToken
  ) {
    self.section = section
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.token = token
  }
}
public struct ComposerSources: Sendable {
  public var commands: [ComposerCommand] = []
  public var skills: [ComposerSkill] = []
  public var references: [ComposerReference] = []
  public var snippets: [ComposerSnippet] = []
  public init() {}
  public static func matches(_ query: String, _ values: String...) -> Bool {
    let query = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    return query.isEmpty
      || values.contains {
        $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(
          query)
      }
  }
  public func suggestions(
    _ trigger: ComposerTrigger, agents: [AgentInfo] = [],
    files: [ComposerFile] = [], sessions: [Session] = [], current: String = "", server: String = "",
    directory: String = "", project: String? = nil
  ) -> [ComposerSuggestion] {
    let query = trigger.query
    switch trigger.character {
    case "@":
      return files.filter { Self.matches(query, $0.path) }.map {
        .init(
          section: "Arquivos", title: $0.path, icon: $0.type == "directory" ? "folder" : "doc",
          token: .init(
            kind: .file, id: $0.path, text: "@\($0.path)",
            value: (directory.hasSuffix("/") ? directory : directory + "/") + $0.path))
      }
        + sessions.filter {
          $0.id != current && $0.parentID == nil && Self.matches(query, $0.title ?? "", $0.id)
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
        + agents.filter {
          $0.hidden != true && $0.mode != "primary" && Self.matches(query, $0.name, $0.id)
        }.map {
          .init(
            section: "Agentes", title: $0.name, icon: "agent",
            token:
              .init(kind: .agent, id: $0.id, text: "@\($0.name)"))
        }
        + references.filter {
          $0.hidden != true && Self.matches(query, $0.name, $0.description ?? "")
        }.map {
          .init(
            section: "Referências", title: $0.name, subtitle: $0.description ?? "", icon: "folder",
            token: .init(kind: .reference, id: $0.name, text: "@\($0.name)", value: $0.path))
        }
    case "$":
      return skills.filter { Self.matches(query, $0.name, $0.description ?? "") }.map {
        skill($0, prefix: "$")
      }
    case "#":
      var merged: [String: ComposerSnippet] = [:]
      for snippet in snippets where snippet.project == nil || snippet.project == project {
        let key = snippet.name.lowercased()
        if merged[key] == nil || snippet.project != nil { merged[key] = snippet }
      }
      return merged.values.filter {
        Self.matches(query, $0.name, $0.description, $0.aliases.joined(separator: " "))
      }
      .sorted { $0.name < $1.name }.map {
        .init(
          section: "Snippets", title: "#\($0.name)", subtitle: $0.description, icon: "number",
          token: .init(kind: .snippet, id: $0.id, text: "#\($0.name)", value: $0.content))
      }
    case "/":
      let local = [
        ("compact", "Resume a conversa para liberar contexto"),
        ("model", "Escolher modelo e esforço"),
        ("agent", "Escolher agente"),
      ]
      let names = Set(commands.map(\.name) + local.map(\.0))
      return commands.filter { item in
        !local.contains { $0.0 == item.name }
          && Self.matches(query, item.name, item.description ?? "")
      }.map {
        .init(
          section: "Comandos", title: "/\($0.name)", subtitle: $0.description ?? "",
          icon: "slash.circle",
          token: .init(kind: .command, id: $0.name, text: "/\($0.name)", value: "backend"))
      }
        + local.filter { item in Self.matches(query, item.0, item.1) }.map {
          .init(
            section: "Comandos", title: "/\($0.0)", subtitle: $0.1, icon: "slash.circle",
            token: .init(kind: .command, id: $0.0, text: "/\($0.0)", value: "client"))
        }
        + skills.filter {
          $0.slash == true && !names.contains($0.name)
            && Self.matches(query, $0.name, $0.description ?? "")
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
    let response: DataResponse<[Session]> = try await get(
      "/api/session",
      query: [
        .init(name: "parentID", value: "null"), .init(name: "order", value: "desc"),
        .init(name: "limit", value: search.isEmpty ? "10" : "30"),
      ]
        + (search.isEmpty ? [] : [.init(name: "search", value: search)]))
    return response.data
  }
}
