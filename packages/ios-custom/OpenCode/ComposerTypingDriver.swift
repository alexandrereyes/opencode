#if DEBUG
import Darwin
import OSLog
import OpenCodeKit
import SwiftUI

/// Server-free typing benchmark for the conversation fixture (`-OpenCodeFixtureAutoType <scenario>`).
/// It drives the production composer through UITextInput at a fixed cadence and records, per keystroke,
/// the main run loop's busy time until the next keystroke, plus display-link frame intervals.
struct ComposerTypingDriver: UIViewRepresentable {
  static let scenario: String? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "-OpenCodeFixtureAutoType"), arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }()
  func makeUIView(context: Context) -> Driver { Driver() }
  func updateUIView(_ view: Driver, context: Context) {}
  static func dismantleUIView(_ view: Driver, coordinator: ()) { view.stop() }

  enum Step { case type(String), delete, token }

  /// Fixture catalogs sized like a real workspace, so suggestion ranking costs what it does in use.
  static let sources: ComposerSources = {
    var sources = ComposerSources()
    sources.skills = (0..<150).map { index in
      try! JSONDecoder().decode(ComposerSkill.self, from: Data(
        #"{"id":"skill-\#(index)","name":"skill-\#(index)","description":"Skill de teste número \#(index) com descrição"}"#.utf8))
    } + [try! JSONDecoder().decode(ComposerSkill.self, from: Data(#"{"id":"sample","name":"sample","description":"Skill de teste"}"#.utf8))]
    return sources
  }()
  static let files: [ComposerFile] = (["README.md"] + (0..<300).map { "packages/modulo-\($0 / 20)/Fonte\($0).swift" }).map {
    try! JSONDecoder().decode(ComposerFile.self, from: Data(#"{"path":"\#($0)","type":"file"}"#.utf8))
  }
  static func suggestions(_ trigger: ComposerTrigger) -> [ComposerSuggestion] {
    sources.suggestions(trigger, files: files, directory: "/fixture")
  }

  static func steps(_ scenario: String) -> [Step] {
    let prose = "Preciso revisar o fluxo de envio do compositor e confirmar que nada engasga ao digitar. "
    func typed(_ text: String) -> [Step] { text.map { .type(String($0)) } }
    switch scenario {
    case "idle":
      return Array(repeating: .type(""), count: 200)
    case "mentions":
      let cycle = typed("Veja @READ") + [.token] + typed("e use $sam") + [.token] + typed("para revisar o texto. ")
      return Array(Array(repeating: cycle, count: 8).joined().prefix(200))
    case "suggestions":
      let cycle = typed("READ") + Array(repeating: .delete, count: 4) + typed("Fonte1") + Array(repeating: .delete, count: 6)
      return typed("Abra @") + Array(Array(repeating: cycle, count: 10).joined().prefix(194))
    case "toggle":
      // Every keystroke empties or fills the field, swapping the send and microphone controls.
      return Array(Array(repeating: typed("a") + [.delete], count: 100).joined())
    default:
      return Array(typed(prose + prose + prose).prefix(200))
    }
  }

  static func prefill(_ scenario: String) -> ComposerDocument {
    guard scenario == "long" else { return ComposerDocument() }
    var document = ComposerDocument()
    for index in 0..<200 {
      document.text += "Linha \(index) do rascunho longo com a skill "
      let token = ComposerToken(kind: .skill, id: "skill-\(index)", text: "$skill-\(index)")
      let start = document.text.utf16.count
      document.text += token.text
      document.tokens.append(.init(start: start, end: document.text.utf16.count, token: token))
      document.text += " mencionada no meio do texto.\n"
    }
    return document
  }

  final class Driver: UIView {
    private let signposter = OSSignposter(subsystem: "br.com.alexandrem.opencode", category: "PointsOfInterest")
    private var task: Task<Void, Never>?
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var awake: CFTimeInterval = 0
    private var busy: Double = 0
    private var previousFrame: CFTimeInterval = 0
    private var frames: [Double] = []

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil, let scenario = ComposerTypingDriver.scenario, task == nil else { return }
      task = Task { @MainActor [weak self] in await self?.run(scenario) }
    }

    private func run(_ scenario: String) async {
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard let window, let composer = find(window, "conversation-composer"),
        let conversation = composer.representedDraft else { return }
      let comment = scenario.hasPrefix("comment")
      if comment {
        // The quote comment sheet hosts the same editor over the conversation.
        conversation.commenting = ChatQuote(messageID: "fixture", partID: "fixture", text: "Trecho citado da resposta.")
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
      guard let input = comment ? find(window, "comment-composer") : composer, let draft = input.representedDraft
      else { return }
      let document = ComposerTypingDriver.prefill(scenario)
      if !comment {
        draft.text = document.attributed
        draft.selection = NSRange(location: document.editorOffset(document.text.utf16.count), length: 0)
      }
      draft.focused = true
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      let steps = ComposerTypingDriver.steps(comment ? String(scenario.dropFirst("comment".count).drop { $0 == "-" }) : scenario)
      var keystrokes: [Double] = []
      var inserts: [Double] = []
      let startCPU = mainThreadCPUTime()
      begin()
      let interval = signposter.beginInterval("ComposerTyping")
      for step in steps {
        busy = 0
        let start = CACurrentMediaTime()
        signposter.emitEvent("Keystroke")
        switch step {
        case .type(let text): if !text.isEmpty { input.insertText(text) }
        case .delete: input.deleteBackward()
        case .token:
          // The same path as choosing the first suggestion in ComposerEditor.
          if let trigger = draft.trigger, let item = ComposerTypingDriver.suggestions(trigger).first {
            draft.insert(item.token, replacing: trigger.range)
          }
        }
        inserts.append((CACurrentMediaTime() - start) * 1000)
        do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        keystrokes.append(busy * 1000)
      }
      signposter.endInterval("ComposerTyping", interval)
      let cpu = (mainThreadCPUTime() - startCPU) * 1000
      end()
      let typed = draft.document
      report(scenario, keystrokes: keystrokes, inserts: inserts, cpu: cpu, text: typed.text.utf16.count, tokens: typed.validTokens.count)
      conversation.commenting = nil
      await conversation.clear()
    }

    private func find(_ view: UIView, _ identifier: String) -> ComposerInputView? {
      if let input = view as? ComposerInputView, input.accessibilityIdentifier == identifier, input.representedDraft != nil {
        return input
      }
      return view.subviews.lazy.compactMap { self.find($0, identifier) }.first
    }

    private func begin() {
      let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
        guard let self else { return }
        let now = CACurrentMediaTime()
        if activity == .afterWaiting { awake = now } else if awake > 0 { busy += now - awake; awake = 0 }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      self.observer = observer
      awake = CACurrentMediaTime()
      let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
      link.add(to: .main, forMode: .common)
      self.link = link
    }

    private func end() {
      if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
      observer = nil
      link?.invalidate()
      link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
      if previousFrame > 0 { frames.append((link.timestamp - previousFrame) * 1000) }
      previousFrame = link.timestamp
    }

    private func report(_ scenario: String, keystrokes: [Double], inserts: [Double], cpu: Double, text: Int, tokens: Int) {
      func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * p)]
      }
      let refresh = Double(window?.screen.maximumFramesPerSecond ?? 60)
      let budget = 1000 / refresh
      let duration = frames.reduce(0, +)
      let hitches = frames.filter { $0 > budget * 1.5 }
      let arguments = ProcessInfo.processInfo.arguments
      let run = arguments.firstIndex(of: "-OpenCodeFixtureRunID").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
      }
      let value: [String: Any] = [
        "runID": run ?? "", "scenario": scenario, "keystrokes": keystrokes.count,
        "finalUTF16": text, "finalTokens": tokens,
        "keystrokeBusyP50MS": percentile(keystrokes, 0.5), "keystrokeBusyP95MS": percentile(keystrokes, 0.95),
        "keystrokeBusyMaxMS": keystrokes.max() ?? 0, "keystrokeBusyMeanMS": keystrokes.reduce(0, +) / Double(max(1, keystrokes.count)),
        "insertP50MS": percentile(inserts, 0.5), "insertP95MS": percentile(inserts, 0.95),
        "mainThreadCPU_MS": cpu, "frames": frames.count, "durationMS": duration,
        "frameP95MS": percentile(frames, 0.95), "frameMaxMS": frames.max() ?? 0,
        "hitches": hitches.count, "hitchTimeMSPerS": hitches.reduce(0) { $0 + $1 - budget } / max(1, duration / 1000),
        "over50MS": frames.filter { $0 > 50 }.count,
      ]
      guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
      try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: url.appendingPathComponent("composer-typing-metrics.json"), options: .atomic)
    }

    private func mainThreadCPUTime() -> Double {
      let thread = mach_thread_self()
      defer { mach_port_deallocate(mach_task_self_, thread) }
      var info = thread_basic_info()
      var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
      let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
      }
      guard status == KERN_SUCCESS else { return 0 }
      return Double(info.user_time.seconds + info.system_time.seconds)
        + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    func stop() {
      task?.cancel()
      task = nil
      end()
    }
  }
}
#endif
