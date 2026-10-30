import AVFoundation
import Observation
import OpenCodeKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor @Observable final class VoiceRecordingComposer {
  private static weak var audioOwner: VoiceRecordingComposer?
  #if os(macOS)
  static var audioBusy: Bool { audioOwner?.capturing == true }
  #endif
  enum State { case idle, authorizing, recording, paused, pending }
  private(set) var state = State.idle
  private(set) var elapsed: TimeInterval = 0
  private(set) var levels = [Float](repeating: 0, count: 40)
  /// When the meter last sampled: the live waveform slides between samples on every frame.
  @ObservationIgnored private(set) var sampledAt = Date.distantPast
  private(set) var gesture = VoiceRecordingGesture()
  private(set) var discarding = false
  private(set) var previewReady = false
  private(set) var previewPlaying = false
  private(set) var previewPosition: TimeInterval = 0
  private(set) var previewDuration: TimeInterval = 0
  private(set) var waveform = [Float](repeating: 0, count: 64)
  private(set) var job: DictationJob?
  var asksDownload = false
  var permissionDenied = false
  var error: String?
  let transcription: TranscriptionController
  let file: URL
  @ObservationIgnored var receive: @MainActor (String) async -> Void = { _ in }
  @ObservationIgnored var pendingChanged: (Bool) -> Void = { _ in }
  @ObservationIgnored var willUseAudio: () -> Bool = { true }
  @ObservationIgnored private let capture: any VoiceRecordingCapture
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []
  @ObservationIgnored private var previewTask: Task<Void, Never>?
  @ObservationIgnored private var previewTicker: Task<Void, Never>?
  @ObservationIgnored private var previewPlayer: AVAudioPlayer?
  @ObservationIgnored private var previewSession = false
  @ObservationIgnored private var previewFile: URL?
  var capturing: Bool { state == .recording || state == .paused || state == .authorizing }
  var visible: Bool { state != .idle || discarding }
  init(file: URL, capture: (any VoiceRecordingCapture)? = nil, transcription: TranscriptionController = .shared) {
    self.file = file; self.capture = capture ?? MicrophoneVoiceCapture(); self.transcription = transcription
  }
  func handle(_ event: VoiceRecordingGesture.Event) {
    var event = event
    if case .began = event {
      guard state == .idle, !discarding else { return }
      gesture = VoiceRecordingGesture()
      mark("touch")
      // With the microphone already allowed, recording starts at the touch instead of after the hold delay.
      if capture.authorized { event = .pressed }
    }
    if case .ended = event { mark("release") }
    let wasHolding = gesture.state == .holding
    switch gesture.handle(event) {
    case .startHolding, .startLocked: start()
    case .handsFree: Haptics.play(.light)
    case .lock:
      #if os(iOS)
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      #endif
      announce("Gravação travada. Pode soltar o dedo")
    case .finish:
      // Releasing during the permission prompt never lets a capture open later. A release before one second is
      // not a dictation yet: keep recording hands-free, as in WhatsApp on iPhone.
      let opening = state == .authorizing
      if opening && !capture.authorized { discard() }
      else if opening || capture.elapsed < VoiceRecordingGesture.minimumDuration {
        gesture.keepRecording()
        Haptics.play(.light)
      } else { finish() }
    case .discard:
      if case .cancelled = event, wasHolding, keepsDraft {
        // The system took the touch (Home, lock, alert): keep a paused draft.
        gesture.keepRecording(); pause(); return
      }
      discard()
      if wasHolding {
        Haptics.play(.warning)
        discarding = true
        task = Task {
          do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
          discarding = false
        }
      }
    case .none: break
    }
  }
  private func start() {
    guard state == .idle, willUseAudio() else { gesture = VoiceRecordingGesture(); return }
    NotificationCenter.default.post(name: .audioCaptureWillStart, object: nil)
    Self.audioOwner?.suspend()
    Self.audioOwner = self
    state = .authorizing
    error = nil
    // The panel appears at the touch: nothing from the previous recording.
    elapsed = 0; levels = Array(repeating: 0, count: 40)
    observeInterruptions()
    let ticket = generation
    task = Task {
      let allowed = await capture.authorize()
      guard !Task.isCancelled, ticket == generation else { return }
      guard allowed else { discard(); permissionDenied = true; return }
      guard willUseAudio() else { discard(); return }
      do {
        try TranscriptionModelFiles.prepare(file.deletingLastPathComponent())
        try await capture.start(at: file)
        // discard() during activation already stopped the capture.
        guard !Task.isCancelled, ticket == generation else { return }
        state = .recording
        mark("recording")
        Haptics.play(.light)
        announce("Gravando para transcrever")
        startMeter()
        // The first load after an install compiles for the Neural Engine; overlap it with speech.
        transcription.prewarm()
      } catch {
        guard ticket == generation else { return }
        discard(); self.error = "Não foi possível iniciar a gravação."
      }
    }
  }
  private func startMeter() {
    task = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        guard let self, state == .recording else { return }
        elapsed = capture.elapsed
        levels.removeFirst(); levels.append(capture.level)
        sampledAt = .now
        if elapsed >= 86_400 { finish(); return }
      }
    }
  }
  func pause() {
    guard state == .recording else { return }
    task?.cancel(); task = nil
    capture.pause(); elapsed = capture.elapsed; state = .paused
    mark("pause")
    announce("Gravação pausada")
    makePreview()
  }
  func resume() {
    guard state == .paused, task == nil, willUseAudio() else { return }
    if Self.audioOwner !== self { Self.audioOwner?.suspend(); Self.audioOwner = self }
    clearPreview()
    let ticket = generation
    task = Task {
      do {
        try await capture.resume()
        guard !Task.isCancelled, ticket == generation, state == .paused else { return }
        state = .recording; announce("Gravação retomada"); startMeter()
      } catch {
        // finish() or discard() during activation stopped the capture and changed the state.
        guard ticket == generation, state == .paused else { return }
        task = nil
        self.error = "Não foi possível retomar a gravação."; makePreview()
      }
    }
  }
  /// Background, interruption, route change or another recorder: a locked recording, or a hold of one second or
  /// more, becomes a paused draft that never resumes on its own; a shorter hold is discarded.
  func suspend() {
    if state == .recording, gesture.state == .locked { pause() }
    else if gesture.state == .holding, keepsDraft { gesture.keepRecording(); pause() }
    else if state == .recording || state == .authorizing { discard() }
    pausePreview()
  }
  private var keepsDraft: Bool { state == .recording && capture.elapsed >= VoiceRecordingGesture.minimumDuration }
  private func observeInterruptions() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    #if os(iOS)
    observers = [
      center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] note in
        guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
          context.source == .system else { return }
        MainActor.assumeIsolated { self?.suspend() }
      },
      center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
        guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          [AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue].contains(reason) else { return }
        MainActor.assumeIsolated { self?.suspend() }
      },
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.suspend() }
      },
    ]
    #else
    observers = [
      center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.suspend() }
      },
      center.addObserver(forName: .macAudioDeviceChanged, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.suspend() }
      },
    ]
    #endif
  }
  private func removeObservers() {
    observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
  }
  func finish() {
    guard state == .recording || state == .paused else { return }
    task?.cancel(); task = nil
    clearPreview(); removeObservers(); capture.stop()
    state = .pending
    // discard() while the file is read (Esc, Descartar) deletes it: the failed read must not bring the panel back.
    let ticket = generation
    task = Task {
      do {
        let file = file
        let duration = try await Task.detached {
          let source = try AVAudioFile(forReading: file)
          return Double(source.length) / source.processingFormat.sampleRate
        }.value
        guard ticket == generation, state == .pending else { return }
        guard duration >= VoiceRecordingGesture.minimumDuration else {
          discard(); announce("Gravação curta descartada"); return
        }
        pendingChanged(true)
        enqueue()
        asksDownload = transcription.status == .missing
      } catch {
        guard ticket == generation else { return }
        state = .pending; self.error = "Não foi possível ler a gravação. Seu áudio foi preservado."; pendingChanged(true)
      }
    }
  }
  func restorePending() {
    guard state == .idle, FileManager.default.fileExists(atPath: file.path) else { return }
    state = .pending
    enqueue()
  }
  private func enqueue() {
    let job = DictationJob(file: file) { [weak self] text in
      guard let self else { return }
      await receive(text)
      mark("text")
      pendingChanged(false)
      try? FileManager.default.removeItem(at: file)
      state = .idle; gesture = VoiceRecordingGesture(); self.job = nil
      announce("Texto transcrito. Revise a mensagem antes de enviar")
    }
    self.job = job
    transcription.enqueue(job)
  }
  func retry() {
    error = nil
    if let job { transcription.retry(job) } else { enqueue() }
  }
  /// What Esc cancels on the Mac: a recording (paused or still asking for the microphone too) or a transcription
  /// under way. A dictation waiting for the model's download, or one that failed, keeps its audio for Tentar de novo.
  var cancellable: Bool {
    if capturing { return true }
    guard state == .pending, error == nil else { return false }
    guard let job else { return true }
    switch job.state {
    case .transcribing: return true
    case .waiting: return transcription.status == .ready || transcription.status == .preparing
    case .failed, .done: return false
    }
  }
  /// Esc: the dictation ends with nothing transcribed. The panel leaving is the visible answer; VoiceOver hears it.
  func cancel() {
    guard cancellable else { return }
    discard()
    announce("Ditado cancelado")
  }
  func discard() {
    generation = UUID()
    task?.cancel(); task = nil
    clearPreview(); removeObservers(); capture.stop()
    if let job { transcription.cancel(job) }
    job = nil
    try? FileManager.default.removeItem(at: file)
    pendingChanged(false)
    state = .idle; elapsed = 0; gesture = VoiceRecordingGesture(); discarding = false; error = nil
  }
  private func makePreview() {
    clearPreview()
    let file = file
    let preview = file.deletingLastPathComponent().appending(path: "dictation-preview-\(UUID().uuidString).caf")
    previewFile = preview
    previewTask = Task {
      defer { if Task.isCancelled || previewFile != preview { try? FileManager.default.removeItem(at: preview) } }
      do {
        var previous: Int?
        var quiet = 0
        for _ in 0..<40 {
          try Task.checkCancellation()
          guard state == .paused else { return }
          let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
          quiet = size == previous ? quiet + 1 : 0
          previous = size
          if quiet >= 4 {
            let result = try await Task.detached {
              try VoiceRecordingSnapshot.copy(pcm: file, to: preview)
              return try VoiceRecordingSnapshot.inspect(preview)
            }.value
            guard !Task.isCancelled, state == .paused else { return }
            waveform = result.waveform; previewDuration = result.duration; elapsed = result.duration; previewReady = result.duration > 0
            mark("preview")
            return
          }
          try await Task.sleep(for: .milliseconds(50))
        }
        throw TranscriptionError.integrity
      } catch is CancellationError {} catch {
        if !Task.isCancelled, previewFile == preview { self.error = "Não foi possível preparar a pré-escuta." }
      }
    }
  }
  func togglePreview() {
    guard state == .paused, previewReady, let previewFile else { return }
    if previewPlaying { pausePreview(); return }
    guard willUseAudio() else { return }
    if Self.audioOwner !== self { Self.audioOwner?.suspend(); Self.audioOwner = self }
    // Playing from the first tap lets a second tap cancel a pending activation.
    previewPlaying = true
    previewSession = true
    previewTicker = Task { [weak self] in
      do {
        guard let self else { return }
        if previewPlayer == nil { previewPlayer = try AVAudioPlayer(contentsOf: previewFile) }
        guard let player = previewPlayer else { return }
        if previewPosition >= previewDuration { previewPosition = 0 }
        player.currentTime = previewPosition
        let queued = QueuedAudio(value: player)
        try await DictationAudioSession.activate(.playback) {
          guard queued.value.play() else { throw TranscriptionError.integrity }
        }
        // pausePreview() during the activation already queued the deactivation.
        guard !Task.isCancelled, previewPlaying, state == .paused else { player.pause(); return }
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
          guard let player = previewPlayer else { return }
          if !player.isPlaying { pausePreview(); previewPosition = 0; return }
          previewPosition = player.currentTime
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        pausePreview(); self.error = "Não foi possível ouvir a gravação."
      }
    }
  }
  func seekPreview(fraction: Double) {
    guard state == .paused, previewReady else { return }
    previewPosition = min(1, max(0, fraction)) * previewDuration
    previewPlayer?.currentTime = previewPosition
  }
  func pausePreview() {
    if previewPlaying { previewPosition = previewPlayer?.currentTime ?? previewPosition }
    previewPlayer?.pause(); previewPlaying = false; previewTicker?.cancel(); previewTicker = nil
    if previewSession { DictationAudioSession.deactivate(); previewSession = false }
  }
  private func clearPreview() {
    pausePreview(); previewPlayer = nil; previewTask?.cancel(); previewTask = nil
    if let previewFile { try? FileManager.default.removeItem(at: previewFile) }
    previewFile = nil
    previewReady = false; previewPosition = 0; previewDuration = 0
  }
  private func mark(_ name: String) {
    #if DEBUG
    DictationTimeline.mark(name)
    #endif
  }
  private func announce(_ message: String) {
    #if os(iOS)
    guard UIAccessibility.isVoiceOverRunning, UIApplication.shared.applicationState == .active else { return }
    UIAccessibility.post(notification: .announcement, argument: message)
    #else
    guard NSApp.isActive, let window = NSApp.keyWindow else { return }
    NSAccessibility.post(element: window, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    #endif
  }
}
