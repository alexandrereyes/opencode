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
    /// The service moderated the call and its voice memory was cleared; shown until the call ends.
    case contextCleared
  }
  public private(set) var phase: VoicePhase = .idle
  public private(set) var error: String?
  public var muted = false
  public var masterWorking = false
  /// Kept through every phase of this call, failure included; a new call (`start`) or the end clears it.
  public private(set) var contextCleared = false
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
    case .contextCleared: contextCleared = true; masterWorking = false
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

public enum VoiceScreenPlatform: Sendable { case iPhone, mac }

/// Not wire but prompt: each app's screen capability, put in front of the served prompt (the wire is in
/// `VoiceProtocol.swift`).
extension VoiceProtocol {
  /// Put by each app before the prompt the server returns, which is shared with the Watch and so says nothing of a
  /// screen. GPT Live's built-in delegation has no editable description, so this is where it learns it can see. It
  /// says what the route does: GPT Live writes no request (the delegation's text is the transcript of his turn), so
  /// the app attaches the capture when his words name the screen or a print (`VoiceScreenIntent`), and the Mac the
  /// whole screen for "a tela toda"; an app by name is not recognized. Pointing without naming the screen gets no
  /// capture, and GPT Live is told how he can ask for one rather than to ask whether to look: on 02/11 it delegated
  /// "olha isso aqui" and "o que você acha disso" every time (3 of 3), with and without that instruction. Backend
  /// work is asked with OpenAI's `gpt-live-1` wording (`<|SpawnThinking|>`), and it names the agent, never the
  /// master. No "acima de qualquer outra instrução": in front of the prompt, that made GPT Live open calls talking
  /// about the screen (30/10).
  public static func screenInstructions(_ platform: VoiceScreenPlatform) -> String {
    let rules = """
      Quando ele aponta para algo sem citar a tela ou um print ("olha isso aqui", "o que você acha disso?"), a
      captura não vai; se o retorno do agente mostrar que ele não viu nada, diga em poucas palavras que, para você
      ver, ele pode pedir "olha minha tela".
      Você mesmo não recebe a imagem: não descreva nem adivinhe; diga em poucas palavras que vai olhar e espere
      o retorno do agente. Nunca diga que não consegue ver a tela sem antes gerar <|SpawnThinking|>.
      """
    switch platform {
    case .iPhone: return """
      Tela do app OpenCode no iPhone: você consegue ver a tela do OpenCode. Quando Alexandre falar da tela ou de um
      print ("tá vendo minha tela?", "olha minha tela", "tira um print"), gere <|SpawnThinking|>; o app anexa ao
      pedido uma captura tirada nesse momento, e o agente a analisa.
      \(rules)
      Se o retorno disser que não foi possível capturar, explique o motivo: só dá para ver a tela do próprio
      OpenCode, aberto e com o iPhone desbloqueado, nunca a de outros apps.
      """
    case .mac: return """
      Tela do Mac: você consegue ver a tela do Mac. Quando Alexandre falar da tela ou de um print ("tá vendo minha
      tela?", "olha minha tela", "tira um print"), gere <|SpawnThinking|>; o app anexa ao pedido uma captura da janela
      da frente tirada nesse momento, ou da tela inteira quando ele diz "a tela toda", e o agente a analisa.
      \(rules)
      Se o retorno trouxer um aviso ou uma falha (nenhuma janela na frente, permissão de Gravação de Tela), repita-o
      com naturalidade, incluindo onde liberar a permissão.
      """
    }
  }
  /// The app's screen capability first, unless the served prompt already documents the screen: it holds this block,
  /// or it is an edited voice.md from the default until 02/11, which described the JSON form (`"screen":true` on the
  /// iPhone, `"screen_app"` on the Mac). The route never sends that JSON, but such a prompt is kept as it is, without
  /// a second, contradicting block; the app still attaches the capture from his words.
  public static func withScreen(_ instructions: String, for platform: VoiceScreenPlatform = .iPhone) -> String {
    let block = screenInstructions(platform)
    let former = platform == .mac ? "\"screen_app\"" : "\"screen\":true"
    return instructions.contains(block) || instructions.contains(former) ? instructions : block + "\n\n" + instructions
  }
}

/// A delegation as the master gets it. `init(_:)` still reads the JSON form the voice prompt described until 02/11
/// (`text`, `screen`, `screen_app`, `delivery`), which this route never sends: its text is the transcript of his turn,
/// and the app decides the screen and the queue from his words (`VoiceScreenIntent`, `VoiceQueueIntent`).
public struct VoiceMasterRequest: Sendable, Equatable {
  public let text: String
  public let delivery: PromptDelivery
  /// The capture to attach (`"screen"`, `"screen_app"`, or the app's inference); nil for a plain request.
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
  /// What is waiting to be said.
  public var waiting: String? { pending }
  /// Puts back a text that was taken but not heard (its call dropped), even when it was the last one said.
  public mutating func retry(_ text: String) {
    guard pending == nil else { return }
    pending = text; last = nil
  }
}

/// GPT Live's quiet view of what the master is doing (`VoiceChannel.commentary`), kept apart from `VoiceNarration`,
/// which holds what is said: the latest state only, sent when it differs from the last one sent, at most once every
/// `interval` seconds, never while Alexandre speaks nor within `afterSpeech` seconds of a spoken append, so it does
/// not ride along with speech. One per delegation.
public struct VoiceMasterStatus: Sendable {
  /// The master calls a tool every few seconds; GPT Live only needs the current state if he asks, and each append is
  /// one more chance to be said aloud.
  public static let interval: Double = 10
  public static let afterSpeech: Double = 3
  private var pending: String?
  private var last: String?
  private var nextAllowed: Double = 0
  public init() {}
  /// A state equal to the last one sent drops an older one still waiting: GPT Live already has the current one.
  public mutating func offer(_ text: String) { pending = text == last ? nil : text }
  public mutating func take(now: Double, userUntil: Double) -> String? {
    guard now >= userUntil, now >= nextAllowed, let pending else { return nil }
    self.pending = nil; last = pending; nextAllowed = now + Self.interval
    return pending
  }
  /// A spoken append went out: the next state waits for GPT Live to start saying it.
  public mutating func spoke(at now: Double) { nextAllowed = max(nextAllowed, now + Self.afterSpeech) }
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
  /// The line shown for an event. Only the master's own text (`Atualização: …`) is news to speak; the rest is
  /// `activity`.
  public static func describe(_ event: ConversationEvent) -> String? {
    if event.type == "session.tool.failed" { return "Uma ferramenta falhou. A mestra está verificando o resultado." }
    if event.type == "session.text.ended", let text = event.data.text, !text.isEmpty {
      return "Atualização: " + String(text.prefix(700))
    }
    if event.type == "session.step.failed" { return "Uma etapa da mestra falhou. Aguardando o resultado da execução." }
    return activity(event).map { "A mestra está " + $0 + "." }
  }
  /// What the master is doing, as a phrase in the present, without news words: the line on screen after "A mestra
  /// está" and, through `note`, GPT Live's quiet state. Tools and the failures the master recovers from.
  public static func activity(_ event: ConversationEvent) -> String? {
    if let call = call(event) {
      switch sessionTool(call.name).map({ "sessions." + $0 }) ?? String(call.name.split(separator: ".").last ?? Substring(call.name)) {
      case "sessions.read", "sessions.status": return "conferindo uma sessão"
      case "sessions.list": return "consultando suas sessões"
      case "sessions.send": return "encaminhando seu pedido"
      case "sessions.create": return "criando a sessão solicitada"
      case "sessions.wait": return "acompanhando o trabalho da sessão"
      case "sessions.requests": return "verificando os pedidos pendentes"
      case "sessions.answer": return "respondendo ao pedido autorizado"
      case "read", "grep", "glob": return "consultando os arquivos"
      case "execute": return "consultando as ferramentas"
      case "iphone_query", "iphone_status": return "consultando seu iPhone"
      default: return "usando uma ferramenta"
      }
    }
    if event.type == "session.tool.failed" { return "verificando o retorno de uma ferramenta que deu erro" }
    if event.type == "session.step.failed" { return "aguardando a execução seguir depois de uma etapa com erro" }
    return nil
  }
  /// The admitted request, before any tool: steer starts at once, queue waits for the work already running.
  public static func admitted(_ delivery: PromptDelivery) -> String {
    delivery == .queue ? "com o pedido na fila, esperando o trabalho atual" : "começando o pedido"
  }
  /// GPT Live's quiet state for an activity: a standing fact for when Alexandre asks, never news. That is what stayed
  /// quiet on `commentary` on 02/11 ("Progresso: o agente está contando as sessões."), while "a etapa terminou" was
  /// said. It names the agent, as the voice prompt does, never the master.
  public static func note(_ activity: String) -> String {
    "Estado do agente (para consulta; não é novidade para anunciar): " + activity
      + ". Pedido em andamento, ainda sem resultado."
  }
}

/// What GPT Live is given to say of the master's result. OpenAI's live delegation guide: return the relevant facts and
/// the status, and keep long output and Markdown meant for display in the backend. Markdown that should not be read
/// aloud is removed (a fenced code block becomes `code`, tables become plain lines, links their text), and the text
/// is cut to `limit` characters at a sentence or line end in its second half (else at a space), followed by `rest`.
/// The start is kept: the master is asked to lead with the result, status and next step. Same rule as the Watch's
/// `spoken` in `plugin-app-custom` (`src/watch/delegation.ts`).
public enum VoiceResult {
  public static let limit = 1_500
  public static let code = "(há código na resposta; veja na conversa)"
  public static let rest = "O restante da resposta está na conversa."
  public static func spoken(_ text: String) -> String {
    var lines: [String] = []
    var fence: Substring?
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    for line in normalized.components(separatedBy: "\n") {
      let marker = line.wholeMatch(of: /^ {0,3}(`{3,}|~{3,})(.*)$/)
      if let open = fence {
        // Closed by a bare fence of the same character, at least as long; an unclosed block runs to the end.
        if let marker, marker.1.first == open.first, marker.1.count >= open.count, marker.2.allSatisfy(\.isWhitespace) {
          fence = nil
        }
        continue
      }
      if let marker {
        fence = marker.1
        if lines.last(where: { !$0.isEmpty }) != code { lines.append(code) }
        continue
      }
      if let line = plain(line) { lines.append(line) }
    }
    let clean = lines.joined(separator: "\n").replacing(/\n{3,}/, with: "\n\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let characters = Array(clean)
    guard characters.count > limit else { return clean }
    let ends = stride(from: limit, through: limit / 2, by: -1)
    let cut = ends.first { characters[$0].isWhitespace && (characters[$0] == "\n" || ".!?…".contains(characters[$0 - 1])) }
      ?? ends.first { characters[$0].isWhitespace } ?? limit
    return String(characters[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + rest
  }
  /// A line as spoken; a table's divider row is dropped and a rule becomes a paragraph break.
  static func plain(_ line: String) -> String? {
    var text = line.trimmingCharacters(in: .whitespaces)
    if text.wholeMatch(of: /([-*_])(\s*\1){2,}/) != nil { return "" }
    text = text.replacing(/^(>\s?)+/, with: "")
    if text.wholeMatch(of: /\|[\s|:-]*/) != nil { return nil }
    if text.hasPrefix("|") {
      text = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
    return text.replacing(/^#{1,6}\s+/, with: "").replacing(/\s+#+$/, with: "")
      .replacing(/^(?:[-*+]|\d{1,3}[.)])\s+/, with: "").replacing(/^\[[ xX]\]\s+/, with: "")
      .replacing(/!?\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
      .replacing(/\*\*|__|`/, with: "")
  }
}
