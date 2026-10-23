#if DEBUG
import AVFoundation
import OpenCodeKit
import SwiftUI

@MainActor enum DictationFixtures {
  static var mode: String? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "-OpenCodeDictationFixture"), args.indices.contains(index + 1),
      ServerConfiguration.launch().url.absoluteString == "http://127.0.0.1:4177" else { return nil }
    return args[index + 1]
  }
  nonisolated static let text = "Confira as sessões em andamento e prepare um resumo das alterações. Não envie esta mensagem antes da minha revisão."
}

struct DictationFixtureRoot: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.scenePhase) private var scenePhase
  @State private var appearance = AppearanceSettings()
  @State private var draft: ConversationDraft
  @State private var store: ConversationStore
  @State private var loaded = false
  private let transcription: TranscriptionController
  init() {
    let configuration = ServerConfiguration.launch()
    let client = OpenCodeClient.scrollFixture(configuration: configuration)
    _store = State(initialValue: ConversationStore(id: "dictation-fixture", client: client, hub: EventHub(client: client)))
    let draft = ConversationDraft(server: "dictation-fixture", id: DictationFixtures.mode == "device" ? "device" : UUID().uuidString)
    if DictationFixtures.mode == "device" {
      transcription = .shared
    } else {
      transcription = TranscriptionController(source: DictationFixtureSource(), engine: DictationFixtureEngine(), monitorsNetwork: false)
    }
    let transcription = transcription
    draft.recordingFactory = { file in
      VoiceRecordingComposer(file: file, capture: DictationFixtures.mode == "device" ? nil : DictationFixtureCapture(), transcription: transcription)
    }
    _draft = State(initialValue: draft)
  }
  var body: some View {
    let theme = appearance.theme(systemDark: scheme == .dark)
    NavigationStack {
      VStack {
        Text("Ditado local · nenhum servidor é acessado").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        if let load = transcription.loadSeconds { Text(String(format: "Carga: %.2f s", load)).accessibilityIdentifier("dictation-load-time") }
        if let time = transcription.transcriptionSeconds { Text(String(format: "Transcrição: %.2f s", time)).accessibilityIdentifier("dictation-inference-time") }
        Spacer()
        if loaded { ConversationComposer(store: store, draft: draft) }
      }.padding(12).background(theme.color(.background)).navigationTitle("Ditado de teste")
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            NavigationLink("Modelo") { TranscriptionSettingsView(transcription: transcription) }
          }
        }
        .task {
          guard !loaded else { return }
          await draft.load()
          loaded = true
          transcription.start()
        }
    }.environment(\.appTheme, theme).environment(\.locale, Locale(identifier: "pt_BR"))
      .preferredColorScheme(appearance.colorScheme).tint(theme.color(.primary))
      .onChange(of: scenePhase) { _, phase in transcription.setActive(phase == .active) }
      .onChange(of: transcription.transcriptionSeconds) { saveMetrics() }
      .onChange(of: draft.expanded) { saveMetrics() }
  }
  private func saveMetrics() {
    let directory = URL.applicationSupportDirectory.appending(path: "OpenCode")
    try? TranscriptionModelFiles.prepare(directory)
    let metrics: [String: JSONValue] = [
      "modelBytes": .number(Double(transcription.totalBytes)),
      "loadSeconds": transcription.loadSeconds.map(JSONValue.number) ?? .null,
      "audioSeconds": transcription.audioSeconds.map(JSONValue.number) ?? .null,
      "inferenceSeconds": transcription.transcriptionSeconds.map(JSONValue.number) ?? .null,
      "expanded": .bool(draft.expanded), "reviewPending": .bool(draft.dictationReview),
    ]
    if let data = try? JSONEncoder().encode(metrics) {
      try? data.write(to: directory.appending(path: "dictation-fixture-metrics.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
  }
}

final class DictationFixtureSource: TranscriptionModelSource, @unchecked Sendable {
  let files: TranscriptionModelFiles
  init() {
    files = TranscriptionModelFiles(root: FileManager.default.temporaryDirectory.appending(path: "dictation-model-fixture"), manifest: .parakeetUltra)
    try? FileManager.default.createDirectory(at: files.installed, withIntermediateDirectories: true)
  }
  func setHandler(_ handler: @escaping @Sendable (TranscriptionDownloadEvent) -> Void) {}
  func start(cellular: Bool) {}
  func stop() async {}
}
actor DictationFixtureEngine: TranscriptionEngine {
  func load(from directory: URL) async throws {}
  func transcribe(_ samples: [Float]) async throws -> String { DictationFixtures.text }
  func unload() async {}
}

@MainActor final class DictationFixtureCapture: VoiceRecordingCapture {
  private var started: TimeInterval?
  private var accumulated: TimeInterval = 0
  private var file: URL?
  func authorize() async -> Bool { true }
  func start(at file: URL) throws { self.file = file; accumulated = 0; started = ProcessInfo.processInfo.systemUptime; try writePCM() }
  var elapsed: TimeInterval { accumulated + (started.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0) }
  var level: Float { MicrophoneVoiceCapture.displayLevel(decibels: Float(-30 + 18 * sin(elapsed * 8))) }
  func pause() { accumulated = elapsed; started = nil; try? writePCM() }
  func resume() throws { started = ProcessInfo.processInfo.systemUptime }
  func stop() { try? writePCM(); started = nil; accumulated = 0; file = nil }
  private func writePCM() throws {
    guard let file, let fixture = Bundle.main.url(forResource: "dictation-fixture", withExtension: "caf") else { throw TranscriptionError.integrity }
    let input = try AVAudioFile(forReading: fixture)
    let count = AVAudioFrameCount(max(1, min(86_400, elapsed) * 48_000))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count) else { throw TranscriptionError.integrity }
    try input.read(into: buffer, frameCount: min(count, AVAudioFrameCount(input.length)))
    let output = try AVAudioFile(forWriting: file, settings: input.processingFormat.settings)
    try output.write(from: buffer)
  }
}
#endif
