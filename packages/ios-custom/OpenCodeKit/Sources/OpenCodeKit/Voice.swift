import Foundation

public enum VoicePhase: String, Codable, Sendable {
  case idle, connecting, listening, speaking, interrupted, reconnecting, offline, failed
  public var label: String {
    switch self {
    case .idle: "Conversa encerrada"
    case .connecting: "Conectando voz…"
    case .listening: "Ouvindo"
    case .speaking: "Falando"
    case .interrupted: "Áudio interrompido"
    case .reconnecting: "Reconectando…"
    case .offline: "Sem conexão"
    case .failed: "Voz indisponível"
    }
  }
}

public struct VoiceState: Equatable, Sendable {
  public enum Event: Sendable {
    case start, connected, speech, silence, bargeIn, interruption, resume, reconnect, offline, end
    case failure(String)
  }
  public private(set) var phase: VoicePhase = .idle
  public private(set) var error: String?
  public var muted = false
  public var masterWorking = false
  public init() {}
  public var visible: Bool { phase != .idle }
  public var label: String {
    if masterWorking && phase == .listening { return "Sessão mestra trabalhando…" }
    return phase.label
  }
  public mutating func apply(_ event: Event) {
    switch event {
    case .start: self = Self(); phase = .connecting
    case .end: self = Self()
    case .failure(let message): error = message; phase = .failed; masterWorking = false
    case .reconnect where [.listening, .speaking, .interrupted, .offline].contains(phase): phase = .reconnecting
    case .offline where [.listening, .speaking, .interrupted, .reconnecting].contains(phase): phase = .offline
    case .connected where [.connecting, .reconnecting, .offline].contains(phase): phase = .listening
    case .speech where [.listening, .speaking].contains(phase): phase = .speaking
    case .silence where phase == .speaking, .bargeIn where phase == .speaking: phase = .listening
    case .interruption where [.listening, .speaking, .reconnecting].contains(phase): phase = .interrupted
    case .resume where phase == .interrupted: phase = .listening
    default: break
    }
  }
}

public enum VoiceWireError: Error, LocalizedError, Equatable {
  case invalidEvent, invalidAnswer, unavailable(Int), oversized
  public var errorDescription: String? {
    switch self {
    case .invalidEvent: "O serviço de voz enviou um evento inválido."
    case .invalidAnswer: "O serviço de voz não confirmou a conexão de áudio."
    case .unavailable(let status): "O serviço de voz está indisponível (HTTP \(status))."
    case .oversized: "A mensagem de voz excedeu o limite permitido."
    }
  }
}

public struct VoiceTranscriptPiece: Equatable, Sendable {
  public let id: String?
  public let text: String
}

public struct VoiceCompletedTurn: Equatable, Sendable {
  public let id: String?
  public let itemID: String?
  public let role: VoiceMemoryTurn.Role
  public let text: String?
  public let interrupted: Bool
}

public enum VoiceEvent: Equatable, Sendable {
  case ready, input(VoiceTranscriptPiece), output(VoiceTranscriptPiece), turnDone(VoiceCompletedTurn)
  case delegation(id: String, text: String), failure, ignored
}

public enum VoiceProtocol {
  /// Appended by the iPhone app to whatever prompt the server returns, so screen delegation keeps working
  /// after Alexandre edits voice.md. GPT Live's delegation tool has no editable description.
  public static let screenInstructions = """
    Capacidade fixa do app OpenCode no iPhone: quando Alexandre pedir para olhar, ver ou conferir a tela
    ("dá uma olhada nessa tela", "o que é isso aqui?"), delegue à mestra com JSON
    {"text":"pedido de Alexandre","screen":true} (com "delivery":"queue" se ele pedir para enfileirar).
    O app anexa uma foto da tela atual do OpenCode, tirada nesse momento, e o ID da sessão aberta.
    Você não recebe a imagem: não descreva nem adivinhe a tela; espere o retorno da mestra.
    Se o retorno disser que não foi possível ver a tela, diga que só consegue ver a tela do próprio
    OpenCode, aberto e com o iPhone desbloqueado, nunca a de outros apps.
    """
  /// The fixed screen capability, unless the served prompt already documents it.
  public static func withScreen(_ instructions: String) -> String {
    instructions.contains("\"screen\":true") ? instructions : instructions + "\n\n" + screenInstructions
  }

  public static func decode(_ data: Data) throws -> VoiceEvent {
    guard data.count <= 256 * 1024 else { throw VoiceWireError.oversized }
    let root = try JSONDecoder().decode(JSONValue.self, from: data).object
    guard let type = root?["type"]?.string else { throw VoiceWireError.invalidEvent }
    switch type {
    case "session.started": return .ready
    case "input_transcript.added", "output_transcript.added":
      guard let text = root?["item"]?.object?["text"]?.string else { throw VoiceWireError.invalidEvent }
      let piece = VoiceTranscriptPiece(id: root?["item"]?.object?["id"]?.string, text: text)
      return type.hasPrefix("input") ? .input(piece) : .output(piece)
    case "turn.done":
      guard let role = root?["turn"]?.object?["role"]?.string,
        ["assistant", "user", "input"].contains(role) else { throw VoiceWireError.invalidEvent }
      let turn = root?["turn"]?.object
      return .turnDone(.init(id: turn?["id"]?.string, itemID: turn?["item_id"]?.string ?? turn?["item"]?.object?["id"]?.string,
        role: role == "assistant" ? .assistant : .user, text: turn?["transcript"]?.string,
        interrupted: turn?["interrupted"]?.bool == true || ["interrupted", "cancelled"].contains(turn?["status"]?.string ?? "")))
    case "delegation.created":
      guard let item = root?["item"]?.object, item["target"]?.string == "client" else { return .ignored }
      guard item["type"]?.string == "delegation", let id = item["id"]?.string,
        !id.isEmpty, id.utf8.count <= 1024, let content = item["content"]?.array else {
        throw VoiceWireError.invalidEvent
      }
      let text = content.compactMap { part -> String? in
        guard part.object?["type"]?.string == "input_text" else { return nil }
        return part.object?["text"]?.string
      }.joined()
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768 else {
        throw VoiceWireError.invalidEvent
      }
      return .delegation(id: id, text: text)
    case "error": return .failure
    default: return .ignored
    }
  }

  public static func append(id: String, text: String) throws -> [Data] {
    guard !id.isEmpty, id.utf8.count <= 1024, !text.isEmpty, text.utf8.count <= 65_536 else {
      throw VoiceWireError.oversized
    }
    var chunks: [String] = []
    var chunk = ""
    for scalar in text.unicodeScalars {
      if chunk.utf8.count + scalar.utf8.count > 500 { chunks.append(chunk); chunk = "" }
      chunk.unicodeScalars.append(scalar)
    }
    if !chunk.isEmpty { chunks.append(chunk) }
    return try chunks.map {
      try JSONEncoder().encode(JSONValue.object([
        "type": .string("delegation.context.append"), "delegation_item_id": .string(id),
        "channel": .string("speakable"),
        "content": .array([.object(["type": .string("input_text"), "text": .string($0)])]),
      ]))
    }
  }
}

public struct VoiceMasterRequest: Sendable, Equatable {
  public let text: String
  public let delivery: PromptDelivery
  /// GPT Live asked to attach a capture of the OpenCode screen (`"screen": true`).
  public let screen: Bool
  public init(_ input: String) {
    let object = (try? JSONDecoder().decode(JSONValue.self, from: Data(input.utf8)))?.object
    let screen = object?["screen"]?.bool == true
    let text = object?["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let object, !text.isEmpty || screen else {
      self.text = input; delivery = .steer; self.screen = false
      return
    }
    self.text = text.isEmpty ? "Dê uma olhada nesta tela do app." : text
    delivery = object["delivery"]?.string == "queue" ? .queue : .steer
    self.screen = screen
  }
}

/// A latest-value mailbox, not a queue of stale narration. User speech takes priority.
public struct VoiceNarration: Sendable {
  private var pending: String?
  private var last: String?
  private var nextAllowed: Double = 0
  public init() {}
  public mutating func offer(_ text: String) {
    guard !text.isEmpty, text != last else { return }
    pending = text
  }
  public mutating func take(now: Double, speaking: Bool, userUntil: Double, final: Bool = false) -> String? {
    guard !speaking, now >= userUntil, final || now >= nextAllowed, let pending else { return nil }
    self.pending = nil; last = pending; nextAllowed = now + 5
    return pending
  }
}

public enum VoiceMasterProgress {
  public static func call(_ event: ConversationEvent) -> (name: String, sessionID: String?)? {
    if event.type == "session.tool.called", let name = event.data.name {
      return (String(name.split(separator: ".").last ?? Substring(name)), event.data.input?.object?["sessionID"]?.string)
    }
    guard event.type == "session.tool.progress",
      let call = event.data.metadata?.object?["toolCalls"]?.array?.last(where: { $0.object?["status"]?.string == "running" })?.object,
      let name = call["tool"]?.string else { return nil }
    return (String(name.split(separator: ".").last ?? Substring(name)), call["input"]?.object?["sessionID"]?.string)
  }
  public static func describe(_ event: ConversationEvent) -> String? {
    if let call = call(event) {
      switch call.name {
      case "session_read", "session_status": return "A mestra está conferindo uma sessão."
      case "sessions_list": return "A mestra está consultando suas sessões."
      case "session_send": return "A mestra está encaminhando seu pedido."
      case "session_create": return "A mestra está criando a sessão solicitada."
      case "session_wait": return "A mestra está acompanhando o trabalho da sessão."
      case "requests_list": return "A mestra está verificando os pedidos pendentes."
      case "request_answer": return "A mestra está respondendo ao pedido autorizado."
      case "read", "grep", "glob": return "A mestra está consultando os arquivos."
      case "execute": return "A mestra está consultando as ferramentas."
      case "iphone_query", "iphone_status": return "A mestra está consultando seu iPhone."
      default: return "A mestra está usando uma ferramenta."
      }
    }
    if event.type == "session.tool.failed" { return "Uma ferramenta falhou. A mestra está verificando o resultado." }
    if event.type == "session.text.ended", let text = event.data.text, !text.isEmpty {
      return "Atualização da mestra: " + String(text.prefix(700))
    }
    if event.type == "session.step.failed" { return "Uma etapa da mestra falhou. Aguardando o resultado da execução." }
    return nil
  }
}
