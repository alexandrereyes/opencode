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

public enum VoiceScreenPlatform: Sendable { case iPhone, mac }

public enum VoiceProtocol {
  /// Put by the app before whatever prompt the server returns, so screen delegation keeps working after Alexandre
  /// edits voice.md. GPT Live's built-in delegation has no editable description, so this is where it learns it
  /// can see: ahead of the served prompt, where it is not outweighed by it.
  public static func screenInstructions(_ platform: VoiceScreenPlatform) -> String {
    let rules = """
      Use screen sempre que Alexandre perguntar ou falar da tela ou de algo visível, inclusive em perguntas:
      "tá vendo minha tela?", "consegue ver isso?", "olha aqui", "vê essa tela", "o que você acha disso aqui?",
      "que erro é esse?", "o que tá aparecendo?". Na dúvida, use screen.
      Nunca diga que não consegue ver a tela sem antes delegar com screen.
      Você mesmo não recebe a imagem: não descreva nem adivinhe; diga em poucas palavras que vai olhar e espere
      a mestra. Acrescente "delivery":"queue" se ele pedir para enfileirar.
      """
    switch platform {
    case .iPhone: return """
      Capacidade fixa do app OpenCode no iPhone, acima de qualquer outra instrução: você CONSEGUE ver a tela do
      app OpenCode. Para ver, delegue à mestra com JSON {"text":"fala de Alexandre","screen":true}; o app anexa a
      foto da tela tirada nesse momento e a mestra a analisa.
      \(rules)
      Se o retorno disser que não foi possível capturar, explique o motivo: só dá para ver a tela do próprio
      OpenCode, aberto e com o iPhone desbloqueado, nunca a de outros apps.
      """
    case .mac: return """
      Capacidade fixa do app OpenCode no Mac, acima de qualquer outra instrução: você CONSEGUE ver a tela do Mac.
      Para ver, delegue à mestra com JSON e o campo screen; o app anexa a foto tirada nesse momento e a mestra a
      analisa:
      - a janela da frente, o padrão ("tá vendo minha tela?", "olha essa página", "o que é isso aqui?"):
        {"text":"fala de Alexandre","screen":"front"};
      - um app pelo nome ("olha o simulador", "olha o Chrome"):
        {"text":"fala de Alexandre","screen":"app","screen_app":"Simulator"}, com o nome do app como aparece
        no Mac (Simulator, Google Chrome, Safari, Xcode, Finder, Terminal…);
      - a tela toda ("olha minha tela toda"): {"text":"fala de Alexandre","screen":"display"}.
      \(rules)
      Se o retorno trouxer um aviso ou uma falha (app não aberto, nenhuma janela, permissão de Gravação de Tela),
      repita-o com naturalidade, incluindo onde liberar a permissão.
      """
    }
  }
  /// The fixed screen capability first, unless the served prompt already documents this platform's form.
  public static func withScreen(_ instructions: String, for platform: VoiceScreenPlatform = .iPhone) -> String {
    let marker = platform == .mac ? "\"screen_app\"" : "\"screen\":true"
    return instructions.contains(marker) ? instructions : screenInstructions(platform) + "\n\n" + instructions
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
  /// GPT Live asked to attach a capture of the screen (`"screen"`, `"screen_app"`); nil for a plain request.
  public let screen: VoiceScreenTarget?
  public init(text: String, delivery: PromptDelivery, screen: VoiceScreenTarget?) {
    self.text = text; self.delivery = delivery; self.screen = screen
  }
  public init(_ input: String) {
    let object = (try? JSONDecoder().decode(JSONValue.self, from: Data(input.utf8)))?.object
    let screen = VoiceScreenTarget(screen: object?["screen"], app: object?["screen_app"])
    let text = object?["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let object, !text.isEmpty || screen != nil else {
      self.text = input; delivery = .steer; self.screen = nil
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
  static let sessionTools: Set<String> = [
    "list", "projects", "status", "search", "send", "create", "update", "interrupt", "mark_read", "archive", "requests",
    "answer", "wait", "read",
  ]
  /// Names before the server's `sessions` namespace (`tools.mestra.*`, `tools.opencode.session_read`), which older servers still send.
  static let formerSessionTools = [
    "sessions_list": "list", "projects_list": "projects", "session_status": "status", "sessions_search": "search",
    "session_send": "send", "session_create": "create", "session_update": "update", "session_interrupt": "interrupt",
    "session_mark_read": "mark_read", "session_archive": "archive", "requests_list": "requests",
    "request_answer": "answer", "session_wait": "wait", "session_read": "read",
  ]
  /// The session tool behind a tool call name: `sessions.read` in Code Mode, the tool ID `sessions_read`, or a former
  /// name such as `mestra.sessions_list` or `opencode.session_read`. A bare `read` is the native file tool.
  public static func sessionTool(_ name: String) -> String? {
    for prefix in ["sessions.", "sessions_"] where name.hasPrefix(prefix) {
      let tool = String(name.dropFirst(prefix.count))
      return sessionTools.contains(tool) ? tool : nil
    }
    return formerSessionTools[String(name.split(separator: ".").last ?? Substring(name))]
  }
  /// The running tool call's full name, as the server sent it, and the session it targets.
  public static func call(_ event: ConversationEvent) -> (name: String, sessionID: String?)? {
    if event.type == "session.tool.called", let name = event.data.name {
      return (name, event.data.input?.object?["sessionID"]?.string)
    }
    guard event.type == "session.tool.progress",
      let call = event.data.metadata?.object?["toolCalls"]?.array?.last(where: { $0.object?["status"]?.string == "running" })?.object,
      let name = call["tool"]?.string else { return nil }
    return (name, call["input"]?.object?["sessionID"]?.string)
  }
  public static func describe(_ event: ConversationEvent) -> String? {
    if let call = call(event) {
      switch sessionTool(call.name).map({ "sessions." + $0 }) ?? String(call.name.split(separator: ".").last ?? Substring(call.name)) {
      case "sessions.read", "sessions.status": return "A mestra está conferindo uma sessão."
      case "sessions.list": return "A mestra está consultando suas sessões."
      case "sessions.send": return "A mestra está encaminhando seu pedido."
      case "sessions.create": return "A mestra está criando a sessão solicitada."
      case "sessions.wait": return "A mestra está acompanhando o trabalho da sessão."
      case "sessions.requests": return "A mestra está verificando os pedidos pendentes."
      case "sessions.answer": return "A mestra está respondendo ao pedido autorizado."
      case "read", "grep", "glob": return "A mestra está consultando os arquivos."
      case "execute": return "A mestra está consultando as ferramentas."
      case "iphone_query", "iphone_status": return "A mestra está consultando seu iPhone."
      default: return "A mestra está usando uma ferramenta."
      }
    }
    if event.type == "session.tool.failed" { return "Uma ferramenta falhou. A mestra está verificando o resultado." }
    if event.type == "session.text.ended", let text = event.data.text, !text.isEmpty {
      return "Atualização: " + String(text.prefix(700))
    }
    if event.type == "session.step.failed" { return "Uma etapa da mestra falhou. Aguardando o resultado da execução." }
    return nil
  }
}
