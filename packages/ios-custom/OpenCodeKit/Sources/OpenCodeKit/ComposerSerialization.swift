import Foundation

extension PromptRequest {
  public init(
    id: String = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
    document: ComposerDocument, delivery: PromptDelivery, agent: String, model: ModelReference,
    attachments: [DeliveredAttachment] = [], metadata extra: [String: JSONValue] = [:]
  ) {
    let display = document.normalized
    var expanded = display.expanded
    // Backend commands have their own envelope; offsets refer to their argument text.
    if case .command = ComposerDispatch.resolve(display), let command = expanded.tokens.first {
      let tail = (expanded.text as NSString).substring(from: command.end)
      let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
      let removed = command.end + (tail as NSString).range(of: trimmed).location
      expanded = ComposerDocument(
        text: trimmed,
        tokens: expanded.tokens.dropFirst().map {
          .init(start: $0.start - removed, end: $0.end - removed, token: $0.token)
        })
    }
    var files: [JSONValue] = []
    var agents: [JSONValue] = []
    var skills: [JSONValue] = []
    var sessions: [JSONValue] = []
    var suffix: [String] = []
    for span in expanded.validTokens {
      let mention = JSONValue.object([
        "start": .number(Double(span.start)), "end": .number(Double(span.end)),
        "text": .string(span.token.text),
      ])
      switch span.token.kind {
      case .file, .reference:
        if let path = span.token.value {
          files.append(
            .object([
              "uri": .string(ComposerDocument.fileURI(path)),
              "name": .string(URL(fileURLWithPath: path).lastPathComponent), "mention": mention,
            ]))
        }
      case .agent: agents.append(.object(["name": .string(span.token.id), "mention": mention]))
      case .skill: skills.append(.object(["id": .string(span.token.id), "mention": mention]))
      case .session:
        if let session = span.token.detail {
          sessions.append(
            .object([
              "type": .string("session"), "content": .string(span.token.text),
              "start": .number(Double(span.start)), "end": .number(Double(span.end)),
              "session": .object(session),
            ]))
          let context = [
            "sessionID": JSONValue.string(span.token.id), "title": session["title"] ?? .null,
            "directory": session["directory"] ?? .null,
          ]
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
          if let data = try? encoder.encode(context), let json = String(data: data, encoding: .utf8)
          {
            suffix.append(
              "Referenced OpenCode session: \(json). Use tools.opencode.session_read when you need to discuss its contents."
            )
          }
        }
      case .snippet, .command: break
      }
    }
    var staged: [JSONValue] = []
    for item in attachments {
      suffix.append("Attached file: `\(item.path)`")
      if let inline = item.inline {
        files.append(.object(["uri": .string(inline), "name": .string(item.attachment.name)]))
      } else {
        staged.append(
          .object([
            "name": .string(item.attachment.name), "mime": .string(item.attachment.mime),
            "path": .string(item.path),
          ]))
      }
    }
    var metadata = extra
    metadata.removeValue(forKey: "sessions")
    metadata.removeValue(forKey: "attachments")
    metadata["displayText"] = .string(display.text)
    metadata["comments"] = metadata["comments"] ?? .array([])
    metadata["agent"] = .string(agent)
    var ref: [String: JSONValue] = [
      "providerID": .string(model.providerID), "modelID": .string(model.id),
    ]
    if let variant = model.variant { ref["variant"] = .string(variant) }
    metadata["model"] = .object(ref)
    if !sessions.isEmpty { metadata["sessions"] = .array(sessions) }
    if !staged.isEmpty { metadata["attachments"] = .array(staged) }
    if let data = try? JSONEncoder().encode(display.tokens),
      let tokens = try? JSONDecoder().decode(JSONValue.self, from: data)
    {
      metadata["composerTokens"] = tokens
    }
    self.init(
      id: id, text: ([expanded.text].filter { !$0.isEmpty } + suffix).joined(separator: "\n"),
      delivery: delivery, metadata: metadata, files: files, agents: agents, skills: skills)
  }
}
