import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OpenCodeKit

private let composerModel = ModelReference(
  id: "gpt-6-luna", providerID: "llm-proxy", variant: "low")
private func decodeComposer<T: Decodable>(_ json: String, _ type: T.Type) throws -> T {
  try JSONDecoder().decode(type, from: Data(json.utf8))
}
private func detected(_ text: String) -> ComposerTrigger? {
  ComposerTrigger.detect(in: .init(text: text), cursor: text.utf16.count)
}

@Test func atomicEditorOffsetsPreserveLegacyUTF16Cursors() {
  let token = ComposerToken(kind: .skill, id: "sample", text: "$sample")
  let document = ComposerDocument(text: "😀 $sample x $sample", tokens: [
    .init(start: 3, end: 10, token: token), .init(start: 13, end: 20, token: token),
  ])
  for cursor in [0, 2, 3, 10, 11, 12, 13, 20] {
    #expect(document.documentOffset(document.editorOffset(cursor)) == cursor)
  }
  #expect(document.editorOffset(7) == 4)
  #expect(document.editorOffset(18) == 8)
}

@Test func editorTriggerOnlyReadsTheCurrentWord() {
  let prefix = String(repeating: "long text\n", count: 1000) + "\u{FFFC} "
  let text = prefix + "$sam"
  let trigger = ComposerTrigger.detect(in: text as NSString, cursor: text.utf16.count)
  #expect(trigger?.query == "sam")
  #expect(trigger?.range == NSRange(location: prefix.utf16.count, length: 4))
  #expect(ComposerTrigger.detect(in: String(repeating: "a", count: 10_000) as NSString, cursor: 10_000) == nil)
  #expect(ComposerTrigger.detect(in: "hello /sam" as NSString, cursor: 10) == nil)
  #expect(ComposerTrigger.detect(in: "\u{FFFC}" as NSString, cursor: 1) == nil)
}

@Test func composerTriggerBoundariesAndSlashScope() {
  for marker in ["@", "$", "#"] {
    #expect(detected(marker)?.character == marker)
    #expect(detected("Olá \(marker)te")?.query == "te")
    #expect(detected("(\(marker)te")?.character == marker)
    #expect(detected("texto\(marker)te") == nil)
    #expect(detected("\(marker)teste ") == nil)
  }
  #expect(detected("/com")?.query == "com")
  #expect(detected(" /com") == nil)
  #expect(detected("a\n/com") == nil)
  #expect(detected("https://example.com") == nil)
  #expect(detected("e-mail@dominio.com") == nil)
  #expect(detected("Atualiza @docs/infra")?.query == "docs/infra")
  let token = ComposerToken(kind: .agent, id: "explore", text: "@Explore")
  #expect(
    ComposerTrigger.detect(
      in: .init(text: token.text, tokens: [.init(start: 0, end: 8, token: token)]), cursor: 4)
      == nil)
}

@Test func composerSourcesFilterByTypeAndDoNotExposeUnsupportedCommands() throws {
  var source = ComposerSources()
  source.skills = try decodeComposer(
    """
    [{"id":"check","name":"conversation-check","description":"Verificação ágil","slash":true},
     {"id":"review","name":"review","description":"Outro","slash":true},
     {"id":"hiddenSlash","name":"not-slash","slash":false}]
    """, [ComposerSkill].self)
  source.commands = try decodeComposer(
    """
    [{"name":"review","description":"Revisa alterações"}]
    """, [ComposerCommand].self)
  source.references = try decodeComposer(
    """
    [{"name":"effect","path":"/references/effect","description":"Biblioteca"},
     {"name":"private","path":"/private","hidden":true}]
    """, [ComposerReference].self)
  let slash = try #require(detected("/"))
  let suggestions = source.suggestions(slash)
  #expect(suggestions.map(\.token.id) == ["review", "compact", "btw", "model", "agent", "check"])
  #expect(suggestions.filter { $0.title == "/review" }.count == 1)
  #expect(
    !suggestions.contains {
      ["undo", "redo", "fork", "terminal", "export", "new"].contains($0.token.id)
    })
  #expect(source.suggestions(try #require(detected("$agil"))).map(\.token.id) == ["check"])
  #expect(source.suggestions(try #require(detected("@bib"))).map(\.token.id) == ["effect"])
  #expect(source.suggestions(try #require(detected("@private"))).isEmpty)
}

@Test func composerFilesSessionsAndAgentsFilterIndependently() throws {
  let source = ComposerSources()
  let files = try decodeComposer(
    "[{\"path\":\"docs/infra.md\",\"type\":\"file\"},{\"path\":\"src/index.ts\",\"type\":\"file\"}]",
    [ComposerFile].self)
  let agents = try decodeComposer(
    """
    [{"id":"explore","name":"Explore","mode":"subagent"},
    {"id":"build","name":"Build","mode":"primary"},
    {"id":"hidden","name":"Hidden","mode":"all","hidden":true}]
    """, [AgentInfo].self)
  let sessions = try decodeComposer(
    """
    [{"id":"ses_current","projectID":"p","title":"Infra atual","location":{"directory":"/repo"},"time":{"created":1,"updated":1}},
    {"id":"ses_other","projectID":"p","title":"Infra anterior","location":{"directory":"/repo"},"time":{"created":1,"updated":1}},
    {"id":"ses_child","projectID":"p","parentID":"ses_other","title":"Infra filha","location":{"directory":"/repo"},"time":{"created":1,"updated":1}}]
    """, [Session].self)
  let mentions = source.suggestions(
    try #require(detected("@")), agents: agents, files: files, sessions: sessions,
    current: "ses_current", directory: "/repo")
  #expect(mentions.map(\.token.id) == ["ses_other", "explore"])
  #expect(
    source.suggestions(
      try #require(detected("@infra")), agents: agents, files: files, sessions: sessions,
      current: "ses_current"
    ).map(\.section) == ["Sessões"])
  let all = source.suggestions(
    try #require(detected("&")), agents: agents, files: files, sessions: sessions,
    current: "ses_current", directory: "/repo")
  #expect(all.map(\.token.id) == ["docs/infra.md", "src/index.ts"])
  #expect(all.map(\.section) == ["Arquivos", "Arquivos"])
  let filtered = source.suggestions(
    try #require(detected("Veja &infra")), agents: agents, files: files, sessions: sessions,
    current: "ses_current", directory: "/repo")
  #expect(filtered.map(\.token.id) == ["docs/infra.md"])
  // The same token the `@` panel inserted before, so the prompt sent is unchanged.
  let token = try #require(all.first?.token)
  #expect(token == ComposerToken(kind: .file, id: "docs/infra.md", text: "@docs/infra.md", value: "/repo/docs/infra.md"))
  let request = PromptRequest(
    document: .init(text: "Veja \(token.text)", tokens: [.init(start: 5, end: 5 + token.text.utf16.count, token: token)]),
    delivery: .steer, agent: "build", model: composerModel)
  #expect(request.text == "Veja @docs/infra.md")
  #expect(request.files?.first?.object?["uri"] == .string("file:///repo/docs/infra.md"))
  #expect(
    request.files?.first?.object?["mention"]
      == .object(["start": .number(5), "end": .number(19), "text": .string("@docs/infra.md")]))
}

@Test func ampersandOpensFilesOnlyAtTheStartOrAfterWhitespace() {
  #expect(detected("&")?.character == "&")
  #expect(detected("&READ")?.query == "READ")
  #expect(detected("Veja &src/ind")?.query == "src/ind")
  #expect(detected("linha\n&doc")?.query == "doc")
  #expect(detected("tab\t&doc")?.character == "&")
  #expect(detected("Veja &READ")?.range == NSRange(location: 5, length: 5))
  // A lone `&` opens like the other markers; the space after it closes the panel without inserting anything.
  #expect(detected("Tom &")?.query == "")
  for prose in [
    "a &&", "a && b", "&&", "R&D", "P&G", "AT&T", "AT&", "https://x.dev/?a=1&b=2", "?a=1&b", "texto&amp;", "Tom&",
    "Tom & ", "Tom & Jerry", "arroz & feijão", "fim.&", "(&doc", "\"&doc", "'&doc", "[&doc", "😀&", "👍🏽&doc",
    "a &=", "&READ ", "e-mail&x",
  ] {
    #expect(detected(prose) == nil, "\(prose)")
  }
  // `!` is prose again.
  for prose in ["!", "!READ", "Veja !READ", "linha\n!doc", "ok!", "Pode arrumar!"] {
    #expect(detected(prose) == nil, "\(prose)")
  }
  // Editor text: tokens are U+FFFC, and the word scan restarts after them.
  #expect(ComposerTrigger.detect(in: "\u{FFFC}&" as NSString, cursor: 2) == nil)
  #expect(ComposerTrigger.detect(in: "\u{FFFC} &RE" as NSString, cursor: 5)?.query == "RE")
  #expect(ComposerTrigger.detect(in: "R&D" as NSString, cursor: 3) == nil)
  #expect(ComposerTrigger.detect(in: "a && b" as NSString, cursor: 4) == nil)
  #expect(ComposerTrigger.detect(in: "Tom & Jerry" as NSString, cursor: 6) == nil)
  #expect(ComposerTrigger.detect(in: "&" as NSString, cursor: 1)?.character == "&")
  #expect(ComposerTrigger.detect(in: "!" as NSString, cursor: 1) == nil)
  let agent = ComposerToken(kind: .agent, id: "build", text: "@build")
  #expect(
    ComposerTrigger.detect(in: .init(text: "@build&", tokens: [.init(start: 0, end: 6, token: agent)]), cursor: 7)?
      .character != "&")
}

@Test func snippetsUseAliasesAndProjectOverrideCaseInsensitively() throws {
  var source = ComposerSources()
  source.snippets = try decodeComposer(
    """
    [{"id":"global","name":"Revisar","description":"Global","aliases":["rv"],"content":"global"},
    {"id":"local","name":"revisar","description":"Projeto","aliases":["diff"],"content":"local","project":"p"},
    {"id":"other","name":"outro","description":"Não","aliases":[],"content":"no","project":"other"}]
    """, [ComposerSnippet].self)
  #expect(
    source.suggestions(try #require(detected("#")), project: "p").map(\.token.id) == ["local"])
  #expect(
    source.suggestions(try #require(detected("#diff")), project: "p").first?.token.value == "local")
  #expect(source.suggestions(try #require(detected("#rv"))).first?.token.id == "global")
}

@Test func skillRankingPrefersNameAndIDBeforeDescription() throws {
  var source = ComposerSources()
  source.skills = try decodeComposer(
    """
    [{"id":"import-memory","name":"import-memory","description":"Import a conversation"},
     {"id":"handoff","name":"handoff","description":"Compact the current conversation"},
     {"id":"other","name":"my-conversation-tools"},
     {"id":"conversation-id","name":"Different display name"},
     {"id":"check","name":"conversation-check","description":"Confere a conversa"}]
    """, [ComposerSkill].self)
  #expect(
    source.suggestions(try #require(detected("$CONVERSATION"))).map(\.token.id)
      == ["conversation-id", "check", "other", "import-memory", "handoff"])
}

@Test func slashRankingPlacesMatchingSkillBeforeCommandDescription() throws {
  var source = ComposerSources()
  source.commands = try decodeComposer(
    """
    [{"name":"describe","description":"Review the conversation"},
     {"name":"pre-review","description":"Revisa"},{"name":"review-code"}]
    """, [ComposerCommand].self)
  source.skills = try decodeComposer(
    """
    [{"id":"review-skill","name":"review-skill","slash":true}]
    """, [ComposerSkill].self)
  let items = source.suggestions(try #require(detected("/review")))
  #expect(items.map(\.token.id) == ["review-code", "review-skill", "pre-review", "describe"])
  #expect(items.map(\.section) == ["Comandos", "Skills", "Comandos", "Comandos"])
}

@Test func contextRankingCombinesNamesIDsAndFileBasenames() throws {
  var source = ComposerSources()
  source.references = try decodeComposer(
    """
    [{"name":"library","path":"/ref","description":"Infração e infraestrutura"}]
    """, [ComposerReference].self)
  let files = try decodeComposer(
    """
    [{"path":"docs/my-infra.md","type":"file"},{"path":"docs/infra.md","type":"file"}]
    """, [ComposerFile].self)
  let agents = try decodeComposer(
    """
    [{"id":"infra-agent","name":"Named differently","mode":"subagent"}]
    """, [AgentInfo].self)
  #expect(
    source.suggestions(try #require(detected("@ÍNFRA")), agents: agents, files: files).map(
      \.token.id)
      == ["infra-agent", "library"])
  #expect(
    source.suggestions(try #require(detected("&ÍNFRA")), agents: agents, files: files).map(
      \.token.id)
      == ["docs/infra.md", "docs/my-infra.md"])
}

@Test func snippetRankingIncludesAliasPrefixesAndSubstrings() throws {
  var source = ComposerSources()
  source.snippets = try decodeComposer(
    """
    [{"id":"description","name":"a-description","description":"Revisar tudo","aliases":[],"content":"a"},
     {"id":"substring","name":"b-substring","description":"","aliases":["pre-revisar"],"content":"b"},
     {"id":"prefix","name":"z-prefix","description":"","aliases":["revisar"],"content":"c"},
     {"id":"revisar-id","name":"z-other","description":"","aliases":[],"content":"d"}]
    """, [ComposerSnippet].self)
  #expect(
    source.suggestions(try #require(detected("#revis"))).map(\.token.id)
      == ["revisar-id", "prefix", "substring", "description"])
  #expect(
    source.suggestions(try #require(detected("#"))).map(\.token.id)
      == ["description", "substring", "revisar-id", "prefix"])
}

@Test func tokenSerializationUsesUTF16AndKeepsTypedDisplayText() throws {
  let prefix = "😀 Ação "
  let file = ComposerToken(kind: .file, id: "f", text: "@açúcar.md", value: "/repo/açúcar.md")
  let agent = ComposerToken(kind: .agent, id: "explore", text: "@Explore")
  let text = prefix + file.text + " " + agent.text
  let start = prefix.utf16.count
  let document = ComposerDocument(
    text: text,
    tokens: [
      .init(start: start, end: start + file.text.utf16.count, token: file),
      .init(start: start + file.text.utf16.count + 1, end: text.utf16.count, token: agent),
    ])
  let request = PromptRequest(
    document: document, delivery: .steer, agent: "build", model: composerModel)
  #expect(request.metadata["displayText"] == .string(text))
  #expect(request.metadata["comments"] == .array([]))
  #expect(request.files?.first?.object?["mention"]?.object?["start"] == .number(8))
  #expect(request.agents?.first?.object?["name"] == .string("explore"))
  #expect(
    URL(string: request.files?.first?.object?["uri"]?.string ?? "")?.path
      .precomposedStringWithCanonicalMapping == "/repo/açúcar.md")
  #expect(
    ComposerDocument.fileURI("/repo/a\u{00e7}\u{00fa}car.md") == "file:///repo/a%C3%A7%C3%BAcar.md")
  let raw = PromptRequest(
    document: .init(text: "@açúcar.md $check"), delivery: .steer, agent: "build",
    model: composerModel)
  #expect(raw.files == nil && raw.skills == nil)
}

@Test func snippetExpansionShiftsLaterMentionsAndNormalizesNewlines() {
  let snippet = ComposerToken(kind: .snippet, id: "r", text: "#r", value: "😀 Revise\r\nagora")
  let skill = ComposerToken(kind: .skill, id: "check", text: "$check")
  let document = ComposerDocument(
    text: "#r $check",
    tokens: [
      .init(start: 0, end: 2, token: snippet), .init(start: 3, end: 9, token: skill),
    ])
  let request = PromptRequest(
    document: document, delivery: .queue, agent: "build", model: composerModel)
  #expect(request.text == "😀 Revise\nagora $check")
  #expect(
    request.skills?.first?.object?["mention"]?.object?["start"]
      == .number(Double("😀 Revise\nagora ".utf16.count)))
  #expect(request.metadata["displayText"] == .string("#r $check"))
  let normalized = ComposerDocument(
    text: "a\r\n$check", tokens: [.init(start: 3, end: 9, token: skill)]
  ).normalized
  #expect(normalized.tokens.first?.start == 2)
}

@Test func dispatchDistinguishesSelectedCommandSlashSkillAndRawText() {
  let command = ComposerToken(kind: .command, id: "review", text: "/review", value: "backend")
  let skill = ComposerToken(kind: .skill, id: "review", text: "/review")
  let local = ComposerToken(kind: .command, id: "compact", text: "/compact", value: "client")
  #expect(ComposerDispatch.resolve(.init(text: "/review")) == .prompt)
  #expect(
    ComposerDispatch.resolve(
      .init(text: "/review", tokens: [.init(start: 0, end: 7, token: skill)])) == .prompt)
  let text = "/review   $check  "
  let document = ComposerDocument(
    text: text,
    tokens: [
      .init(start: 0, end: 7, token: command),
      .init(start: 10, end: 16, token: .init(kind: .skill, id: "check", text: "$check")),
    ])
  #expect(ComposerDispatch.resolve(document) == .command("review", "$check"))
  let request = PromptRequest(
    document: document, delivery: .steer, agent: "build", model: composerModel)
  #expect(request.text == "$check")
  #expect(request.skills?.first?.object?["mention"]?.object?["start"] == .number(0))
  #expect(
    ComposerDispatch.resolve(
      .init(text: "/compact", tokens: [.init(start: 0, end: 8, token: local)])) == .local("compact")
  )
}

@Test func sessionReferenceIsMetadataAndInstructionNotAFile() {
  let token = ComposerToken(
    kind: .session, id: "ses_ref", text: "@Revisão",
    detail: [
      "id": .string("ses_ref"), "title": .string("Revisão"), "directory": .string("/repo"),
      "server": .string("https://local"),
    ])
  let document = ComposerDocument(
    text: token.text, tokens: [.init(start: 0, end: token.text.utf16.count, token: token)])
  let request = PromptRequest(
    document: document, delivery: .steer, agent: "build", model: composerModel)
  #expect(request.files == nil)
  #expect(request.metadata["sessions"]?.array?.count == 1)
  #expect(request.text.contains("Referenced OpenCode session:"))
  #expect(request.text.contains("Use tools.sessions.read (tools.opencode.session_read on older servers)"))
}

@Test func attachmentInlineRulesAndConversionDecision() {
  for mime in ["image/png", "image/jpeg", "image/gif", "image/webp"] {
    #expect(AttachmentEncoding.inline(mime: mime, size: 20 * 1024 * 1024, input: ["image"]))
    #expect(!AttachmentEncoding.inline(mime: mime, size: 20 * 1024 * 1024 + 1, input: ["image"]))
    #expect(!AttachmentEncoding.inline(mime: mime, size: 1, input: ["text"]))
  }
  #expect(AttachmentEncoding.inline(mime: "application/pdf", size: 1, input: ["pdf"]))
  #expect(!AttachmentEncoding.inline(mime: "application/pdf", size: 1, input: ["image"]))
  #expect(!AttachmentEncoding.inline(mime: "text/plain", size: 1, input: ["text"]))
  #expect(!AttachmentEncoding.inline(mime: "image/heic", size: 1, input: ["image"]))
  #expect(AttachmentEncoding.convertToJPEG(mime: "image/heic", width: 80, height: 80))
  #expect(AttachmentEncoding.convertToJPEG(mime: "image/png", width: 4000, height: 2000))
  #expect(!AttachmentEncoding.convertToJPEG(mime: "image/png", width: 2048, height: 1024))
}

@Test func attachmentSerializationStagesBothInlineAndPaths() {
  let image = DraftAttachment(name: "foto.png", mime: "image/png", size: 2)
  let file = DraftAttachment(name: "nota.txt", mime: "text/plain", size: 3)
  let request = PromptRequest(
    document: .init(text: "Confira"), delivery: .steer, agent: "build", model: composerModel,
    attachments: [
      .init(attachment: image, path: "/tmp/foto.png", inline: "data:image/png;base64,YWI="),
      .init(attachment: file, path: "/tmp/nota.txt", inline: nil),
    ])
  #expect(request.files?.count == 1)
  #expect(request.files?.first?.object?["uri"] == .string("data:image/png;base64,YWI="))
  #expect(request.metadata["attachments"]?.array?.count == 1)
  #expect(request.text == "Confira\nAttached file: `/tmp/foto.png`\nAttached file: `/tmp/nota.txt`")
}

@Test func draftPersistenceRoundTripIsServerScopedAndCleansRemovedBytes() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "composer-test-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let store = DraftPersistence(server: "https://one", sessionID: "ses_a", root: root)
  let other = DraftPersistence(server: "https://two", sessionID: "ses_a", root: root)
  let attachment = DraftAttachment(name: "a.txt", mime: "text/plain", size: 3)
  let token = ComposerToken(kind: .snippet, id: "r", text: "#r", value: "revise")
  let snapshot = DraftSnapshot(
    document: .init(text: "#r", tokens: [.init(start: 0, end: 2, token: token)]),
    attachments: [attachment], model: composerModel, agent: "build", cursor: 2,
    replacing: "queued-original")
  try await store.store(Data("abc".utf8), attachment: attachment)
  try await store.save(snapshot)
  #expect(try await store.load().0 == snapshot)
  #expect(try await store.bytes(attachment) == Data("abc".utf8))
  #expect(try await other.load().0 == nil)
  try await store.cleanAttachments(retaining: [])
  #expect(!FileManager.default.fileExists(atPath: store.file(attachment).path))
  #expect(try await store.load().1)
  try await store.remove()
  #expect(try await store.load().0 == nil)
}

@Test func draftPersistenceDropsAttachmentsBeyondBudget() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "composer-test-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let store = DraftPersistence(server: "s", sessionID: "id", root: root)
  let item = DraftAttachment(
    name: "oversize", mime: "application/octet-stream", size: AttachmentEncoding.draftLimit + 1)
  try await store.store(Data([1]), attachment: item)
  try await store.save(.init(attachments: [item]))
  let (snapshot, dropped) = try await store.load()
  #expect(dropped)
  #expect(snapshot?.attachments.isEmpty == true)
}

@Test func attachmentConversionReallyDownscalesAndProducesJPEG() throws {
  let pixels = Data(repeating: 150, count: 3000 * 20 * 3)
  let provider = try #require(CGDataProvider(data: pixels as CFData))
  let image = try #require(
    CGImage(
      width: 3000, height: 20, bitsPerComponent: 8, bitsPerPixel: 24,
      bytesPerRow: 9000, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [], provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  let (converted, name, mime) = try AttachmentEncoding.prepare(
    data as Data, name: "wide.png", mime: "image/png")
  #expect(name == "wide.jpg" && mime == "image/jpeg")
  let source = try #require(CGImageSourceCreateWithData(converted as CFData, nil))
  let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  #expect(decoded.width == 2048 && decoded.height <= 20)
}

@Test func attachmentHTTPStagesRawBytesAndCommandsHaveNoPromptMetadata() async throws {
  let bytes = Data([1, 2, 3])
  let client = OpenCodeClient(configuration: .init(url: URL(string: "https://sandbox.invalid")!)) {
    request in
    let path = try #require(request.url?.path)
    if path == "/api/info" {
      return (
        Data(#"{"version":"2","paths":{"tmp":"/server/tmp"}}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    if path == "/api/experimental/fs/write" {
      #expect(request.httpMethod == "POST")
      #expect(request.httpBody == bytes)
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
      #expect(query?.first { $0.name == "path" }?.value == "/server/tmp/uploads/attachment/a.png")
      #expect(query?.first { $0.name == "location[directory]" }?.value == "/repo")
    }
    if path == "/api/session/ses_test/command" {
      let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
      #expect(body.object?["name"] == .string("review"))
      #expect(body.object?["text"] == .string("argument"))
      #expect(body.object?["id"] == nil && body.object?["metadata"] == nil)
    }
    return (
      Data(),
      HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
    )
  }
  let delivered = try await client.deliver(
    .init(id: "attachment", name: "a.png", mime: "image/png", size: 3),
    bytes: bytes, directory: "/repo", input: ["image"])
  #expect(delivered.inline == "data:image/png;base64,AQID")
  let request = PromptRequest(
    text: "argument", delivery: .steer, agent: "build", model: composerModel)
  try await client.command("review", request: request, sessionID: "ses_test")
}

@Test func materializedQueueMentionsBecomeRequestURIsAgain() throws {
  let payload = try decodeComposer(
    """
    {"text":"@a.md @Explore $check","metadata":{"displayText":"@a.md @Explore $check","comments":[]},
    "files":[{"mime":"text/plain","data":"YWJj","source":{"type":"uri","uri":"file:///repo/a.md"},"mention":{"start":0,"end":5,"text":"@a.md"}}],
    "agents":[{"name":"explore","mention":{"start":6,"end":14,"text":"@Explore"}}],
    "skills":[{"id":"check","mention":{"start":15,"end":21,"text":"$check"}}]}
    """, InboxItem.Payload.self)
  let document = ComposerDocument(restoring: payload)
  #expect(document.tokens.count == 3)
  let request = PromptRequest(
    document: document, delivery: .queue, agent: "build", model: composerModel)
  #expect(request.files?.first?.object?["uri"] == .string("file:///repo/a.md"))
  #expect(request.files?.first?.object?["data"] == nil)
  #expect(request.agents?.count == 1 && request.skills?.count == 1)
}

private func mentionSession(_ id: String, title: String, directory: String = "/repo/app", updated: Double = 1,
  archived: Double? = nil) -> String {
  #"{"id":"\#(id)","projectID":"p","title":"\#(title)","location":{"directory":"\#(directory)"},"time":{"created":1,"updated":\#(updated)\#(archived.map { #","archived":\#($0)"# } ?? "")}}"#
}

private final class SessionPages: @unchecked Sendable {
  let lock = NSLock()
  var queries: [[String: String]] = []
  func record(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    lock.withLock { queries.append(query) }
    return query
  }
}

@Test func sessionMentionsSkipArchivedSessionsAndReadMorePagesForEnoughLiveOnes() async throws {
  let pages = SessionPages()
  let client = OpenCodeClient(configuration: .init(url: URL(string: "https://sandbox.invalid")!)) { request in
    let query = pages.record(request)
    let first = (0..<50).map { mentionSession("ses_old\($0)", title: "Sessão mestra", updated: Double(1000 - $0), archived: 5) }
      + [mentionSession("ses_live0", title: "Sessão mestra", updated: 900)]
    let second = (1..<20).map { mentionSession("ses_live\($0)", title: "Viva \($0)", updated: Double(800 - $0)) }
    let body = query["cursor"] == nil
      ? #"{"data":[\#(first.joined(separator: ","))],"cursor":{"next":"page2"}}"#
      : #"{"data":[\#(second.joined(separator: ","))],"cursor":{}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  let recent = try await client.composerSessions("")
  #expect(recent.count == 10)
  #expect(recent.allSatisfy { $0.time.archived == nil })
  #expect(recent.first?.id == "ses_live0")
  #expect(pages.queries.count == 2)
  #expect(pages.queries[0]["parentID"] == "null" && pages.queries[0]["search"] == nil)
  #expect(pages.queries[1]["cursor"] == "page2")
  // A search keeps its filter on every page and stops when the list ends.
  let found = try await client.composerSessions("mestra")
  #expect(found.map(\.id) == ["ses_live0"] + (1..<20).map { "ses_live\($0)" })
  #expect(pages.queries.suffix(2).allSatisfy { $0["search"] == "mestra" })
  // A short page ends the list even though the server still returns a next cursor.
  let short = SessionPages()
  let single = OpenCodeClient(configuration: .init(url: URL(string: "https://sandbox.invalid")!)) { request in
    _ = short.record(request)
    let body = #"{"data":[\#(mentionSession("ses_only", title: "Única"))],"cursor":{"next":"more"}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await single.composerSessions("").map(\.id) == ["ses_only"])
  #expect(short.queries.count == 1)
}

@Test func sessionMentionsLabelTheCurrentMasterAndTellRepeatedTitlesApart() throws {
  let now = Date(timeIntervalSince1970: 1_000_000)
  let ms = now.timeIntervalSince1970 * 1000
  let sessions = try decodeComposer(
    "[" + [
      mentionSession("ses_master", title: "Sessão mestra", directory: "/Users/a/master", updated: ms - 120_000),
      mentionSession("ses_twin_a", title: "Revisar PR", directory: "/Users/a/opencode2", updated: ms - 3 * 3_600_000),
      mentionSession("ses_twin_b", title: "revisar pr", directory: "/Users/a/abacato", updated: ms - 2 * 86_400_000),
      mentionSession("ses_single", title: "Única", directory: "/Users/a/app", updated: ms),
    ].joined(separator: ",") + "]", [Session].self)
  let items = ComposerSources().suggestions(
    try #require(detected("@")), sessions: sessions, current: "ses_here", master: "ses_master", now: now)
  #expect(items.map(\.token.id) == ["ses_master", "ses_twin_a", "ses_twin_b", "ses_single"])
  #expect(items.map(\.subtitle) == ["Mestra atual", "opencode2 · 3h", "abacato · 2d", ""])
  // Without a known master, a lone "Sessão mestra" is an ordinary row.
  let plain = ComposerSources().suggestions(try #require(detected("@")), sessions: sessions, now: now)
  #expect(plain.first?.subtitle == "")
}
