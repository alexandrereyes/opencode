#if DEBUG
import AppKit
import Darwin
import OpenCodeKit

/// `-OpenCodeMacPerf`: the main thread's cost with sessions streaming and while typing, against the fixture. Six
/// sessions (three roots and three subagents of the shown root) stream text deltas through the event hub at 25 Hz
/// each, with one structural event per session a second (a list reload, previews); the fixture's streaming sessions
/// change their update time and preview text as a real server's would. Phases: quiet, streaming, typing alone and
/// typing while streaming. Each prints the main thread's CPU share, how late a main-queue ping runs, the views
/// whose `body` ran (per second, or per key while typing) and the cost of a key: `sendEvent` through the window
/// plus the layout and display it leaves pending. The app quits at the end.
@MainActor enum MacPerf {
  nonisolated static let enabled = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacPerf")
  /// The shown root streams too (`-OpenCodeMacPerfShown`), not only other sessions and its subagents.
  nonisolated static let shownStreams = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacPerfShown")
  private static var counts: [String: Int] = [:]
  private static var started = false
  private static let mainThread = mach_thread_self()

  static func count(_ name: String) {
    guard enabled else { return }
    counts[name, default: 0] += 1
  }

  static func run(runtime: MacWindowRuntime) async {
    guard enabled, !started else { return }
    started = true
    _ = mainThread
    try? await Task.sleep(for: .seconds(6))
    guard let store = runtime.store, let window = runtime.window, let id = runtime.selection.sessionID,
      let input = runtime.drafts.draft(id).input else { return finish("sem janela, sessão ou composer") }
    window.makeFirstResponder(input.textView)
    try? await Task.sleep(for: .seconds(1))
    await phase("parado", seconds: 5)
    let stream = Task { await streamEvents(store.hub) }
    try? await Task.sleep(for: .seconds(2))
    await phase("transmitindo", seconds: 6)
    stream.cancel()
    try? await Task.sleep(for: .seconds(3))
    await typing("digitando", window: window, input: input, keys: 50)
    let again = Task { await streamEvents(store.hub) }
    try? await Task.sleep(for: .seconds(2))
    await typing("digitando+transmitindo", window: window, input: input, keys: 50)
    again.cancel()
    finish("ok")
  }

  private static func phase(_ name: String, seconds: Double) async {
    // `-OpenCodeMacPerfHold <s>`: longer phases, to `sample` one from outside.
    let seconds = MacFixture.value("-OpenCodeMacPerfHold").flatMap(Double.init) ?? seconds
    print("MacPerf início \(name)")
    fflush(stdout)
    counts = [:]
    let ping = Ping()
    let cpu = mainCPU()
    let start = CACurrentMediaTime()
    try? await Task.sleep(for: .seconds(seconds))
    let wall = CACurrentMediaTime() - start
    let busy = (mainCPU() - cpu) / wall
    report(name, busy: busy, ping: ping.stop(), per: wall, unit: "s", keys: nil)
  }

  private static func typing(_ name: String, window: NSWindow, input: ComposerInputView, keys: Int) async {
    let keys = MacFixture.value("-OpenCodeMacPerfKeys").flatMap(Int.init) ?? keys
    print("MacPerf início \(name)")
    fflush(stdout)
    counts = [:]
    let ping = Ping()
    let cpu = mainCPU()
    let start = CACurrentMediaTime()
    var costs: [Double] = []
    var cpus: [Double] = []
    let before = input.textStorage.length
    for index in 0..<keys {
      let character = index % 6 == 5 ? " " : String("abcdefghij".randomElement()!)
      let wall = CACurrentMediaTime()
      let thread = mainCPU()
      if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
        isARepeat: false, keyCode: character == " " ? 49 : 0) { window.sendEvent(event) }
      window.layoutIfNeeded()
      window.displayIfNeeded()
      costs.append((CACurrentMediaTime() - wall) * 1000)
      cpus.append((mainCPU() - thread) * 1000)
      try? await Task.sleep(for: .milliseconds(80))
    }
    let wall = CACurrentMediaTime() - start
    let typed = input.textStorage.length - before
    report(name, busy: (mainCPU() - cpu) / wall, ping: ping.stop(), per: Double(keys), unit: "tecla",
      keys: (typed, costs, cpus))
    input.textView.selectAll(nil)
    input.textView.deleteBackward(nil)
    try? await Task.sleep(for: .seconds(1))
  }

  private static func report(_ name: String, busy: Double, ping: [Double], per: Double, unit: String,
    keys: (typed: Int, costs: [Double], cpus: [Double])?)
  {
    var line = String(format: "MacPerf %@ cpu-principal=%.0f%% ping p50=%.1fms p95=%.1fms max=%.0fms", name, busy * 100,
      percentile(ping, 0.5), percentile(ping, 0.95), ping.max() ?? 0)
    if let keys {
      line += String(format: " teclas=%d tecla-parede p50=%.1fms p95=%.1fms tecla-cpu p50=%.1fms p95=%.1fms",
        keys.typed, percentile(keys.costs, 0.5), percentile(keys.costs, 0.95), percentile(keys.cpus, 0.5),
        percentile(keys.cpus, 0.95))
    }
    let bodies = counts.sorted { $0.value > $1.value }
      .map { String(format: "%@=%.1f", $0.key, Double($0.value) / per) }.joined(separator: " ")
    print(line + " · body/\(unit): " + (bodies.isEmpty ? "nenhum" : bodies))
    fflush(stdout)
  }

  private static func finish(_ message: String) {
    print("MacPerf fim \(message)")
    fflush(stdout)
    exit(message == "ok" ? 0 : 1)
  }

  /// Six sessions stream text at 25 Hz; once a second each also sends a structural event, as steps and tools do.
  nonisolated static let streaming = ["ses_mac_live", "ses_mac_sidebar", "ses_mac_docs", "ses_mac_c1", "ses_mac_c2",
    "ses_mac_c3"] + (shownStreams ? [MacFixture.rootID] : [])

  private static func streamEvents(_ hub: EventHub) async {
    let ids = streaming
    var tick = 0
    if shownStreams {
      hub.inject(event("session.text.started", MacFixture.rootID, extra: #","ordinal":0"#))
    }
    while !Task.isCancelled {
      for id in ids {
        hub.inject(event("session.text.delta", id, extra: ",\"ordinal\":0,\"delta\":\"palavra \(tick) \""))
      }
      if tick % 25 == 0 {
        for id in ids {
          hub.inject(event("session.updated", id))
          hub.inject(event("session.tool.progress", id, extra: #","id":"call_\#(id)""#))
        }
      }
      tick += 1
      try? await Task.sleep(for: .milliseconds(40))
    }
  }

  private static func event(_ type: String, _ id: String, extra: String = "") -> ServerEvent {
    let message = id == MacFixture.rootID ? "msg_root_5" : id.hasPrefix("ses_mac_c") ? "msg_\(id)_a" : "msg_\(id)"
    let json = #"{"type":"\#(type)","created":\#(Date.now.timeIntervalSince1970 * 1000),"data":{"sessionID":"\#(id)","assistantMessageID":"\#(message)"\#(extra)}}"#
    return .update(try! JSONDecoder().decode(ConversationEvent.self, from: Data(json.utf8)))
  }

  /// The main thread's user and system CPU time, in seconds.
  private static func mainCPU() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.user_time.seconds + info.system_time.seconds)
      + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
  }

  private static func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
  }
}

/// How late a main-queue block runs, sent every 10 ms from a background queue.
private final class Ping: @unchecked Sendable {
  private let lock = NSLock()
  private var latencies: [Double] = []
  private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

  init() {
    timer.schedule(deadline: .now(), repeating: .milliseconds(10))
    timer.setEventHandler { [self] in
      let sent = CACurrentMediaTime()
      DispatchQueue.main.async { [self] in
        let late = (CACurrentMediaTime() - sent) * 1000
        lock.lock()
        latencies.append(late)
        lock.unlock()
      }
    }
    timer.resume()
  }

  func stop() -> [Double] {
    timer.cancel()
    lock.lock()
    defer { lock.unlock() }
    return latencies
  }
}
#endif
