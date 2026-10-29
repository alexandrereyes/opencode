#if DEBUG
import Foundation
import OpenCodeKit

enum VoiceBarFixtures {
  static let names = ["listening", "speaking", "thinking", "connecting", "reconnecting", "offline", "muted", "error", "idle", "long", "interrupted"]
  static let launchState: VoiceBarState? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let server = arguments.firstIndex(of: "-OpenCodeServerURL"), arguments.indices.contains(server + 1),
      URL(string: arguments[server + 1]).map { ServerConfiguration(url: $0).isolatedTestSandbox } == true,
      let index = arguments.firstIndex(of: "-OpenCodeVoiceBarFixture"), arguments.indices.contains(index + 1)
    else { return nil }
    return state(arguments[index + 1])
  }()

  static func state(_ name: String) -> VoiceBarState? {
    guard names.contains(name) else { return nil }
    let phase: VoiceBarState.Phase = switch name {
    case "speaking", "long": .speaking
    case "thinking": .thinking
    case "connecting": .connecting
    case "reconnecting": .reconnecting
    case "offline": .offline
    case "error": .failed
    case "interrupted": .interrupted
    default: .listening
    }
    return .init(phase: phase, elapsed: name == "connecting" ? 0 : 134,
      transcript: name == "long"
        ? String(repeating: "Três sessões esperam você. Posso abrir a primeira para conferir os detalhes? ", count: 8)
        : "Três sessões esperam você. Abro a primeira?",
      masterProgress: ["speaking", "thinking", "long"].contains(name) ? "lendo 3 sessões…" : nil,
      muted: name == "muted", error: name == "error" ? "A conexão caiu. Confira sua rede e tente novamente." : nil)
  }
}
#endif
