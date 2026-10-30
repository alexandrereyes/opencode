#if DEBUG
import Foundation
import OpenCodeKit
import UIKit

/// Synthetic data only. The transport never falls through to URLSession, including writes.
@MainActor enum ScreenCatalogFixture {
  /// Own artwork, inline like PATCH /api/project/:id {icon:{override:"data:…"}}, with no server mutation.
  static let projectIcons: [String: String] = {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let png = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).image { context in
      UIColor(red: 0.08, green: 0.26, blue: 0.35, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
      UIColor(red: 0.36, green: 0.90, blue: 0.73, alpha: 1).setFill()
      UIBezierPath(roundedRect: CGRect(x: 24, y: 24, width: 80, height: 80), cornerRadius: 18).fill()
      UIColor(red: 0.08, green: 0.26, blue: 0.35, alpha: 1).setFill()
      UIBezierPath(ovalIn: CGRect(x: 45, y: 45, width: 38, height: 38)).fill()
    }.pngData()!
    let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128"><rect width="128" height="128" rx="24" fill="#573878"/><path d="M64 20 108 64 64 108 20 64Z" fill="#e7b6ff"/><circle cx="64" cy="64" r="17" fill="#573878"/></svg>"##
    return ["project_scroll_0": "data:image/png;base64," + png.base64EncodedString(),
      "project_scroll_2": "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()]
  }()
  static let scripts = try! JSONDecoder().decode([ShellInfo].self, from: Data(#"[{"id":"catalog-script","status":"running","command":"bun run preview --port 4321","metadata":{"sessionID":"ses_scroll_0000"},"time":{"started":1792576830000}}]"#.utf8))
  static let children = try! JSONDecoder().decode([Session].self, from: Data(#"[{"id":"ses_catalog_review","parentID":"ses_scroll_0000","projectID":"project_scroll_0","title":"Verificar a acessibilidade","agent":"build","model":{"id":"modelo-exemplo","providerID":"fixture","variant":"high"},"location":{"directory":"/Projetos/exemplo-0"},"time":{"created":1792576830000,"updated":1792576890000}},{"id":"ses_catalog_finished","parentID":"ses_scroll_0000","projectID":"project_scroll_0","title":"Revisar os filtros","agent":"plan","model":{"id":"modelo-exemplo","providerID":"fixture","variant":"low"},"outcome":"succeeded","location":{"directory":"/Projetos/exemplo-0"},"time":{"created":1792576840000,"updated":1792576950000,"idle":1792576950000}},{"id":"ses_catalog_older","parentID":"ses_scroll_0000","projectID":"project_scroll_0","title":"Conferir os atalhos","agent":"build","model":{"id":"modelo-rapido","providerID":"fixture"},"outcome":"succeeded","location":{"directory":"/Projetos/exemplo-0"},"time":{"created":1792576850000,"updated":1792576900000,"idle":1792576900000}}]"#.utf8))
  static let resources: [SessionResource] = [
    .init(id: "catalog-ios", kind: .iosSimulator, label: "iPhone de demonstração", purpose: "Conferir a navegação",
      owner: .init(sessionID: "ses_scroll_0000", rootSessionID: "ses_scroll_0000"), state: .idle,
      meta: .init(kind: "ios-simulator", device: "iPhone 17 Pro", runtime: "iOS 27.0")),
    .init(id: "catalog-android", kind: .androidEmulator, label: "Android de demonstração", purpose: "Verificar o layout",
      owner: .init(sessionID: "ses_scroll_0000", rootSessionID: "ses_scroll_0000"), state: .idle,
      meta: .init(kind: "android-emulator", avd: "Pixel de exemplo")),
    .init(id: "catalog-chrome", kind: .chrome, label: "Navegador de demonstração", purpose: "Revisar a versão web",
      owner: .init(sessionID: "ses_catalog_review", rootSessionID: "ses_scroll_0000", agent: "build"), state: .idle,
      meta: .init(kind: "chrome", url: "https://example.com", title: "Projeto de exemplo")),
  ]

  static func file(_ source: String) -> (data: Data, mime: String, text: String?)? {
    if source.hasSuffix("index.html") {
      let text = #"<!doctype html><html lang="pt-BR"><head><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="theme.css"></head><body><span class="badge">PROJETO DE EXEMPLO</span><h1>Uma navegação<br>mais simples.</h1><p>Um protótipo sintético para organizar ideias e validar os próximos passos.</p><section><h2>Próxima versão</h2><p>Filtros claros, atalhos acessíveis e conversas sempre à mão.</p><div class="metric">3 <small>melhorias planejadas</small></div></section><footer>HTML + CSS local · demonstração offline</footer></body></html>"#
      return (Data(text.utf8), "text/html", text)
    }
    if source.hasSuffix("README.md") {
      let text = "# Projeto de exemplo\n\nUma referência sintética para a navegação do aplicativo.\n\n## Próximos passos\n\n- Revisar os filtros.\n- Validar a acessibilidade.\n- Conferir os temas claro e escuro.\n\n> Nenhum dado pessoal é utilizado nesta demonstração."
      return (Data(text.utf8), "text/markdown", text)
    }
    guard source.hasSuffix("preview.png") else { return nil }
    let data = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
      UIColor(red: 0.10, green: 0.16, blue: 0.23, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
      UIColor(red: 0.27, green: 0.74, blue: 0.62, alpha: 1).setFill()
      UIBezierPath(roundedRect: CGRect(x: 80, y: 90, width: 480, height: 300), cornerRadius: 32).fill()
      ("Projeto de exemplo" as NSString).draw(at: CGPoint(x: 130, y: 215), withAttributes: [
        .font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.black,
      ])
    }.pngData()!
    return (data, "image/png", nil)
  }
  /// `-OpenCodeCatalogSections` fills every Sessões section: a question, a permission and a failure in
  /// "Precisa de você", a pinned session and older days. Without it, ses_scroll_0000 stays near the top.
  static let sections = ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogSections")
  static let permissions: [PermissionRequest] = sections ? try! JSONDecoder().decode([PermissionRequest].self, from: Data(#"[{"id":"per_catalog","sessionID":"ses_scroll_0004","action":"shell","resources":["git push origin versao-teste"]}]"#.utf8)) : []
  static let forms: [PendingForm] = sections ? try! JSONDecoder().decode([PendingForm].self, from: Data(#"[{"id":"frm_catalog","sessionID":"ses_scroll_0002","title":"Pergunta","fields":[{"key":"q0","type":"string","title":"Cache","description":"Qual banco usar no cache?"}]}]"#.utf8)) : []
  static let failures = sections ? ["ses_scroll_0005": "bun test falhou"] : [:]
  /// `-OpenCodeCatalogSettingsButton` shows the header's Mac-only Configurações button.
  static let settingsButton = ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogSettingsButton")
  /// `-OpenCodeCatalogActivity` runs the conversation: its answer gains an activity group (Ler, Shell, Agente,
  /// Editar) between two paragraphs, the tray shows the execution and two queued messages.
  static let activity = ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogActivity")
  static let active: Set<String> = activity ? ["ses_catalog_review", "ses_scroll_0000"] : ["ses_catalog_review"]
  static let inbox: [InboxItem] = {
    if activity {
      return try! JSONDecoder().decode([InboxItem].self, from: Data(#"[{"id":"msg_catalog_queued_1","sessionID":"ses_scroll_0000","type":"user","delivery":"queue","payload":{"text":"Depois, confira também a navegação por teclado."},"time":{"created":1792576799000}},{"id":"msg_catalog_queued_2","sessionID":"ses_scroll_0000","type":"user","delivery":"queue","payload":{"text":"Rode os testes de interface no tema claro e no escuro."},"time":{"created":1792576799500}}]"#.utf8))
    }
    guard ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogPending") else { return [] }
    return try! JSONDecoder().decode([InboxItem].self, from: Data(#"[{"id":"msg_catalog_pending","sessionID":"ses_scroll_0000","type":"user","delivery":"steer","payload":{"text":"Depois, confira também a navegação por teclado."},"time":{"created":1792576799000}}]"#.utf8))
  }()

  /// Você ▸ Snippets: globals, a project's (one replacing a global) and another project's; `-OpenCodeCatalogNoSnippets`
  /// shows the first-snippet state.
  static let snippets: [Snippet] = ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogNoSnippets") ? [] : [
    Snippet(id: "snp-commit", name: "commit-push-pr", aliases: ["cpp"], description: "Commit, push e abre o PR",
      content: "Faça o commit das mudanças, envie a branch e abra o pull request."),
    Snippet(id: "snp-ptbr", name: "ptbr", description: "Responde sempre em português",
      content: "Responda sempre em português do Brasil."),
    Snippet(id: "snp-resumo", name: "resumo", description: "Resume o que foi feito na sessão",
      content: "Resuma o que foi feito nesta sessão, em tópicos curtos."),
    Snippet(id: "snp-revisar", name: "revisar", aliases: ["review", "cr"], description: "Revisa o diff e aponta riscos",
      content: "Revise o diff atual e aponte bugs e riscos de regressão."),
    Snippet(id: "snp-capturas", name: "capturas", description: "Captura as telas no simulador",
      content: "Gere as capturas das telas no simulador, nos temas claro e escuro.", project: "project_scroll_0"),
    Snippet(id: "snp-revisar-projeto", name: "revisar", description: "Revisão com as regras do projeto",
      content: "Revise o diff atual seguindo o guia do projeto.\n- Aponte bugs e riscos de regressão.\n- Responda em tópicos curtos.",
      project: "project_scroll_0"),
    Snippet(id: "snp-atualizacoes", name: "atualizacoes", description: "Verifica as atualizações das dependências",
      content: "Verifique se há atualizações das dependências e resuma as mudanças.", project: "project_scroll_0"),
    Snippet(id: "snp-testes", name: "testes", description: "Gera e executa os testes relevantes",
      content: "Escreva e rode os testes relevantes para a mudança.", project: "project_scroll_2"),
  ]

  static func snapshot(_ source: ScrollFixtureSnapshot) -> ScrollFixtureSnapshot {
    let encoded = String(decoding: try! JSONEncoder().encode(Array(source.entries.prefix(11))), as: UTF8.self)
      .replacingOccurrences(of: "\\/", with: "/")
      .replacingOccurrences(of: "Sessão de exemplo 000 — revisão do projeto e ferramentas", with: "Revisar a navegação do aplicativo")
      .replacingOccurrences(of: "Sessão de exemplo 001 — revisão do projeto e ferramentas", with: "Organizar o roteiro da próxima versão")
      .replacingOccurrences(of: "/Projetos/exemplo-1", with: "/Chats/roteiro")
    let titles = ["Escolher o banco do cache", "Atualizar a documentação", "Publicar a versão de teste",
      "Rodar a suíte de testes", "Planejar a próxima versão", "Ideias para a barra lateral",
      "Revisar o contraste dos temas", "Atualizar o changelog", "Migrar as preferências antigas"]
    // Times relative to launch keep the day sections and elapsed labels stable between captures.
    let now = Date.now.timeIntervalSince1970 * 1000
    let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970 * 1000
    let minute = 60_000.0
    let todayAt = { (ago: Double) in min(now, max(now - ago * minute, today + minute)) }
    let times: [Double] = [
      now - 5 * minute, todayAt(30), todayAt(sections ? 1 : 40), todayAt(120), todayAt(sections ? 3 : 180),
      sections ? now - 12 * minute : today - 600 * minute, now - 3 * 1440 * minute, today - 840 * minute,
      today - 3 * 1440 * minute + 600 * minute, today - 600 * minute, today - 12 * 1440 * minute,
    ]
    let unread = ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogUnread")
    let values = try! JSONDecoder().decode([[String: JSONValue]].self, from: Data(encoded.utf8)).enumerated().map { index, value in
      var value = value
      var session = value["session"]!.object!
      var time = session["time"]!.object!
      for key in ["created", "updated", "idle"] { time[key] = .number(times[index]) }
      // Read sessions stay read at their new times; the failure is unseen.
      if time["viewed"] != .number(0) { time["viewed"] = .number(sections && index == 5 ? 0 : times[index]) }
      value["messageAt"] = .number(times[index])
      if index >= 2 { session["title"] = .string(titles[index - 2]) }
      if sections && index == 5 { session["outcome"] = .string("failed") }
      if sections && index == 2 { value["questionAt"] = .number(times[index]) }
      if sections && index == 4 { value["permissionAt"] = .number(times[index]) }
      // A watermark after all fixture timestamps leaves only the selected repository unread.
      if unread { time["viewed"] = .number(session["projectID"]?.string == "project_scroll_3" ? 0 : 4_000_000_000_000) }
      session["time"] = .object(time)
      value["session"] = .object(session)
      return value
    }
    let entries = try! JSONDecoder().decode([NavigationEntry].self, from: JSONEncoder().encode(values))
    var messages = try! JSONDecoder().decode([ConversationMessage].self, from: Data(#"""
      [{"id":"msg_catalog_user","type":"user","time":{"created":1792576800000},"text":"Revise a navegação do aplicativo e proponha uma organização mais simples.\n\nConsidere as abas principais, o acesso às conversas e os atalhos de criação. Preserve a hierarquia visual e os controles de acessibilidade.\n\nApresente um resumo das mudanças, sem alterar os arquivos por enquanto."},
       {"id":"msg_catalog_answer","type":"assistant","agent":"build","model":{"id":"modelo-exemplo","providerID":"fixture","variant":"high"},"tokens":{"input":6000,"output":7000,"reasoning":0,"cache":{"read":63000,"write":0}},"time":{"created":1792576810000,"completed":1792576815000},"finish":"stop","content":[{"type":"text","text":"## Uma navegação mais simples\n\nA proposta mantém as cinco abas e dá mais destaque às **conversas recentes**.\n\n- Criar uma sessão em um único toque.\n- Agrupar filtros por projeto.\n- Manter os ajustes na aba Você.\n\nNenhum arquivo foi alterado. Podemos começar pelos filtros e validar o resultado antes de seguir."}]}]
      """#.utf8))
    messages[1].content?[0].text? += "\n\n### Próxima etapa\n\nVamos comparar os caminhos de entrada, organizar os atalhos e validar cada mudança com um cenário pequeno. A navegação deve continuar previsível, tanto com o teclado aberto quanto durante a leitura de uma resposta longa.\n\nO resultado esperado é uma interface com ações fáceis de encontrar e contexto suficiente para retomar o trabalho."
    if activity {
      // The running execution started 2m40s before launch, so the tray's elapsed time is stable between captures.
      let start = now - 160_000
      let text = messages[1].content![0].text!
      let split = text.range(of: "\n\nO resultado esperado")!
      messages[1].time.created = start
      messages[1].time.completed = nil
      messages[1].finish = nil
      let old = (1...3).map { "  let rota\($0) = Rota.antiga(\($0))" }.joined(separator: "\\n")
      let new = (1...12).map { "  let atalho\($0) = Atalho.novo(\($0))" }.joined(separator: "\\n")
      let tools = [
        ("read", #"{"path":"/Projetos/exemplo-0/Sources/SessionsView.swift"}"#, "{}", 2.0, 14.0),
        ("shell", #"{"command":"git status"}"#, "{}", 15, 21),
        ("subagent", #"{"agent":"explore","description":"Mapear navegação"}"#, #"{"sessionID":"ses_catalog_finished"}"#, 22, 94),
        ("edit", #"{"path":"/Projetos/exemplo-0/Sources/ChatView.swift","oldString":"\#(old)","newString":"\#(new)"}"#, "{}", 95, 143),
      ].enumerated().map { index, tool in
        #"{"type":"tool","id":"call_catalog_\#(index)","name":"\#(tool.0)","state":{"status":"completed","input":\#(tool.1),"metadata":\#(tool.2)},"time":{"created":\#(start + tool.3 * 1000),"completed":\#(start + tool.4 * 1000)}}"#
      }
      var content = try! JSONDecoder().decode([ConversationPart].self, from: Data("[\(tools.joined(separator: ","))]".utf8))
      content.insert(ConversationPart(type: "text", text: String(text[..<split.lowerBound])), at: 0)
      content.append(ConversationPart(type: "text", text: "O resultado esperado" + text[split.upperBound...]))
      messages[1].content = content
    }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogShort") {
      messages[0].text = "Como podemos simplificar a navegação?"
    }
    let preferencesJSON = String(decoding: try! JSONEncoder().encode(source.preferences), as: UTF8.self)
      .replacingOccurrences(of: "\"settings\":", with: "\"notifySessions\":[\"ses_scroll_0000\"],\"settings\":")
      .replacingOccurrences(of: #""pinnedSessions":[]"#, with: sections ? #""pinnedSessions":["ses_scroll_0006"]"# : #""pinnedSessions":[]"#)
      .replacingOccurrences(of: "\"settings\":", with: #""models":{"user":[{"providerID":"fixture","modelID":"modelo-exemplo","visibility":"show"},{"providerID":"fixture","modelID":"modelo-rapido","visibility":"show"}],"variant":{}},"settings":"#)
    let preferences = try! JSONDecoder().decode(Preferences.self, from: Data(preferencesJSON.utf8))
    let models = try! JSONDecoder().decode([ModelInfo].self, from: Data(#"[{"id":"modelo-exemplo","providerID":"fixture","name":"Modelo Exemplo","limit":{"context":200000},"variants":[{"id":"low"},{"id":"high"}]},{"id":"modelo-rapido","providerID":"fixture","name":"Modelo Rápido","limit":{"context":128000}}]"#.utf8))
    let projects = source.projects.map { project in
      guard let icon = projectIcons[project.id] else { return project }
      var value = try! JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(project))
      value["icon"] = .object(["override": .string(icon)])
      return try! JSONDecoder().decode(Project.self, from: JSONEncoder().encode(value))
    }
    return ScrollFixtureSnapshot(messages: messages, entries: entries, projects: projects,
      preferences: preferences, models: models)
  }

  static func client(_ configuration: ServerConfiguration) -> OpenCodeClient {
    let snapshot = ScrollFixtures.snapshot
    func encode<T: Encodable>(_ value: T) -> String {
      String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
    let responses = [
      "/api/model": "{\"data\":\(encode(snapshot.models))}",
      "/api/model/default": "{\"data\":\(encode(snapshot.models[0]))}",
      "/api/agent": #"{"data":[{"id":"build","name":"Build","mode":"primary"},{"id":"plan","name":"Plan","mode":"primary"}]}"#,
      "/api/provider": #"{"data":[{"id":"fixture","name":"Modelos de demonstração"}]}"#,
      "/api/config": "[]",
      "/api/mcp": #"{"data":[{"name":"safari-devtools","status":{"status":"connected"}},{"name":"figma","status":{"status":"disabled"}}]}"#,
      "/api/project": encode(snapshot.projects),
      "/api/worktree": "[]",
      "/api/worktree/refresh": "{}",
      "/api/vcs": #"{"data":{"provider":"git","branch":{"current":"main"}}}"#,
      "/api/rpc/custom.worktrees/branches": #"{"output":[]}"#,
      "/api/rpc/custom.preferences/get": "{\"output\":\(encode(snapshot.preferences))}",
      "/api/rpc/custom.preferences/mutate": "{\"output\":\(encode(snapshot.preferences))}",
      "/api/rpc/custom.session-family/page": #"{"output":{"data":[]}}"#,
      "/api/rpc/custom.session-family/snapshot": #"{"output":{"count":0,"permissions":[],"forms":[],"active":[]}}"#,
      "/api/session/active": #"{"data":{}}"#,
      "/api/session": #"{"data":[],"cursor":{}}"#,
      "/api/rpc/custom.directories/home": #"{"output":"/Projetos"}"#,
      "/api/rpc/custom.worktrees/locate": #"{"output":[]}"#,
      "/api/fs/list": #"{"location":{"directory":"/Projetos/exemplo-0"},"data":[{"path":"Sources","type":"directory"},{"path":"README.md","type":"file"},{"path":"index.html","type":"file"},{"path":"preview.png","type":"file"}]}"#,
      "/api/fs/read/theme.css": "body{margin:0;padding:32px 24px;background:#12202b;color:#f3f4f0;font:17px -apple-system,sans-serif}h1{font-size:42px;line-height:1.1;margin:24px 0}p{line-height:1.6;color:#bdcdd4}.badge{font-size:11px;letter-spacing:2px;color:#7ee0bf}section{margin-top:32px;padding:24px;border:1px solid #38515e;border-radius:20px;background:#1b303c}h2{margin-top:0;font-size:23px}.metric{color:#7ee0bf;font-size:46px;font-weight:700}small{display:block;color:#bdcdd4;font-size:14px;font-weight:400}footer{margin-top:28px;font-size:12px;color:#8da5b2}",
      "/api/rpc/custom.chats/info": #"{"output":{"root":"/Chats"}}"#,
      "/api/rpc/custom.master/info": #"{"output":{"version":1,"agent":"build","model":{"id":"modelo-exemplo","providerID":"fixture"}}}"#,
      "/api/rpc/custom.snippets/list": "{\"output\":{\"items\":\(encode(snippets))}}",
    ]
    return .screenCatalog(configuration: configuration, responses: responses)
  }
}
#endif
