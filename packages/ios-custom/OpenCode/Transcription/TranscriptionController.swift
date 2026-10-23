import Foundation
import Network
import Observation
import OpenCodeKit
import OSLog
import UIKit

@MainActor @Observable final class DictationJob {
  enum State: Equatable { case waiting, transcribing, failed(String), done }
  let id = UUID()
  let file: URL
  var state = State.waiting
  @ObservationIgnored let receive: @MainActor (String) async -> Void
  init(file: URL, receive: @escaping @MainActor (String) async -> Void) { self.file = file; self.receive = receive }
}

@MainActor @Observable final class TranscriptionController {
  enum Status: Equatable { case missing, downloading, preparing, ready, failed(String) }
  static let shared = TranscriptionController()
  private(set) var status: Status
  private(set) var downloaded: Int64 = 0
  private(set) var expensive = false
  private(set) var connected = true
  private(set) var cellular = false
  private(set) var diskBytes: Int64 = 0
  private(set) var jobs: [DictationJob] = []
  private(set) var loadSeconds: Double?
  private(set) var transcriptionSeconds: Double?
  private(set) var audioSeconds: Double?
  @ObservationIgnored let source: any TranscriptionModelSource
  @ObservationIgnored private let engine: any TranscriptionEngine
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let decode: @Sendable (URL) throws -> [Float]
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var idle: Task<Void, Never>?
  @ObservationIgnored private var monitor: NWPathMonitor?
  @ObservationIgnored private var active = true
  @ObservationIgnored private var removing = false
  @ObservationIgnored private var unloadWhenIdle = false
  @ObservationIgnored private var memoryObserver: (any NSObjectProtocol)?
  private static let consentKey = "OpenCodeTranscriptionDownloadConsented"
  private static let cellularKey = "OpenCodeTranscriptionDownloadCellular"
  private static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "dictation")
  var totalBytes: Int64 { source.files.manifest.totalBytes }
  var progress: Double { min(1, Double(downloaded) / Double(max(1, totalBytes))) }
  var label: String {
    switch status {
    case .missing: "Modelo não baixado"
    case .downloading: !connected ? "Aguardando conexão" : expensive && !cellular ? "Aguardando Wi-Fi" : "Baixando modelo…"
    case .preparing: "Preparando para este iPhone…"
    case .ready: "Pronto · no aparelho"
    case .failed(let reason): reason
    }
  }
  static var downloadMessage: String {
    "O Parakeet Ultra ocupa 632 MB (603 MiB). Recomendamos Wi-Fi. O download continua em segundo plano e pode ser retomado. A primeira preparação leva cerca de 15 segundos. O áudio nunca sai deste iPhone."
  }
  init(source: (any TranscriptionModelSource)? = nil, engine: (any TranscriptionEngine)? = nil,
       defaults: UserDefaults = .standard, monitorsNetwork: Bool = true,
       decode: @escaping @Sendable (URL) throws -> [Float] = TranscriptionAudio.samples) {
    let files = TranscriptionModelFiles(root: .applicationSupportDirectory.appending(path: "OpenCode/Transcription"), manifest: .parakeetUltra)
    self.source = source ?? TranscriptionDownloader(files: files)
    self.engine = engine ?? ParakeetUltraEngine()
    self.defaults = defaults
    self.decode = decode
    status = self.source.files.isInstalled ? .ready : .missing
    downloaded = self.source.files.stagedBytes()
    diskBytes = self.source.files.bytesOnDisk
    cellular = defaults.bool(forKey: Self.cellularKey)
    self.source.setHandler { [weak self] event in Task { @MainActor in self?.handle(event) } }
    memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.idle?.cancel()
        if self.worker == nil { Task { await self.engine.unload() } }
        else { self.unloadWhenIdle = true }
      }
    }
    if monitorsNetwork {
      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { [weak self] path in
        Task { @MainActor in self?.expensive = path.isExpensive || path.isConstrained; self?.connected = path.status == .satisfied }
      }
      monitor.start(queue: DispatchQueue(label: "opencode.transcription.network"))
      self.monitor = monitor
    }
  }
  func start() {
    if source.files.isInstalled { status = .ready; pump(); return }
    if defaults.bool(forKey: Self.consentKey) { download(cellular: cellular) }
  }
  func setActive(_ value: Bool) {
    active = value
    if value { pump() }
    if !value, worker == nil { idle?.cancel(); Task { await engine.unload() } }
  }
  func download(cellular: Bool) {
    guard !removing else { return }
    defaults.set(true, forKey: Self.consentKey)
    self.cellular = cellular
    defaults.set(cellular, forKey: Self.cellularKey)
    if source.files.isInstalled { status = .ready; pump(); return }
    status = .downloading
    source.start(cellular: cellular)
  }
  func retry() {
    if source.files.isInstalled { status = .ready; pump() }
    else { download(cellular: cellular) }
  }
  func enqueue(_ job: DictationJob) {
    guard !jobs.contains(where: { $0 === job }) else { return }
    jobs.append(job)
    pump()
  }
  func retry(_ job: DictationJob) { job.state = .waiting; retry() }
  func cancel(_ job: DictationJob) { jobs.removeAll { $0 === job } }
  func removeModel() async {
    guard worker == nil, !removing else { return }
    removing = true
    defer { removing = false }
    defaults.set(false, forKey: Self.consentKey)
    defaults.set(false, forKey: Self.cellularKey)
    cellular = false
    idle?.cancel()
    await source.stop()
    await engine.unload()
    do {
      try source.files.remove()
      downloaded = 0; diskBytes = 0; status = .missing
    } catch { status = .failed("Não foi possível apagar o modelo.") }
  }
  var canRemove: Bool { worker == nil && !removing }
  func refreshDiskSize() { diskBytes = source.files.bytesOnDisk }
  private func handle(_ event: TranscriptionDownloadEvent) {
    guard !removing else { return }
    switch event {
    case .progress(let bytes): downloaded = bytes
    case .installed:
      cellular = false; defaults.set(false, forKey: Self.cellularKey)
      downloaded = totalBytes; diskBytes = source.files.bytesOnDisk; status = .ready; pump()
    case .failed(let reason): status = .failed(reason)
    }
  }
  private func pump() {
    guard active, !removing, worker == nil, status == .ready,
      jobs.contains(where: { $0.state == .waiting }) else { return }
    idle?.cancel()
    worker = Task {
      defer { worker = nil; scheduleUnload() }
      let started = ContinuousClock.now
      status = .preparing
      do {
        try await engine.load(from: source.files.installed)
        loadSeconds = Self.seconds(ContinuousClock.now - started)
        Self.log.notice("Model load: \(self.loadSeconds ?? 0, privacy: .public) s")
        status = .ready
      } catch {
        status = .failed("Não foi possível preparar o modelo de transcrição.")
        return
      }
      while active, let job = jobs.first(where: { $0.state == .waiting }) {
        job.state = .transcribing
        do {
          let file = job.file, decode = self.decode
          let samples = try await Task.detached(priority: .userInitiated) { try decode(file) }.value
          guard active else { job.state = .waiting; break }
          let started = ContinuousClock.now
          let text = try await engine.transcribe(samples)
          audioSeconds = Double(samples.count) / 16_000
          transcriptionSeconds = Self.seconds(ContinuousClock.now - started)
          Self.log.notice("Transcription: \(Double(samples.count) / 16_000, privacy: .public) s audio, \(self.transcriptionSeconds ?? 0, privacy: .public) s inference")
          guard jobs.contains(where: { $0 === job }) else { continue }
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionError.empty }
          await job.receive(text)
          job.state = .done
          jobs.removeAll { $0 === job }
        } catch {
          if jobs.contains(where: { $0 === job }) {
            job.state = .failed("Não foi possível transcrever. \(error is TranscriptionError ? error.localizedDescription : "Seu áudio foi preservado.")")
          }
        }
      }
    }
  }
  private func scheduleUnload() {
    idle?.cancel()
    let immediate = !active || unloadWhenIdle
    unloadWhenIdle = false
    idle = Task { [weak self] in
      if !immediate { do { try await Task.sleep(for: .seconds(60)) } catch { return } }
      guard let self, worker == nil else { return }
      await engine.unload()
    }
  }
  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}

final class TranscriptionAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                   completionHandler: @escaping () -> Void) {
    let completion = BackgroundDownloadCompletion(completionHandler)
    guard let downloader = TranscriptionController.shared.source as? TranscriptionDownloader else { completionHandler(); return }
    downloader.handleBackgroundEvents(identifier: identifier) { completion.call() }
  }
}
private final class BackgroundDownloadCompletion: @unchecked Sendable {
  private let completion: () -> Void
  init(_ completion: @escaping () -> Void) { self.completion = completion }
  func call() { completion() }
}
