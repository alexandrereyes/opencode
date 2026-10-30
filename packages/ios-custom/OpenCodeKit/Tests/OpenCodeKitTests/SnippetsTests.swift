import Foundation
import Testing

@testable import OpenCodeKit

/// Ajustes ▸ Snippets: the plugin's rules (`plugin-app-custom/test/snippets.test.ts` has the same cases), the
/// library's grouping, filter and duplicate, and the catalog's reload on `rpc.custom.snippets.updated`.
@Suite struct SnippetsTests {
  static let projects = try! JSONDecoder().decode([Project].self, from: Data("""
    [{"id":"prj_op","canonical":"/Users/a/Dev/opencode2","name":"opencode2","sandboxes":[]},
     {"id":"prj_av","canonical":"/Users/a/Dev/abacato-v2","name":"abacato-v2","sandboxes":[]}]
    """.utf8))

  static let catalog = [
    Snippet(id: "g1", name: "revisar", aliases: ["review", "cr"], description: "Revisa o diff", content: "Revise."),
    Snippet(id: "g2", name: "resumo", content: "Resuma."),
    Snippet(id: "p1", name: "deploy", aliases: ["swarm"], content: "Faça o deploy.", project: "prj_op"),
    Snippet(id: "p2", name: "revisar", description: "Com as regras do custom", content: "Revise.", project: "prj_op"),
    Snippet(id: "x1", name: "antigo", content: "Texto.", project: "prj_gone"),
  ]

  static func issues(_ snippet: Snippet) -> [String] {
    SnippetRules.issues(snippet, in: catalog, projects: projects).map(\.message)
  }

  @Test func handlesTakeAccentedLettersDigitsHyphenAndUnderscore() {
    for value in ["revisão_2-pr", "código", "revisa\u{303}o", "ça", "x1"] { #expect(SnippetRules.isHandle(value)) }
    for value in ["", "a.b", "a@b", "a$b", "a#b", "a/b", "two words", "ação!"] { #expect(!SnippetRules.isHandle(value)) }
  }

  @Test func issuesNameEveryFieldInPortuguese() {
    #expect(Self.issues(Snippet(name: "revisar código", content: "x")) == [SnippetRules.formatHint])
    #expect(Self.issues(Snippet(name: "", content: "x")) == ["Dê um nome ao snippet."])
    #expect(Self.issues(Snippet(name: "novo", content: "  \n")) == ["O conteúdo não pode ficar vazio."])
    #expect(Self.issues(Snippet(name: "novo", aliases: ["a b", "Novo", "x", "X"], content: "x")) == [
      "O atalho “a b” só pode ter letras, números, - e _.",
      "O atalho “Novo” repete o nome ou outro atalho.",
      "O atalho “X” repete o nome ou outro atalho.",
    ])
  }

  @Test func handlesAreUniqueInTheirScopeBothWays() {
    #expect(Self.issues(Snippet(name: "REVISAR", content: "x")) == ["Já existe #revisar nos globais."])
    #expect(Self.issues(Snippet(name: "review", content: "x")) == ["“review” já é atalho de #revisar nos globais."])
    #expect(Self.issues(Snippet(name: "novo", aliases: ["Resumo"], content: "x"))
      == ["O atalho “Resumo” já é usado por #resumo nos globais."])
    #expect(Self.issues(Snippet(name: "Deploy", content: "x", project: "prj_op")) == ["Já existe #deploy em opencode2."])
    #expect(Self.issues(Snippet(name: "deploy", content: "x", project: "prj_gone")).isEmpty)
    // Other scopes are free, and a snippet never collides with itself.
    #expect(Self.issues(Snippet(name: "swarm", content: "x")).isEmpty)
    #expect(Self.issues(Snippet(id: "g1", name: "revisar", aliases: ["review", "cr", "rv"], content: "x")).isEmpty)
    #expect(SnippetRules.overridden(Self.catalog[3], in: Self.catalog)?.id == "g1")
    #expect(SnippetRules.overridden(Self.catalog[0], in: Self.catalog) == nil)
  }

  @Test func sectionsGroupFilterAndSearch() {
    let all = SnippetLibrary.sections(Self.catalog, projects: Self.projects)
    #expect(all.map(\.title) == ["Globais", "opencode2", "Projeto removido"])
    #expect(all.map { $0.items.map(\.id) } == [["g2", "g1"], ["p1", "p2"], ["x1"]])
    #expect(SnippetLibrary.sections(Self.catalog, projects: Self.projects, filter: .global).map(\.title) == ["Globais"])
    #expect(SnippetLibrary.sections(Self.catalog, projects: Self.projects, filter: .projects).map(\.title)
      == ["opencode2", "Projeto removido"])
    // Name, aliases and description, ignoring case and accents.
    let found = SnippetLibrary.sections(Self.catalog, projects: Self.projects, query: "REGRAS")
    #expect(found.flatMap(\.items).map(\.id) == ["p2"])
    #expect(SnippetLibrary.sections(Self.catalog, projects: Self.projects, query: "swárm").flatMap(\.items).map(\.id)
      == ["p1"])
    #expect(SnippetLibrary.sections(Self.catalog, projects: Self.projects, query: "nada").isEmpty)
  }

  @Test func duplicateAndDraftTakeAFreeNameInTheSameScope() {
    let copy = SnippetLibrary.duplicate(Self.catalog[0], in: Self.catalog)
    #expect(copy.id != "g1" && copy.name == "revisar-copia" && copy.aliases.isEmpty && copy.project == nil)
    #expect(SnippetLibrary.duplicate(Self.catalog[0], in: Self.catalog + [copy]).name == "revisar-copia-2")
    #expect(SnippetRules.issues(copy, in: Self.catalog).isEmpty)
    let draft = SnippetLibrary.draft(content: "Revise o diff atual, por favor.", project: "prj_op", in: Self.catalog)
    #expect(draft.name == "revise-o-diff" && draft.project == "prj_op" && draft.content == "Revise o diff atual, por favor.")
    #expect(SnippetLibrary.draft(content: "Deploy!", project: "prj_op", in: Self.catalog).name == "deploy-2")
    #expect(SnippetLibrary.draft(content: "...", project: nil, in: []).name == "snippet")
  }

  /// A server that keeps a catalog, answers `list`, `save` and `remove` like the plugin and counts list reads.
  final class Server: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Snippet] = []
    private(set) var lists = 0
    func set(_ value: [Snippet]) { lock.withLock { items = value } }
    var client: OpenCodeClient {
      OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) { [self] request in
        let url = try #require(request.url)
        let body = try request.httpBody.flatMap { try JSONDecoder().decode(JSONValue.self, from: $0) }
        let input = body?.object?["input"]
        let (status, json): (Int, String) = lock.withLock {
          switch url.lastPathComponent {
          case "list":
            lists += 1
            let data = String(decoding: try! JSONEncoder().encode(items), as: UTF8.self)
            return (200, #"{"output":{"items":\#(data)}}"#)
          case "save":
            let snippet = try! JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(input))
            if items.contains(where: { $0.id != snippet.id && $0.project == snippet.project && $0.name == snippet.name }) {
              return (400, #"{"_tag":"RpcError","type":"conflict","message":"taken","data":{"name":"\#(snippet.name)","field":"name","value":"\#(snippet.name)","existing":"\#(snippet.name)"}}"#)
            }
            if snippet.name.contains(" ") {
              return (400, #"{"_tag":"RpcError","type":"invalid","message":"bad","data":{"field":"name","reason":"format","value":"\#(snippet.name)"}}"#)
            }
            items = items.filter { $0.id != snippet.id } + [snippet]
            return (200, #"{"output":\#(String(decoding: try! JSONEncoder().encode(snippet), as: UTF8.self))}"#)
          case "remove":
            let id = input?.object?["id"]?.string
            items.removeAll { $0.id == id }
            return (200, #"{"output":{}}"#)
          default: return (404, "{}")
          }
        }
        return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
      }
    }
  }

  @MainActor @Test func catalogReloadsOnTheUpdatedEventOnly() async throws {
    let server = Server()
    server.set([Self.catalog[0]])
    let catalog = SnippetCatalog(client: server.client)
    // Not loaded yet: an event alone does not fetch.
    await catalog.receive(Snippet.updatedEvent)
    #expect(server.lists == 0)
    await catalog.loadIfNeeded()
    #expect(catalog.items.map(\.id) == ["g1"] && server.lists == 1)
    let revision = catalog.revision
    // Another client saves: the event reloads, other events do not.
    server.set([Self.catalog[0], Self.catalog[1]])
    await catalog.receive("session.updated")
    #expect(server.lists == 1)
    await catalog.receive(Snippet.updatedEvent)
    #expect(catalog.items.map(\.id) == ["g1", "g2"] && catalog.revision == revision + 1)
    // An unchanged answer keeps the revision, so composers keep their copy.
    await catalog.receive(Snippet.updatedEvent)
    #expect(catalog.revision == revision + 1)
  }

  @MainActor @Test func catalogSavesRemovesAndReadsTheRefusals() async throws {
    let server = Server()
    let catalog = SnippetCatalog(client: server.client)
    await catalog.load()
    try await catalog.save(Self.catalog[2], projects: Self.projects)
    #expect(catalog.items.map(\.id) == ["p1"])
    await #expect(throws: SnippetSaveError(issue: .init(.name, "Já existe #deploy em opencode2."))) {
      try await catalog.save(Snippet(id: "other", name: "deploy", content: "x", project: "prj_op"), projects: Self.projects)
    }
    await #expect(throws: SnippetSaveError(issue: .init(.name, SnippetRules.formatHint))) {
      try await catalog.save(Snippet(name: "dois nomes", content: "x"))
    }
    try await catalog.remove("p1")
    try await catalog.remove("p1")
    #expect(catalog.items.isEmpty)
  }

  @Test func olderServersConflictWithTheNameOnly() {
    let error = SnippetSaveError.decode(type: "conflict", data: .object(["name": .string("revisar")]),
      snippet: Snippet(name: "revisar", content: "x"), projects: [])
    #expect(error?.issue == .init(.name, "Já existe #revisar nos globais."))
    #expect(SnippetSaveError.decode(type: "rpc.internal", data: nil, snippet: Snippet(), projects: []) == nil)
  }

  @Test func wireOmitsAnAbsentProject() throws {
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(Snippet(id: "a", name: "a", content: "b")))
    #expect(json.object?["project"] == nil)
    #expect(json.object?.keys.sorted() == ["aliases", "content", "description", "id", "name"])
  }
}
