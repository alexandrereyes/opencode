import Foundation

public struct SideQuestionEntry: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let question: String
  public var answer: String
  public init(question: String, answer: String = "") {
    id = UUID()
    self.question = question
    self.answer = answer
  }
}

public struct SideQuestionRequest: Encodable, Sendable {
  public static let instructions =
    "The user is asking a quick side question about the conversation so far. Answer directly and concisely in markdown from what you already know. Do not call any tools and do not take any actions."
  public let prompt: String
  public init(question: String, history: [SideQuestionEntry] = []) {
    let history = history.filter { !$0.answer.isEmpty }.suffix(5).map { entry in
      [
        "question": Self.truncate(entry.question, to: 1000),
        "answer": Self.truncate(entry.answer, to: 3000),
      ]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let context =
      history.isEmpty
      ? nil
      : (try? encoder.encode(history))
        .flatMap { String(data: $0, encoding: .utf8) }
        .map { "Previous side questions and answers (reference context):\n" + $0 }
    prompt = [Self.instructions, context, question.trimmingCharacters(in: .whitespacesAndNewlines)]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
  }
  private static func truncate(_ text: String, to count: Int) -> String {
    // JavaScript slice counts UTF-16. Avoid splitting a surrogate at its boundary.
    var end = min(count, text.utf16.count)
    let units = Array(text.utf16.prefix(end + 1))
    if end > 0 && end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
    return String(decoding: units.prefix(end), as: UTF16.self)
  }
  public static func quote(_ text: String) -> String {
    text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n\n"
  }
  public static func slashQuestion(_ document: ComposerDocument) -> String? {
    let text = document.expanded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("/btw") else { return nil }
    let question = text.dropFirst(4)
    guard question.isEmpty || question.first?.isWhitespace == true else { return nil }
    return String(question).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension OpenCodeClient {
  public func sideQuestion(_ input: SideQuestionRequest, sessionID: String) async throws -> String {
    struct Response: Codable { let text: String }
    var request = request("/api/session/\(sessionID)/generate")
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(input)
    let response = try JSONDecoder().decode(DataResponse<Response>.self, from: await data(request))
    return response.data.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
