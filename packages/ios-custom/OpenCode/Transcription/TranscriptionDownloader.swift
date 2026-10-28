import Foundation
import OpenCodeKit
import os

enum TranscriptionDownloadEvent: Sendable, Equatable {
  case progress(Int64), installed, failed(String)
}

protocol TranscriptionModelSource: AnyObject, Sendable {
  var files: TranscriptionModelFiles { get }
  func setHandler(_ handler: @escaping @Sendable (TranscriptionDownloadEvent) -> Void)
  func start(cellular: Bool)
  func stop() async
}

/// Abacato's background/resumable, per-file verified download, scoped to this app.
final class TranscriptionDownloader: NSObject, TranscriptionModelSource, URLSessionDownloadDelegate, @unchecked Sendable {
  static let wifiIdentifier = "br.com.alexandrem.opencode.transcription.wifi"
  static let anyNetworkIdentifier = "br.com.alexandrem.opencode.transcription.any"
  let files: TranscriptionModelFiles
  private struct State {
    var handler: (@Sendable (TranscriptionDownloadEvent) -> Void)?
    var sessions: [String: URLSession] = [:]
    var inFlight: [String: Int64] = [:]
    var completions: [String: @Sendable () -> Void] = [:]
    var cancelled: Set<String> = []
    var active = false
    var cellular = false
    var failures = 0
    var retry: Task<Void, Never>?
    var scheduling = false
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "opencode.transcription.download"
    return queue
  }()
  init(files: TranscriptionModelFiles) { self.files = files; super.init() }
  func setHandler(_ handler: @escaping @Sendable (TranscriptionDownloadEvent) -> Void) {
    state.withLock { $0.handler = handler }
  }
  private func emit(_ event: TranscriptionDownloadEvent) { state.withLock { $0.handler }?(event) }
  private func session(_ identifier: String) -> URLSession {
    state.withLock { state in
      if let session = state.sessions[identifier] { return session }
      let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
      #if os(iOS)
      configuration.sessionSendsLaunchEvents = true
      #endif
      configuration.isDiscretionary = false
      configuration.allowsExpensiveNetworkAccess = identifier == Self.anyNetworkIdentifier
      configuration.allowsConstrainedNetworkAccess = identifier == Self.anyNetworkIdentifier
      configuration.allowsCellularAccess = true
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
      state.sessions[identifier] = session
      return session
    }
  }
  func handleBackgroundEvents(identifier: String, completion: @escaping @Sendable () -> Void) {
    guard [Self.wifiIdentifier, Self.anyNetworkIdentifier].contains(identifier) else { completion(); return }
    state.withLock { $0.active = true; $0.completions[identifier] = completion }
    _ = session(identifier)
  }
  func start(cellular: Bool) {
    state.withLock { $0.active = true; $0.cellular = cellular; $0.retry?.cancel(); $0.retry = nil }
    Task { await schedule() }
  }
  private func schedule() async {
    let acquired = state.withLock { state in
      guard state.active, !state.scheduling else { return false }
      state.scheduling = true
      return true
    }
    guard acquired else { return }
    defer { state.withLock { $0.scheduling = false } }
    if files.isInstalled { emit(.installed); return }
    do {
      try files.prepareRoot()
      let missing = files.missingFiles()
      if missing.isEmpty { finishIfComplete(); return }
      let remaining = missing.reduce(Int64(0)) { $0 + $1.bytes }
      let capacity = try files.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
      if let capacity, capacity < remaining + 200 * 1_048_576 { throw TranscriptionError.noSpace }
      let cellular = state.withLock { $0.cellular }
      let target = session(cellular ? Self.anyNetworkIdentifier : Self.wifiIdentifier)
      let other = session(cellular ? Self.wifiIdentifier : Self.anyNetworkIdentifier)
      for task in await other.allTasks {
        guard let download = task as? URLSessionDownloadTask, let path = task.taskDescription else { task.cancel(); continue }
        state.withLock { _ = $0.cancelled.insert("\(other.configuration.identifier ?? "")/\(task.taskIdentifier)") }
        if let data = await download.cancelByProducingResumeData(), let file = missing.first(where: { $0.path == path }) {
          saveResumeData(data, for: file)
        }
      }
      guard state.withLock({ $0.active }) else { return }
      let running = Set(await target.allTasks.compactMap(\.taskDescription))
      emit(.progress(files.stagedBytes()))
      for file in missing where !running.contains(file.path) {
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: files.resumeDataURL(for: file)) {
          task = target.downloadTask(withResumeData: data)
          try? FileManager.default.removeItem(at: files.resumeDataURL(for: file))
        } else { task = target.downloadTask(with: files.manifest.url(for: file)) }
        task.taskDescription = file.path
        task.countOfBytesClientExpectsToReceive = file.bytes
        task.resume()
      }
    } catch { emit(.failed(error.localizedDescription)) }
  }
  func stop() async {
    state.withLock { $0.active = false; $0.retry?.cancel(); $0.retry = nil }
    for session in state.withLock({ Array($0.sessions.values) }) {
      for task in await session.allTasks { task.cancel() }
    }
    await withCheckedContinuation { continuation in queue.addOperation { continuation.resume() } }
    state.withLock { $0.inFlight = [:]; $0.failures = 0 }
  }
  private func saveResumeData(_ data: Data, for file: TranscriptionManifest.File) {
    let url = files.resumeDataURL(for: file)
    try? TranscriptionModelFiles.prepare(url.deletingLastPathComponent())
    try? data.write(to: url, options: .atomic)
  }
  private func finishIfComplete() {
    guard state.withLock({ $0.active }), files.missingFiles().isEmpty else { return }
    do { try files.install(); emit(.installed) }
    catch { emit(.failed(error.localizedDescription)) }
  }
  private func failed(_ reason: String) {
    let attempt = state.withLock { state -> Int in
      guard state.active else { return 0 }
      state.failures += 1
      return state.failures
    }
    guard attempt > 0 else { return }
    if attempt >= 6 {
      state.withLock { $0.active = false; $0.failures = 0 }
      emit(.failed(reason)); return
    }
    let retry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(min(300, 5 * pow(2, Double(attempt - 1))))) } catch { return }
      await self?.schedule()
    }
    state.withLock { $0.retry?.cancel(); $0.retry = retry }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let path = downloadTask.taskDescription, state.withLock({ $0.active }) else { return }
    let inFlight = state.withLock { $0.inFlight[path] = totalBytesWritten; return $0.inFlight.values.reduce(0, +) }
    emit(.progress(min(files.manifest.totalBytes, files.stagedBytes() + inFlight)))
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard state.withLock({ $0.active }), let path = downloadTask.taskDescription,
      let file = files.manifest.files.first(where: { $0.path == path }) else { return }
    state.withLock { _ = $0.inFlight.removeValue(forKey: path) }
    do {
      let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else { throw TranscriptionError.download("Resposta \(status) ao baixar o modelo.") }
      try files.stage(file, from: location)
      try? FileManager.default.removeItem(at: files.resumeDataURL(for: file))
      state.withLock { $0.failures = 0 }
      emit(.progress(files.stagedBytes()))
      finishIfComplete()
    } catch {
      try? FileManager.default.removeItem(at: files.resumeDataURL(for: file))
      failed(error.localizedDescription)
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    guard let error, state.withLock({ $0.active }) else { return }
    let ours = state.withLock { $0.cancelled.remove("\(session.configuration.identifier ?? "")/\(task.taskIdentifier)") != nil }
    if let path = task.taskDescription { state.withLock { _ = $0.inFlight.removeValue(forKey: path) } }
    let failure = error as NSError
    if let data = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
      let file = files.manifest.files.first(where: { $0.path == task.taskDescription }) { saveResumeData(data, for: file) }
    guard !ours, failure.code != NSURLErrorCancelled else { return }
    failed("Não foi possível baixar o modelo. Confira a conexão e tente de novo.")
  }
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let identifier = session.configuration.identifier,
      let completion = state.withLock({ $0.completions.removeValue(forKey: identifier) }) else { return }
    DispatchQueue.main.async { completion() }
  }
}
