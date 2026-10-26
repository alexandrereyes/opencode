#if DEBUG
import Foundation
import OpenCodeKit
import UIKit

/// Synthetic data only. The transport never falls through to URLSession, including writes.
@MainActor enum ScreenCatalogFixture {
  static let scripts = try! JSONDecoder().decode([ShellInfo].self, from: Data(#"[{"id":"catalog-script","status":"running","command":"bun run preview --port 4321","metadata":{"sessionID":"ses_scroll_0000"},"time":{"started":1792576830000}}]"#.utf8))
  static let children = try! JSONDecoder().decode([Session].self, from: Data(#"[{"id":"ses_catalog_review","parentID":"ses_scroll_0000","projectID":"project_scroll_0","title":"Verificar a acessibilidade","agent":"build","model":{"id":"modelo-exemplo","providerID":"fixture"},"location":{"directory":"/Projetos/exemplo-0"},"time":{"created":1792576830000,"updated":1792576830000}}]"#.utf8))
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
  static func snapshot(_ source: ScrollFixtureSnapshot) -> ScrollFixtureSnapshot {
    let encoded = String(decoding: try! JSONEncoder().encode(Array(source.entries.prefix(8))), as: UTF8.self)
      .replacingOccurrences(of: "\\/", with: "/")
      .replacingOccurrences(of: "Sessão de exemplo 000 — revisão do projeto e ferramentas", with: "Revisar a navegação do aplicativo")
      .replacingOccurrences(of: "Sessão de exemplo 001 — revisão do projeto e ferramentas", with: "Organizar o roteiro da próxima versão")
      .replacingOccurrences(of: "/Projetos/exemplo-1", with: "/Chats/roteiro")
    let entries: [NavigationEntry]
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogUnread") {
      let values = try! JSONDecoder().decode([[String: JSONValue]].self, from: Data(encoded.utf8)).map { value in
        var value = value
        var session = value["session"]!.object!
        var time = session["time"]!.object!
        // A watermark after all fixed fixture timestamps leaves only the selected repository unread.
        time["viewed"] = .number(session["projectID"]?.string == "project_scroll_3" ? 0 : 2_000_000_000_000)
        session["time"] = .object(time)
        value["session"] = .object(session)
        return value
      }
      entries = try! JSONDecoder().decode([NavigationEntry].self, from: JSONEncoder().encode(values))
    } else {
      entries = try! JSONDecoder().decode([NavigationEntry].self, from: Data(encoded.utf8))
    }
    var messages = try! JSONDecoder().decode([ConversationMessage].self, from: Data(#"""
      [{"id":"msg_catalog_user","type":"user","time":{"created":1792576800000},"text":"Revise a navegação do aplicativo e proponha uma organização mais simples.\n\nConsidere as abas principais, o acesso às conversas e os atalhos de criação. Preserve a hierarquia visual e os controles de acessibilidade.\n\nApresente um resumo das mudanças, sem alterar os arquivos por enquanto."},
       {"id":"msg_catalog_answer","type":"assistant","agent":"build","model":{"id":"modelo-exemplo","providerID":"fixture","variant":"high"},"tokens":{"input":6000,"output":7000,"reasoning":0,"cache":{"read":63000,"write":0}},"time":{"created":1792576810000,"completed":1792576815000},"finish":"stop","content":[{"type":"text","text":"## Uma navegação mais simples\n\nA proposta mantém as cinco abas e dá mais destaque às **conversas recentes**.\n\n- Criar uma sessão em um único toque.\n- Agrupar filtros por projeto.\n- Manter os ajustes na aba Você.\n\nNenhum arquivo foi alterado. Podemos começar pelos filtros e validar o resultado antes de seguir."}]}]
      """#.utf8))
    messages[1].content?[0].text? += "\n\n### Próxima etapa\n\nVamos comparar os caminhos de entrada, organizar os atalhos e validar cada mudança com um cenário pequeno. A navegação deve continuar previsível, tanto com o teclado aberto quanto durante a leitura de uma resposta longa.\n\nO resultado esperado é uma interface com ações fáceis de encontrar e contexto suficiente para retomar o trabalho."
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeCatalogShort") {
      messages[0].text = "Como podemos simplificar a navegação?"
    }
    let preferencesJSON = String(decoding: try! JSONEncoder().encode(source.preferences), as: UTF8.self)
      .replacingOccurrences(of: "\"settings\":", with: #""models":{"user":[{"providerID":"fixture","modelID":"modelo-exemplo","visibility":"show"},{"providerID":"fixture","modelID":"modelo-rapido","visibility":"show"}],"variant":{}},"settings":"#)
    let preferences = try! JSONDecoder().decode(Preferences.self, from: Data(preferencesJSON.utf8))
    let models = try! JSONDecoder().decode([ModelInfo].self, from: Data(#"[{"id":"modelo-exemplo","providerID":"fixture","name":"Modelo Exemplo","limit":{"context":200000},"variants":[{"id":"low"},{"id":"high"}]},{"id":"modelo-rapido","providerID":"fixture","name":"Modelo Rápido","limit":{"context":128000}}]"#.utf8))
    return ScrollFixtureSnapshot(messages: messages, entries: entries, projects: source.projects,
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
      "/api/fs/list": #"{"location":{"directory":"/Projetos/exemplo-0"},"data":[{"path":"Sources","type":"directory"},{"path":"README.md","type":"file"},{"path":"preview.png","type":"file"}]}"#,
      "/api/rpc/custom.chats/info": #"{"output":{"root":"/Chats"}}"#,
      "/api/rpc/custom.master/info": #"{"output":{"version":1,"agent":"build","model":{"id":"modelo-exemplo","providerID":"fixture"}}}"#,
    ]
    return .screenCatalog(configuration: configuration, responses: responses)
  }
}
#endif
