#if DEBUG
import AppKit
import OpenCodeKit

/// `-OpenCodeMacVoiceScreenCheck own|denied|first|granted|display|missing` against an isolated sandbox server, with
/// `-OpenCodeVoiceScreenFixture`: GPT Live is simulated and the real Sessão mestra receives the capture. A fake
/// system replaces the front app, the window list and Screen Recording, so nothing asks macOS for permission and
/// Alexandre's apps are never read. OpenCode's own window is captured for real (no permission needed), off-screen
/// and without activating the app. Prints `MacVoiceScreen outcome: …` and quits.
@MainActor enum MacVoiceScreenCheck {
  static let scenario = MacFixture.value("-OpenCodeMacVoiceScreenCheck")

  static func run(_ runtime: MacWindowRuntime) async {
    guard let scenario else { return }
    setvbuf(stdout, nil, _IOLBF, 0)
    print("MacVoiceScreen start: \(scenario)")
    for _ in 0..<200 where runtime.store == nil || runtime.window == nil { try? await Task.sleep(for: .milliseconds(100)) }
    guard let window = runtime.window else { print("MacVoiceScreen outcome: no-window"); exit(3) }
    guard let sessions = runtime.store, sessions.client.configuration.isolatedTestSandbox else {
      print("MacVoiceScreen outcome: refused-not-sandbox"); exit(2)
    }
    if let id = MacFixture.value("-OpenCodeMacVoiceScreenSession") { runtime.select(id) }
    window.setFrame(NSRect(x: -4000, y: 40, width: 1500, height: 940), display: true)
    let fake = MacScreenFake(scenario: scenario)
    MacVoiceScreen.system = fake
    try? await Task.sleep(for: .seconds(4))
    let voice = runtime.app.audio.voice
    voice.start(sessions: sessions)
    for _ in 0..<300 where voice.screenOutcome.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
    print("MacVoiceScreen voice: \(voice.state.phase) \(voice.detail)")
    print("MacVoiceScreen outcome: \(voice.screenOutcome.isEmpty ? "timeout" : voice.screenOutcome)")
    print("MacVoiceScreen permission requested: \(fake.requested)")
    print("MacVoiceScreen toast: \(voice.toast.message?.text ?? "-") [\(voice.toast.message?.action ?? "-")]")
    if let folder = MacFixture.value("-OpenCodeMacVoiceScreenEvidence"),
      let image = MacVoiceScreen.ownImage(window), let data = try? MacVoiceScreen.jpeg(image) {
      try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(scenario)-window.jpg"))
    }
    try? await Task.sleep(for: .seconds(1))
    await voice.end()
    exit(0)
  }
}

/// Another app in front ("Google Chrome", a pid OpenCode never owns) unless the scenario puts OpenCode there.
@MainActor final class MacScreenFake: MacScreenSystem {
  private let scenario: String
  private(set) var requested = false
  var asked: Bool
  init(scenario: String) {
    self.scenario = scenario
    asked = scenario == "denied"
  }
  private static let chrome: Int32 = 999_999
  var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }
  var frontPID: Int32? { scenario == "own" ? ownPID : Self.chrome }
  var apps: [VoiceScreenPlanner.App] {
    [.init(pid: ownPID, name: "OpenCode"), .init(pid: Self.chrome, name: "Google Chrome")]
  }
  var windows: [VoiceScreenWindow] {
    [VoiceScreenWindow(id: 900_001, pid: Self.chrome, app: "Google Chrome", title: "Documentação da API",
      frame: CGRect(x: 0, y: 0, width: 1200, height: 800))]
  }
  var displays: [VoiceScreenPlanner.Display] { [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))] }
  var permission: Bool { ["granted", "display"].contains(scenario) }
  func requestPermission() { requested = true }
  var ownWindow: (window: NSWindow, sessionID: String?)? {
    let runtime = MacRuntime.shared.front
    return runtime?.window.map { ($0, runtime?.selection.sessionID) }
  }
  func capture(own window: NSWindow) -> CGImage? { MacVoiceScreen.ownImage(window) }
  /// A drawn stand-in for another app's window or the display: never a picture of Alexandre's screen.
  func capture(_ source: VoiceScreenSource) async throws(VoiceScreenRefusal) -> CGImage {
    let size = source == .own ? CGSize(width: 10, height: 10) : CGSize(width: 1600, height: 1000)
    let image = NSImage(size: size, flipped: false) { rect in
      NSColor.systemTeal.setFill(); rect.fill()
      let text = VoiceScreenPlanner.subject(source) as NSString
      text.draw(at: CGPoint(x: 60, y: rect.midY), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.white])
      return true
    }
    guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw .failed }
    return picture
  }
}
#endif
