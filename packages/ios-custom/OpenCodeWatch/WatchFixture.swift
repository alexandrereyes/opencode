import Foundation
import OpenCodeKit

/// DEBUG-only screens for captures: `-OpenCodeWatchFixture dashboard|question|permission|voice|unpaired|offline|
/// complications`, optionally with `-OpenCodeWatchCombo working|working-unread|question-working-unread|nothing` for
/// the state ring's combinations. Fixtures never touch the network, the Keychain or the shared cache.
struct WatchFixture {
  enum Screen: String {
    case dashboard, question, permission, voice, unpaired, offline, complications
    case dashboardEnd = "dashboard-end"
  }

  let screen: Screen

  /// DEBUG only: the `OpenCodeWatchPairing` default (base64 JSON, set with `simctl spawn <udid> defaults write
  /// br.com.alexandrem.opencode.watchkitapp OpenCodeWatchPairing -string …`; a launch argument would be parsed as a
  /// property list, where `=` breaks it) stores a pairing at every launch, so a simulator can talk to a sandbox gateway
  /// without the iPhone, also when the system relaunches the app for a background refresh.
  static let injectedPairing: WatchPairing? = {
    #if DEBUG
      UserDefaults.standard.string(forKey: "OpenCodeWatchPairing").flatMap { Data(base64Encoded: $0) }
        .flatMap { try? JSONDecoder().decode(WatchPairing.self, from: $0) }
    #else
      nil
    #endif
  }()

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

  /// The state ring's combinations (rev. 30/10), each with sessions that match its counts.
  enum Combo: String {
    case working, workingUnread = "working-unread", questionWorkingUnread = "question-working-unread", nothing

    func state(now: Int) -> String {
      let work = """
        {"sessionID":"s2","title":"Live Activity no iOS","project":"ios","directory":"/r/ios","status":"working"},
        {"sessionID":"s3","title":"Deploy no Swarm","project":"infra","directory":"/r/infra","status":"working"}
        """
      let question = """
        {"sessionID":"s1","title":"Escolher banco do cache","project":"core","directory":"/r/core","kind":"question",
         "since":\(now - 180_000),"text":"Qual banco usar no cache das sessões?","requestID":"fixture-question"}
        """
      let unread = { (id: String, title: String, ago: Int) in
        """
        {"sessionID":"\(id)","title":"\(title)","project":"ios","directory":"/r/ios","kind":"unread","since":\(now - ago)}
        """
      }
      let row = { (id: String, title: String, status: String) in
        #"{"sessionID":"\#(id)","title":"\#(title)","project":"ios","directory":"/r/ios","status":"\#(status)"}"#
      }
      let (counts, active, attention, needs, sessions): (String, Int, String, String, String) =
        switch self {
        case .working:
          (#""working":3,"question":0,"permission":0,"failed":0,"idle":0,"unread":0"#, 3, "", "",
           work + "," + row("s4", "Revisar contrato do relógio", "working"))
        case .workingUnread:
          (#""working":2,"question":0,"permission":0,"failed":0,"idle":2,"unread":2"#, 2, "",
           unread("s5", "Gravador de voz", 360_000) + "," + unread("s6", "Anel do relógio", 600_000),
           work + "," + row("s5", "Gravador de voz", "idle") + "," + row("s6", "Anel do relógio", "idle"))
        case .questionWorkingUnread:
          (#""working":2,"question":1,"permission":0,"failed":0,"idle":1,"unread":1"#, 3, question,
           question + "," + unread("s5", "Gravador de voz", 360_000),
           row("s1", "Escolher banco do cache", "question") + "," + work + "," + row("s5", "Gravador de voz", "idle"))
        case .nothing: ("", 0, "", "", "")
        }
      guard self != .nothing else { return #"{"state":null,"host":"MacBook Pro"}"# }
      return """
        {"state":{"v":1,"updatedAt":\(now),"host":"MacBook Pro","counts":{\(counts)},"activeTotal":\(active),
         "attention":[\(attention)],"attentionTotal":\(attention.isEmpty ? 0 : 1),"needs":[\(needs)],
         "sessions":[\(sessions)]},"host":"MacBook Pro"}
        """
    }
  }

  static let combo: Combo? = {
    #if DEBUG
      UserDefaults.standard.string(forKey: "OpenCodeWatchCombo").flatMap(Combo.init(rawValue:))
    #else
      nil
    #endif
  }()

  var entry: WatchStateCache.Entry? {
    guard screen != .unpaired else { return nil }
    let now = Date()
    let ms = { (date: Date) in Int((date.timeIntervalSince1970 * 1000).rounded()) }
    let json = Self.combo?.state(now: ms(now)) ?? """
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
    // Offline and the complications show an older read, so their captures show the relative age.
    let age: TimeInterval = screen == .offline ? 7 * 60 : screen == .complications ? 4 * 60 : 0
    return WatchStateCache.Entry(snapshot: snapshot, fetched: now - age)
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
