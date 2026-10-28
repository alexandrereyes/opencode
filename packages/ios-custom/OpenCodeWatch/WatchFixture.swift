import Foundation
import OpenCodeKit

/// DEBUG-only screens for captures: `-OpenCodeWatchFixture dashboard|question|permission|voice|unpaired|offline|
/// complications`. Fixtures never touch the network, the Keychain or the shared cache.
struct WatchFixture {
  enum Screen: String {
    case dashboard, question, permission, voice, unpaired, offline, complications
    case dashboardEnd = "dashboard-end"
  }

  let screen: Screen

  static let launch: WatchFixture? = {
    #if DEBUG
      UserDefaults.standard.string(forKey: "OpenCodeWatchFixture").flatMap(Screen.init(rawValue:))
        .map(WatchFixture.init(screen:))
    #else
      nil
    #endif
  }()

  var pairing: WatchPairing? {
    screen == .unpaired ? nil : WatchPairing(deviceID: "fixture", deviceToken: "fixture",
      gatewayURL: URL(string: "https://fixture.invalid")!, access: .init(clientId: "-", clientSecret: "-"),
      voice: .init(voiceID: "rio"))
  }

  var connection: WatchModel.Connection {
    switch screen {
    case .unpaired: .unpaired
    case .offline: .unreachable
    default: .online
    }
  }

  var entry: WatchStateCache.Entry? {
    guard screen != .unpaired else { return nil }
    let now = Date()
    let ms = { (date: Date) in Int((date.timeIntervalSince1970 * 1000).rounded()) }
    let json = """
      {"state":{"v":1,"updatedAt":\(ms(now)),"host":"MacBook Pro",
       "counts":{"working":3,"question":1,"permission":0,"failed":0,"idle":1,"unread":1},"activeTotal":4,
       "attention":[{"sessionID":"s1","title":"Escolher banco do cache","project":"core","directory":"/r/core",
         "kind":"question","since":\(ms(now - 180)),"text":"Qual banco usar no cache das sessões?",
         "requestID":"fixture-question"}],
       "attentionTotal":1,
       "sessions":[
         {"sessionID":"s1","title":"Escolher banco do cache","project":"core","directory":"/r/core","status":"question"},
         {"sessionID":"s2","title":"Live Activity no iOS","project":"ios","directory":"/r/ios","status":"working",
          "progress":{"done":2,"total":3,"unit":"subagents"}},
         {"sessionID":"s3","title":"Deploy no Swarm","project":"infra","directory":"/r/infra","status":"working"},
         {"sessionID":"s4","title":"Revisar contrato do relógio","project":"plugin","directory":"/r/plugin",
          "status":"working"}]},
       "host":"MacBook Pro"}
      """
    let snapshot = try! JSONDecoder().decode(WatchStateSnapshot.self, from: Data(json.utf8))
    return WatchStateCache.Entry(snapshot: snapshot, fetched: screen == .offline ? now - 7 * 60 : now)
  }

  static let question: WatchRequest = try! JSONDecoder().decode(WatchRequest.self, from: Data("""
    {"kind":"question","requestID":"fixture-question","sessionID":"s1","title":"Escolher banco do cache",
     "project":"core","since":\((Date().timeIntervalSince1970 - 180) * 1000),
     "questions":[{"id":"q1","text":"Qual banco usar no cache das sessões?","multiple":false,"allowText":true,
     "options":[{"id":"pg","label":"Postgres"},{"id":"sqlite","label":"SQLite","recommended":true},
     {"id":"redis","label":"Redis"}]}]}
    """.utf8))

  static let permission: WatchRequest = try! JSONDecoder().decode(WatchRequest.self, from: Data("""
    {"kind":"permission","requestID":"fixture-permission","sessionID":"s5","title":"Rodar testes do OAuth",
     "project":"core","since":\((Date().timeIntervalSince1970 - 60) * 1000),"action":"bash",
     "resources":["bun test --filter oauth"],"summary":"bash · bun test --filter oauth"}
    """.utf8))
}
